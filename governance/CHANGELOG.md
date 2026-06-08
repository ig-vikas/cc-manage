# Changelog

## Unreleased

- Added OpenCode Nemotron provider support through a dedicated local proxy.
- Added OpenCode-safe request cleaning for Claude-only thinking, metadata, container, MCP, service tier, and beta fields while preserving tool calls/results.
- Routed OpenCode Nemotron through OpenCode Zen's documented `/v1/chat/completions` endpoint and token-style local auth mode.
- Added Anthropic-compatible response normalization and fake SSE streaming for OpenCode/Nemotron responses.

## v2.0.0

- Added provider-aware V2 implementation plan.
- Added `.env` key-name based profile migration design.
- Added production repo docs and secret-handling policy.
- Added shared OpenAI-compatible proxy plan and implementation.
- Added Gemini tool-call and thought-signature support.
- Added dynamic Groq model discovery requirement and CLI command.
