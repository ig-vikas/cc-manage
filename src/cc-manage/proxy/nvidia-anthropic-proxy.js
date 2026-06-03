process.env.CC_PROVIDER = process.env.CC_PROVIDER || 'nvidia';
process.env.CC_PROVIDER_MODE = process.env.CC_PROVIDER_MODE || 'openai-chat-proxy';
process.env.CC_UPSTREAM_BASE_URL = 'https://integrate.api.nvidia.com/v1';
process.env.CC_MODELS = process.env.CC_MODELS || [
  'qwen/qwen3.5-397b-a17b',
  'nvidia/nemotron-3-super-120b-a12b',
  'qwen/qwen3.5-122b-a10b',
  'z-ai/glm-5.1'
].join(',');

require('./openai-chat-proxy');

