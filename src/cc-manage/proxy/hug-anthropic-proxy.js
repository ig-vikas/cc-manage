process.env.CC_PROVIDER = process.env.CC_PROVIDER || 'huggingface';
process.env.CC_PROVIDER_MODE = process.env.CC_PROVIDER_MODE || 'openai-chat-proxy';
process.env.CC_UPSTREAM_BASE_URL = 'https://router.huggingface.co/v1';
process.env.CC_MODELS = process.env.CC_MODELS || [
  'moonshotai/Kimi-K2.6',
  'moonshotai/Kimi-K2.5'
].join(',');

require('./openai-chat-proxy');
