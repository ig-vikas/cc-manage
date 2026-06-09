const http = require('http');
const https = require('https');

const PORT = parseInt(process.argv[2], 10) || 18100;
const PROVIDER = process.env.CC_PROVIDER || 'opencode_nemotron';
const DEFAULT_MODEL = 'nemotron-3-ultra-free';
const AVAILABLE_MODELS = (process.env.CC_MODELS || DEFAULT_MODEL)
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);
const UPSTREAM_CHAT_URL =
  process.env.CC_OPENCODE_CHAT_URL ||
  process.env.OPENCODE_CHAT_URL ||
  'https://opencode.ai/zen/v1/chat/completions';
const TOOL_REASONING_STATE = new Map();
const MAX_TOOL_REASONING_STATE = 500;

function getApiKey(req) {
  const h = req.headers['x-api-key'] || req.headers.authorization || '';
  return h.replace(/^Bearer\s+/i, '').trim();
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function makeId(prefix) {
  return prefix + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

function safeParseJson(text) {
  if (text && typeof text === 'object') return text;
  try {
    return JSON.parse(text || '{}');
  } catch (e) {
    return {};
  }
}

function compactJson(value) {
  try {
    return JSON.stringify(value);
  } catch (e) {
    return String(value || '');
  }
}

function rememberToolReasoning(id, reasoning) {
  const text = String(reasoning || '').trim();
  if (!id || !text) return;
  TOOL_REASONING_STATE.set(String(id), text);
  while (TOOL_REASONING_STATE.size > MAX_TOOL_REASONING_STATE) {
    const oldestKey = TOOL_REASONING_STATE.keys().next().value;
    TOOL_REASONING_STATE.delete(oldestKey);
  }
}

function getRememberedToolReasoning(id) {
  if (!id) return '';
  return TOOL_REASONING_STATE.get(String(id)) || '';
}

function getMessageReasoningContent(message) {
  const value = message?.reasoning_content ?? message?.reasoning ?? message?.thinking;
  if (!value) return '';
  if (typeof value === 'string') return value.trim();
  if (Array.isArray(value)) {
    return value.map(item => {
      if (!item) return '';
      if (typeof item === 'string') return item;
      return item.text || item.reasoning_content || item.thinking || compactJson(item);
    }).filter(Boolean).join('\n').trim();
  }
  return compactJson(value).trim();
}

function uniqueNonEmpty(values) {
  return [...new Set(values.map(value => String(value || '').trim()).filter(Boolean))];
}

function fallbackPartText(part) {
  if (!part) return '';
  if (typeof part === 'string') return part;
  if (part.type === 'text') return part.text || '';
  if (part.type === 'image') return '[image]';
  if (part.type === 'tool_result') return extractText(part.content);
  if (part.type === 'tool_use') return `${part.name || 'tool'}(${compactJson(part.input || {})})`;
  if (part.type === 'thinking' && part.thinking) return `[thinking] ${part.thinking}`;
  if (part.type === 'redacted_thinking') return '[redacted_thinking]';
  if (part.text) return String(part.text);
  if (part.content) return extractText(part.content);
  return `[${part.type || 'content'}] ${compactJson(part)}`;
}

function extractText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.map(fallbackPartText).filter(Boolean).join('\n');
}

function estimateInputTokens(reqBody) {
  const pieces = [];
  if (reqBody.system) pieces.push(extractText(reqBody.system));
  for (const msg of reqBody.messages || []) pieces.push(extractText(msg.content));
  return Math.max(1, Math.ceil(pieces.join('\n').length / 4));
}

function sanitizeOpenAiToolName(name, index) {
  const fallback = `tool_${index}`;
  const cleaned = String(name || fallback).replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 64);
  return cleaned || fallback;
}

function buildToolNameMaps(tools) {
  const originalToOpen = {};
  const openToOriginal = {};
  (tools || []).forEach((tool, index) => {
    const original = String(tool.name || `tool_${index}`);
    let openName = sanitizeOpenAiToolName(original, index);
    let suffix = 2;
    while (openToOriginal[openName] && openToOriginal[openName] !== original) {
      const suffixText = `_${suffix++}`;
      openName = sanitizeOpenAiToolName(original, index).slice(0, 64 - suffixText.length) + suffixText;
    }
    originalToOpen[original] = openName;
    openToOriginal[openName] = original;
  });
  return { originalToOpen, openToOriginal };
}

function toOpenAiToolName(name, toolMaps) {
  return toolMaps.originalToOpen[name] || sanitizeOpenAiToolName(name, 0);
}

function fromOpenAiToolName(name, toolMaps) {
  const cleaned = String(name || '').replace(/^functions\./, '').replace(/:\d+$/, '');
  return toolMaps.openToOriginal[cleaned] || cleaned || 'tool';
}

function toOpenAiTools(tools, toolMaps) {
  return (tools || []).map((tool, index) => ({
    type: 'function',
    function: {
      name: toOpenAiToolName(tool.name || `tool_${index}`, toolMaps),
      description: tool.description || '',
      parameters: tool.input_schema || { type: 'object', properties: {} }
    }
  }));
}

function toOpenAiToolChoice(toolChoice, toolMaps) {
  if (!toolChoice) return undefined;
  if (typeof toolChoice === 'string') return toolChoice;
  if (toolChoice.type === 'auto') return 'auto';
  if (toolChoice.type === 'any') return 'required';
  if (toolChoice.type === 'none') return 'none';
  if (toolChoice.type === 'tool' && toolChoice.name) {
    return { type: 'function', function: { name: toOpenAiToolName(toolChoice.name, toolMaps) } };
  }
  return undefined;
}

function toOpenAiMessages(reqBody, toolMaps) {
  const out = [];
  const system = extractText(reqBody.system);
  if (system) {
    out.push({ role: 'system', content: system });
  }

  function textOnlyUserContent(parts) {
    const text = extractText(parts).trim();
    return text || '';
  }

  for (const msg of reqBody.messages || []) {
    const role = msg.role === 'assistant' ? 'assistant' : 'user';

    if (role === 'assistant' && Array.isArray(msg.content)) {
      const textParts = [];
      const toolCalls = [];
      const reasoningParts = [];
      for (const part of msg.content) {
        if (part.type === 'text') {
          textParts.push(part.text || '');
        } else if (part.type === 'thinking') {
          if (part.thinking) reasoningParts.push(part.thinking);
        } else if (part.type === 'redacted_thinking') {
          if (part.data) reasoningParts.push(part.data);
        } else if (part.type === 'tool_use') {
          const rememberedReasoning = getRememberedToolReasoning(part.id);
          if (rememberedReasoning) reasoningParts.push(rememberedReasoning);
          toolCalls.push({
            id: part.id || makeId('call_'),
            type: 'function',
            function: {
              name: toOpenAiToolName(part.name, toolMaps),
              arguments: JSON.stringify(part.input || {})
            }
          });
        } else {
          const text = fallbackPartText(part);
          if (text) textParts.push(text);
        }
      }
      const assistantMessage = { role: 'assistant', content: textParts.join('\n') || null };
      if (toolCalls.length) assistantMessage.tool_calls = toolCalls;
      const reasoning = uniqueNonEmpty(reasoningParts).join('\n');
      if (reasoning) assistantMessage.reasoning_content = reasoning;
      out.push(assistantMessage);
      continue;
    }

    if (role === 'user' && Array.isArray(msg.content)) {
      let userParts = [];
      let emitted = false;
      const flushText = () => {
        if (!userParts.length) return;
        out.push({ role: 'user', content: textOnlyUserContent(userParts) });
        userParts = [];
        emitted = true;
      };

      for (const part of msg.content) {
        if (part.type === 'tool_result') {
          flushText();
          out.push({
            role: 'tool',
            tool_call_id: part.tool_use_id || part.id || makeId('call_'),
            content: extractText(part.content) || (part.is_error ? 'Tool returned an error.' : '')
          });
          emitted = true;
        } else if (part.type !== 'tool_use') {
          userParts.push(part);
        }
      }
      flushText();
      if (!emitted) out.push({ role: 'user', content: textOnlyUserContent(msg.content) });
      continue;
    }

    out.push({ role, content: extractText(msg.content) });
  }

  if (out.length === 0) out.push({ role: 'user', content: '' });
  return out;
}

function cleanOpenCodeRequest(reqBody) {
  const toolMaps = buildToolNameMaps(reqBody.tools || []);
  const body = {
    model: reqBody.model || process.env.CC_DEFAULT_MODEL || DEFAULT_MODEL,
    messages: toOpenAiMessages(reqBody, toolMaps),
    stream: false
  };

  const maxTokens = Number(reqBody.max_tokens || reqBody.max_completion_tokens || 0);
  if (Number.isFinite(maxTokens) && maxTokens > 0) body.max_tokens = maxTokens;

  const tools = toOpenAiTools(reqBody.tools, toolMaps);
  if (tools.length) {
    body.tools = tools;
    body.tool_choice = toOpenAiToolChoice(reqBody.tool_choice, toolMaps) || 'auto';
  }
  if (reqBody.temperature !== undefined) body.temperature = reqBody.temperature;
  if (reqBody.top_p !== undefined) body.top_p = reqBody.top_p;
  if (reqBody.stop_sequences !== undefined) body.stop = reqBody.stop_sequences;
  if (reqBody.response_format !== undefined) body.response_format = reqBody.response_format;
  if (reqBody.parallel_tool_calls !== undefined) body.parallel_tool_calls = reqBody.parallel_tool_calls;

  return body;
}

function parseProviderError(body, fallback) {
  try {
    const parsed = JSON.parse(body);
    if (parsed.error?.message) return parsed.error.message;
    if (typeof parsed.error === 'string') return parsed.error;
    if (parsed.message) return parsed.message;
  } catch (e) {
    // Keep fallback for non-JSON errors.
  }
  return fallback;
}

function errorTypeForStatus(status) {
  if (status === 401 || status === 403) return 'authentication_error';
  if (status === 400 || status === 404) return 'invalid_request_error';
  if (status === 429) return 'rate_limit_error';
  return 'api_error';
}

function writeAnthropicError(res, status, type, message) {
  res.writeHead(status || 502, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    type: 'error',
    error: { type, message: `${PROVIDER}: ${message}` }
  }));
}

function upstreamPostJson(urlText, payload, apiKey) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlText);
    const encoded = JSON.stringify(payload);
    const client = url.protocol === 'http:' ? http : https;
    const req = client.request({
      protocol: url.protocol,
      hostname: url.hostname,
      port: url.port || (url.protocol === 'http:' ? 80 : 443),
      path: `${url.pathname}${url.search}`,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(encoded),
        'Authorization': `Bearer ${apiKey}`
      }
    }, response => {
      let body = '';
      response.on('data', chunk => body += chunk);
      response.on('end', () => resolve({
        status: response.statusCode || 502,
        headers: response.headers,
        body
      }));
    });
    req.on('error', reject);
    req.write(encoded);
    req.end();
  });
}

function normalizeContent(content) {
  if (typeof content === 'string') return [{ type: 'text', text: content }];
  if (!Array.isArray(content)) return [];
  const out = [];
  for (const part of content) {
    if (!part) continue;
    if (typeof part === 'string') out.push({ type: 'text', text: part });
    else if (part.type === 'text') out.push({ type: 'text', text: part.text || '' });
    else if (part.text) out.push({ type: 'text', text: String(part.text) });
    else out.push({ type: 'text', text: compactJson(part) });
  }
  return out.filter(part => part.text !== '');
}

function openAiContentToText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.map(part => {
    if (!part) return '';
    if (typeof part === 'string') return part;
    if (part.type === 'text') return part.text || '';
    if (part.text) return String(part.text);
    return compactJson(part);
  }).filter(Boolean).join('\n');
}

function contentBlocksFromOpenAiMessage(message, anthropicReq) {
  const toolMaps = buildToolNameMaps(anthropicReq.tools || []);
  const blocks = [];
  const text = openAiContentToText(message.content);
  const reasoning = getMessageReasoningContent(message);
  if (text) blocks.push({ type: 'text', text });

  for (const toolCall of message.tool_calls || []) {
    const fn = toolCall.function || {};
    const args = typeof fn.arguments === 'string' ? fn.arguments : compactJson(fn.arguments || {});
    const block = {
      type: 'tool_use',
      id: String(toolCall.id || '').startsWith('toolu_') ? toolCall.id : makeId('toolu_'),
      name: fromOpenAiToolName(fn.name, toolMaps),
      input: safeParseJson(args)
    };
    if (reasoning) rememberToolReasoning(block.id, reasoning);
    blocks.push(block);
  }

  if (!blocks.length) blocks.push({ type: 'text', text: '' });
  return blocks;
}

function stopReasonFromChoice(choice, contentBlocks) {
  if (contentBlocks.some(block => block.type === 'tool_use')) return 'tool_use';
  if (choice.finish_reason === 'length') return 'max_tokens';
  if (choice.finish_reason === 'content_filter') return 'stop_sequence';
  return choice.finish_reason === 'stop' ? 'end_turn' : (choice.finish_reason || 'end_turn');
}

function normalizeOpenCodeResponse(providerBody, requestedModel, fallbackInputTokens, anthropicReq) {
  const choice = Array.isArray(providerBody.choices) ? providerBody.choices[0] : null;
  const message = choice?.message || {};
  const content = choice
    ? contentBlocksFromOpenAiMessage(message, anthropicReq)
    : normalizeContent(providerBody.content);
  const usage = providerBody.usage || {};
  return {
    id: makeId('msg_proxy_'),
    type: 'message',
    role: 'assistant',
    model: requestedModel || DEFAULT_MODEL,
    content: content.length ? content : [{ type: 'text', text: '' }],
    stop_reason: providerBody.stop_reason || stopReasonFromChoice(choice || {}, content),
    stop_sequence: providerBody.stop_sequence || null,
    usage: {
      input_tokens: Number.isFinite(usage.input_tokens) ? usage.input_tokens : (Number.isFinite(usage.prompt_tokens) ? usage.prompt_tokens : fallbackInputTokens),
      output_tokens: Number.isFinite(usage.output_tokens) ? usage.output_tokens : (Number.isFinite(usage.completion_tokens) ? usage.completion_tokens : 0),
      cache_creation_input_tokens: Number.isFinite(usage.cache_creation_input_tokens) ? usage.cache_creation_input_tokens : 0,
      cache_read_input_tokens: Number.isFinite(usage.cache_read_input_tokens) ? usage.cache_read_input_tokens : 0
    }
  };
}

function sse(res, event, payload) {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function emitContentBlocks(res, blocks) {
  blocks.forEach((block, index) => {
    if (block.type === 'tool_use') {
      sse(res, 'content_block_start', {
        type: 'content_block_start',
        index,
        content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} }
      });
      sse(res, 'content_block_delta', {
        type: 'content_block_delta',
        index,
        delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input || {}) }
      });
      sse(res, 'content_block_stop', { type: 'content_block_stop', index });
      return;
    }

    sse(res, 'content_block_start', {
      type: 'content_block_start',
      index,
      content_block: { type: 'text', text: '' }
    });
    if (block.text) {
      sse(res, 'content_block_delta', {
        type: 'content_block_delta',
        index,
        delta: { type: 'text_delta', text: block.text }
      });
    }
    sse(res, 'content_block_stop', { type: 'content_block_stop', index });
  });
}

function writeFakeAnthropicStream(res, message) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive'
  });

  sse(res, 'message_start', {
    type: 'message_start',
    message: {
      id: message.id,
      type: 'message',
      role: 'assistant',
      model: message.model,
      content: [],
      stop_reason: null,
      stop_sequence: null,
      usage: {
        input_tokens: message.usage.input_tokens,
        output_tokens: 0,
        cache_creation_input_tokens: message.usage.cache_creation_input_tokens || 0,
        cache_read_input_tokens: message.usage.cache_read_input_tokens || 0
      }
    }
  });
  emitContentBlocks(res, message.content || []);
  sse(res, 'message_delta', {
    type: 'message_delta',
    delta: {
      stop_reason: message.stop_reason,
      stop_sequence: message.stop_sequence
    },
    usage: { output_tokens: message.usage.output_tokens }
  });
  sse(res, 'message_stop', { type: 'message_stop' });
  res.end();
}

function writeModels(res) {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    object: 'list',
    data: AVAILABLE_MODELS.map(model => ({
      id: model,
      object: 'model',
      type: 'model'
    }))
  }));
}

const server = http.createServer(async (req, res) => {
  const apiKey = getApiKey(req);
  const path = new URL(req.url || '/', 'http://127.0.0.1').pathname;

  if (req.method === 'GET' && (path === '/health' || path === '/')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: true, model: DEFAULT_MODEL }));
  }

  if (!apiKey) {
    return writeAnthropicError(res, 401, 'authentication_error', 'Missing API key');
  }

  if (req.method === 'GET' && path === '/v1/models') {
    return writeModels(res);
  }

  if (req.method === 'POST' && path === '/v1/messages/count_tokens') {
    let parsed;
    try {
      parsed = JSON.parse(await readBody(req) || '{}');
    } catch (e) {
      return writeAnthropicError(res, 400, 'invalid_request_error', 'Invalid JSON body');
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ input_tokens: estimateInputTokens(parsed) }));
  }

  if (req.method !== 'POST' || path !== '/v1/messages') {
    return writeAnthropicError(res, 404, 'not_found_error', `Unsupported endpoint ${req.method} ${path}`);
  }

  let anthropicReq;
  try {
    anthropicReq = JSON.parse(await readBody(req) || '{}');
  } catch (e) {
    return writeAnthropicError(res, 400, 'invalid_request_error', 'Invalid JSON body');
  }

  const requestedStream = anthropicReq.stream === true;
  const cleaned = cleanOpenCodeRequest(anthropicReq);
  const fallbackInputTokens = estimateInputTokens(anthropicReq);

  try {
    const upstream = await upstreamPostJson(UPSTREAM_CHAT_URL, cleaned, apiKey);
    if (upstream.status < 200 || upstream.status >= 300) {
      const message = parseProviderError(upstream.body, `Upstream returned HTTP ${upstream.status}`);
      return writeAnthropicError(res, upstream.status, errorTypeForStatus(upstream.status), `OpenCode upstream HTTP ${upstream.status}: ${message}`);
    }

    let providerBody;
    try {
      providerBody = JSON.parse(upstream.body || '{}');
    } catch (e) {
      return writeAnthropicError(res, 502, 'api_error', 'OpenCode returned non-JSON response');
    }

    const normalized = normalizeOpenCodeResponse(providerBody, cleaned.model, fallbackInputTokens, anthropicReq);
    if (requestedStream) return writeFakeAnthropicStream(res, normalized);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(normalized));
  } catch (e) {
    return writeAnthropicError(res, 502, 'api_error', e.message || 'OpenCode request failed');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`OpenCode Nemotron proxy ready on http://127.0.0.1:${PORT}`);
});

server.on('error', e => {
  console.error('Proxy error:', e.message);
  process.exit(1);
});
