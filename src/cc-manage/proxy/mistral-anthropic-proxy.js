process.env.CC_PROVIDER = process.env.CC_PROVIDER || 'mistral';
process.env.CC_PROVIDER_MODE = process.env.CC_PROVIDER_MODE || 'openai-chat-proxy';
process.env.CC_UPSTREAM_BASE_URL = 'https://api.mistral.ai/v1';
process.env.CC_MODELS = process.env.CC_MODELS || [
  'mistral-large-latest',
  'pixtral-large-latest',
  'ministral-8b-latest'
].join(',');

require('./openai-chat-proxy');
