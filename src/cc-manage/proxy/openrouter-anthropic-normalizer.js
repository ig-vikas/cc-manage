process.env.CC_PROVIDER = process.env.CC_PROVIDER || 'openrouter';
process.env.CC_PROVIDER_MODE = process.env.CC_PROVIDER_MODE || 'openai-chat-proxy';
process.env.CC_UPSTREAM_BASE_URL = 'https://openrouter.ai/api/v1';
process.env.CC_MODELS = process.env.CC_MODELS || 'baidu/cobuddy:free';

require('./openai-chat-proxy');

