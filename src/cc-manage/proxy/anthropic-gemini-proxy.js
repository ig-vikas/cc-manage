const http = require('http');
const https = require('https');
const fs = require('fs');

const PORT = parseInt(process.argv[2], 10) || 18000;
const AI_STUDIO_HOST = 'generativelanguage.googleapis.com';
const AVAILABLE_MODELS = [
  'gemini-3.5-flash',
  'gemini-3-flash-preview',
  'gemini-3.1-flash-lite',
  'gemini-2.5-flash',
  'gemini-2.0-flash',
  'gemini-2.0-flash-lite'
];
const TOOL_CALL_STATE = new Map();
const MAX_TOOL_CALL_STATE = 500;

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

function rememberToolCall(id, state) {
  if (!id || !state) return;
  TOOL_CALL_STATE.set(id, state);
  while (TOOL_CALL_STATE.size > MAX_TOOL_CALL_STATE) {
    const oldestKey = TOOL_CALL_STATE.keys().next().value;
    TOOL_CALL_STATE.delete(oldestKey);
  }
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

function estimateInputTokens(anthropicReq) {
  const pieces = [];
  if (anthropicReq.system) pieces.push(extractText(anthropicReq.system));
  for (const msg of anthropicReq.messages || []) pieces.push(extractText(msg.content));
  return Math.max(1, Math.ceil(pieces.join('\n').length / 4));
}

function mapModel(model) {
  return String(model || '').replace(/^google\//, '');
}

function parseProviderError(body, fallback) {
  try {
    const parsed = JSON.parse(body);
    if (parsed.error?.message) return parsed.error.message;
    if (typeof parsed.error === 'string') return parsed.error;
    if (parsed.message) return parsed.message;
  } catch (e) {
    // Fall through to the fallback for non-JSON errors.
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
    error: { type, message }
  }));
}

function sanitizeGeminiToolName(name, index) {
  let cleaned = String(name || `tool_${index}`).replace(/[^a-zA-Z0-9_]/g, '_').slice(0, 64);
  if (!/^[a-zA-Z_]/.test(cleaned)) cleaned = `tool_${cleaned}`.slice(0, 64);
  return cleaned || `tool_${index}`;
}

function buildToolNameMaps(tools) {
  const originalToGemini = {};
  const geminiToOriginal = {};
  (tools || []).forEach((tool, index) => {
    const original = String(tool.name || `tool_${index}`);
    let geminiName = sanitizeGeminiToolName(original, index);
    let suffix = 2;
    while (geminiToOriginal[geminiName] && geminiToOriginal[geminiName] !== original) {
      const suffixText = `_${suffix++}`;
      geminiName = sanitizeGeminiToolName(original, index).slice(0, 64 - suffixText.length) + suffixText;
    }
    originalToGemini[original] = geminiName;
    geminiToOriginal[geminiName] = original;
  });
  return { originalToGemini, geminiToOriginal };
}

function toGeminiToolName(name, toolMaps) {
  return toolMaps.originalToGemini[name] || sanitizeGeminiToolName(name, 0);
}

function fromGeminiToolName(name, toolMaps) {
  const cleaned = String(name || '').replace(/^functions\./, '').replace(/:\d+$/, '');
  return toolMaps.geminiToOriginal[cleaned] || cleaned || 'tool';
}

function toGeminiSchema(schema) {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    return { type: 'object', properties: {} };
  }

  const src = { ...schema };
  const out = {};
  let type = src.type;
  if (Array.isArray(type)) {
    const nonNull = type.find(t => t !== 'null');
    if (type.includes('null')) out.nullable = true;
    type = nonNull || 'string';
  }

  if (typeof type === 'string') out.type = type.toLowerCase();
  if (src.description) out.description = src.description;
  if (Array.isArray(src.enum)) out.enum = src.enum;
  if (src.format) out.format = src.format;
  if (src.nullable === true) out.nullable = true;
  if (Array.isArray(src.required)) out.required = src.required;

  if (src.properties && typeof src.properties === 'object') {
    out.properties = {};
    for (const [key, value] of Object.entries(src.properties)) {
      out.properties[key] = toGeminiSchema(value);
    }
  }

  if (src.items) out.items = toGeminiSchema(src.items);

  if (!out.type) {
    if (out.properties) out.type = 'object';
    else if (out.items) out.type = 'array';
    else out.type = 'string';
  }

  return out;
}

function toGeminiTools(tools, toolMaps) {
  const declarations = (tools || []).map((tool, index) => ({
    name: toGeminiToolName(tool.name || `tool_${index}`, toolMaps),
    description: tool.description || '',
    parameters: toGeminiSchema(tool.input_schema || { type: 'object', properties: {} })
  }));
  return declarations.length ? [{ functionDeclarations: declarations }] : undefined;
}

function toGeminiToolConfig(toolChoice, toolMaps) {
  if (!toolChoice) return undefined;
  if (typeof toolChoice === 'string') {
    if (toolChoice === 'none') return { functionCallingConfig: { mode: 'NONE' } };
    if (toolChoice === 'required') return { functionCallingConfig: { mode: 'ANY' } };
    return { functionCallingConfig: { mode: 'AUTO' } };
  }
  if (toolChoice.type === 'none') return { functionCallingConfig: { mode: 'NONE' } };
  if (toolChoice.type === 'any') return { functionCallingConfig: { mode: 'ANY' } };
  if (toolChoice.type === 'tool' && toolChoice.name) {
    return {
      functionCallingConfig: {
        mode: 'ANY',
        allowedFunctionNames: [toGeminiToolName(toolChoice.name, toolMaps)]
      }
    };
  }
  return { functionCallingConfig: { mode: 'AUTO' } };
}

function toGoogleRole(role) {
  return role === 'assistant' ? 'model' : 'user';
}

function pushContent(contents, role, parts) {
  const cleanParts = (parts || []).filter(Boolean);
  if (!cleanParts.length) return;
  const last = contents[contents.length - 1];
  if (last && last.role === role) {
    last.parts.push(...cleanParts);
  } else {
    contents.push({ role, parts: cleanParts });
  }
}

function toolResultPayload(part) {
  const text = extractText(part.content);
  const parsed = safeParseJson(text);
  if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) && Object.keys(parsed).length) {
    return parsed;
  }
  if (part.is_error) return { error: text || 'Tool returned an error.' };
  if (text) return { result: text };
  return { result: '' };
}

function toGoogleContents(messages, toolMaps) {
  const contents = [];
  const toolIdToName = {};

  for (const msg of messages || []) {
    const role = toGoogleRole(msg.role);
    const parts = [];

    if (Array.isArray(msg.content)) {
      for (const part of msg.content) {
        if (part.type === 'text') {
          parts.push({ text: part.text || '' });
        } else if (part.type === 'image' && part.source) {
          const source = part.source || {};
          if (source.type === 'url' || source.url) {
            parts.push({
              fileData: {
                mimeType: source.media_type || source.mediaType || 'image/png',
                fileUri: source.url
              }
            });
          } else if (source.data) {
            parts.push({
              inlineData: {
                mimeType: source.media_type || source.mediaType || 'image/png',
                data: source.data
              }
            });
          }
        } else if (part.type === 'tool_use') {
          const name = toGeminiToolName(part.name, toolMaps);
          if (part.id) toolIdToName[part.id] = name;
          const functionCallPart = { functionCall: { name, args: part.input || {} } };
          const remembered = TOOL_CALL_STATE.get(part.id);
          if (remembered?.thoughtSignature) functionCallPart.thoughtSignature = remembered.thoughtSignature;
          parts.push(functionCallPart);
        } else if (part.type === 'tool_result') {
          const remembered = TOOL_CALL_STATE.get(part.tool_use_id);
          const name = toolIdToName[part.tool_use_id] || remembered?.name || toGeminiToolName(part.name || 'tool_result', toolMaps);
          parts.push({ functionResponse: { name, response: toolResultPayload(part) } });
        } else {
          const text = fallbackPartText(part);
          if (text) parts.push({ text });
        }
      }
    } else if (typeof msg.content === 'string') {
      parts.push({ text: msg.content });
    }

    pushContent(contents, role, parts.length ? parts : [{ text: extractText(msg.content) }]);
  }

  return contents;
}

function buildGoogleBody(anthropicReq) {
  const toolMaps = buildToolNameMaps(anthropicReq.tools || []);
  const body = {
    contents: toGoogleContents(anthropicReq.messages || [], toolMaps),
    generationConfig: { maxOutputTokens: anthropicReq.max_tokens || 8192 }
  };
  if (anthropicReq.temperature !== undefined) body.generationConfig.temperature = anthropicReq.temperature;

  const system = extractText(anthropicReq.system || '');
  if (system) body.systemInstruction = { parts: [{ text: system }] };

  const tools = toGeminiTools(anthropicReq.tools, toolMaps);
  if (tools) {
    body.tools = tools;
    body.toolConfig = toGeminiToolConfig(anthropicReq.tool_choice, toolMaps) || { functionCallingConfig: { mode: 'AUTO' } };
  }
  return body;
}

function writeModels(res) {
  const data = AVAILABLE_MODELS.map(id => ({
    id,
    type: 'model',
    display_name: id,
    created_at: '2026-01-01T00:00:00Z'
  }));
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    data,
    has_more: false,
    first_id: data[0] ? data[0].id : null,
    last_id: data.length ? data[data.length - 1].id : null
  }));
}

function requestGoogle(path, postData) {
  return new Promise((resolve, reject) => {
    const u = new URL('https://' + AI_STUDIO_HOST + path);
    const opts = {
      hostname: u.hostname,
      port: 443,
      path: u.pathname + u.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      }
    };
    const proxyReq = https.request(opts, proxyRes => {
      let data = '';
      proxyRes.on('data', c => data += c);
      proxyRes.on('end', () => resolve({ status: proxyRes.statusCode, headers: proxyRes.headers, body: data }));
    });
    proxyReq.on('error', reject);
    proxyReq.write(postData);
    proxyReq.end();
  });
}

function debugLog(endpoint, postData) {
  if (process.env.GEMINI_PROXY_DEBUG !== '1') return;
  const loggedEndpoint = endpoint.replace(/key=[^&]+/, 'key=<redacted>');
  fs.appendFileSync('proxy_debug.log', `[REQ] ${loggedEndpoint}\n${postData}\n\n`);
}

function contentBlocksFromGoogleParts(parts, anthropicReq) {
  const toolMaps = buildToolNameMaps(anthropicReq.tools || []);
  const blocks = [];
  let text = '';

  for (const part of parts || []) {
    if (part.text) text += part.text;
    if (part.functionCall) {
      if (text) {
        blocks.push({ type: 'text', text });
        text = '';
      }
      const id = makeId('toolu_');
      rememberToolCall(id, {
        name: part.functionCall.name,
        args: part.functionCall.args || {},
        thoughtSignature: part.thoughtSignature || part.thought_signature
      });
      blocks.push({
        type: 'tool_use',
        id,
        name: fromGeminiToolName(part.functionCall.name, toolMaps),
        input: part.functionCall.args || {}
      });
    } else if (!part.text) {
      const fallback = compactJson(part);
      if (fallback && fallback !== '{}') {
        if (text) text += '\n';
        text += fallback;
      }
    }
  }

  if (text) blocks.push({ type: 'text', text });
  if (!blocks.length) blocks.push({ type: 'text', text: '' });
  return blocks;
}

function stopReasonFromCandidate(candidate, blocks) {
  if (blocks.some(block => block.type === 'tool_use')) return 'tool_use';
  if (candidate.finishReason === 'MAX_TOKENS') return 'max_tokens';
  if (candidate.finishReason === 'STOP') return 'end_turn';
  return candidate.finishReason || 'end_turn';
}

function toAnthropicResponse(googleResp, model, anthropicReq) {
  const candidate = googleResp.candidates?.[0] || {};
  const parts = candidate.content?.parts || [];
  const content = contentBlocksFromGoogleParts(parts, anthropicReq);
  const usage = googleResp.usageMetadata || {};
  return {
    id: makeId('msg_'),
    type: 'message',
    role: 'assistant',
    content,
    model,
    stop_reason: stopReasonFromCandidate(candidate, content),
    usage: {
      input_tokens: usage.promptTokenCount || 0,
      output_tokens: usage.candidatesTokenCount || 0
    }
  };
}

function sendSse(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function emitContentBlocks(res, blocks) {
  blocks.forEach((block, index) => {
    if (block.type === 'tool_use') {
      sendSse(res, 'content_block_start', {
        type: 'content_block_start',
        index,
        content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} }
      });
      sendSse(res, 'content_block_delta', {
        type: 'content_block_delta',
        index,
        delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input || {}) }
      });
      sendSse(res, 'content_block_stop', { type: 'content_block_stop', index });
      return;
    }

    sendSse(res, 'content_block_start', {
      type: 'content_block_start',
      index,
      content_block: { type: 'text', text: '' }
    });
    if (block.text) {
      sendSse(res, 'content_block_delta', {
        type: 'content_block_delta',
        index,
        delta: { type: 'text_delta', text: block.text }
      });
    }
    sendSse(res, 'content_block_stop', { type: 'content_block_stop', index });
  });
}

function mergeFunctionCallPart(functionCalls, index, part) {
  const functionCall = part.functionCall || {};
  if (!functionCalls[index]) functionCalls[index] = { name: '', args: {} };
  if (functionCall.name) functionCalls[index].name = functionCall.name;
  if (functionCall.args && typeof functionCall.args === 'object') {
    functionCalls[index].args = { ...functionCalls[index].args, ...functionCall.args };
  } else if (typeof functionCall.args === 'string') {
    functionCalls[index].args = { ...functionCalls[index].args, ...safeParseJson(functionCall.args) };
  }
  if (part.thoughtSignature || part.thought_signature) {
    functionCalls[index].thoughtSignature = part.thoughtSignature || part.thought_signature;
  }
}

function forwardStream(apiKey, anthropicReq, res) {
  const model = anthropicReq.model || AVAILABLE_MODELS[0];
  const googleModel = mapModel(model);
  const endpoint = `/v1beta/models/${googleModel}:generateContent?key=${apiKey}`;
  const postData = JSON.stringify(buildGoogleBody(anthropicReq));
  debugLog(endpoint, postData);

  requestGoogle(endpoint, postData).then(result => {
    if (result.status < 200 || result.status >= 300) {
      return writeAnthropicError(
        res,
        result.status || 502,
        errorTypeForStatus(result.status),
        parseProviderError(result.body, 'Google AI Studio stream failed')
      );
    }

    let googleResp;
    try {
      googleResp = JSON.parse(result.body);
    } catch (e) {
      return writeAnthropicError(res, 502, 'api_error', 'Invalid Google AI Studio response: ' + e.message);
    }

    const candidate = googleResp.candidates?.[0] || {};
    const blocks = contentBlocksFromGoogleParts(candidate.content?.parts || [], anthropicReq);
    const usage = googleResp.usageMetadata || {};

    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no'
    });

    sendSse(res, 'message_start', {
      type: 'message_start',
      message: {
        id: makeId('msg_'),
        type: 'message',
        role: 'assistant',
        content: [],
        model,
        stop_reason: null,
        usage: {
          input_tokens: usage.promptTokenCount || estimateInputTokens(anthropicReq),
          output_tokens: 0
        }
      }
    });
    emitContentBlocks(res, blocks);
    sendSse(res, 'message_delta', {
      type: 'message_delta',
      delta: { stop_reason: stopReasonFromCandidate(candidate, blocks), stop_sequence: null },
      usage: { output_tokens: usage.candidatesTokenCount || 0 }
    });
    sendSse(res, 'message_stop', { type: 'message_stop' });
    res.end();
  }).catch(err => {
    if (!res.headersSent) {
      writeAnthropicError(res, 502, 'api_error', 'Connection to Google AI Studio failed: ' + err.message);
    } else {
      res.end();
    }
  });
}

const server = http.createServer(async (req, res) => {
  const requestPath = (req.url || '').split('?')[0];
  const apiKey = getApiKey(req);

  if (!apiKey) {
    return writeAnthropicError(res, 401, 'authentication_error', 'No API key provided. Set ANTHROPIC_API_KEY to your Google AI Studio API key.');
  }

  if (req.method === 'GET' && requestPath === '/v1/models') return writeModels(res);

  if (req.method !== 'POST' || (requestPath !== '/v1/messages' && requestPath !== '/v1/messages/count_tokens')) {
    return writeAnthropicError(res, 404, 'invalid_request_error', 'Not found. Use POST /v1/messages or /v1/messages/count_tokens');
  }

  let anthropicReq;
  try {
    anthropicReq = JSON.parse(await readBody(req));
  } catch (e) {
    return writeAnthropicError(res, 400, 'invalid_request_error', 'Invalid JSON: ' + e.message);
  }

  if (requestPath === '/v1/messages/count_tokens') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ input_tokens: estimateInputTokens(anthropicReq) }));
  }

  if (anthropicReq.stream === true) return forwardStream(apiKey, anthropicReq, res);

  const model = anthropicReq.model || AVAILABLE_MODELS[0];
  const googleModel = mapModel(model);
  const endpoint = `/v1beta/models/${googleModel}:generateContent?key=${apiKey}`;
  const postData = JSON.stringify(buildGoogleBody(anthropicReq));
  debugLog(endpoint, postData);

  try {
    const result = await requestGoogle(endpoint, postData);
    if (result.status >= 200 && result.status < 300) {
      const googleResp = JSON.parse(result.body);
      const anthropicResp = toAnthropicResponse(googleResp, model, anthropicReq);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(anthropicResp));
    } else {
      writeAnthropicError(
        res,
        result.status || 502,
        errorTypeForStatus(result.status),
        parseProviderError(result.body, 'Google AI Studio API error')
      );
    }
  } catch (e) {
    writeAnthropicError(res, 502, 'api_error', 'Connection to Google AI Studio failed: ' + e.message);
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`AIStudio proxy ready on http://127.0.0.1:${PORT}`);
});

server.on('error', e => {
  console.error('Proxy error:', e.message);
  process.exit(1);
});
