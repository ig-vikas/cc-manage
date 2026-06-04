process.env.CC_PROVIDER = process.env.CC_PROVIDER || 'codestral';
process.env.CC_PROVIDER_MODE = process.env.CC_PROVIDER_MODE || 'openai-chat-proxy';
process.env.CC_UPSTREAM_BASE_URL = 'https://codestral.mistral.ai/v1';
process.env.CC_MODELS = process.env.CC_MODELS || [
  'codestral-latest',
  'codestral-2508'
].join(',');

require('./openai-chat-proxy');
