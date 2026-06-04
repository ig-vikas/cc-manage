process.env.CC_PROVIDER = process.env.CC_PROVIDER || 'mistral-vibe';
process.env.CC_PROVIDER_MODE = process.env.CC_PROVIDER_MODE || 'openai-chat-proxy';
process.env.CC_UPSTREAM_BASE_URL = 'https://api.mistral.ai/v1';
process.env.CC_MODELS = process.env.CC_MODELS || [
  'mistral-vibe-cli-latest',
  'mistral-medium-3.5',
  'devstral-small-latest'
].join(',');

require('./openai-chat-proxy');
