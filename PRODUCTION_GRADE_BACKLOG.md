# Production Grade Backlog

This project already has a strong base: profile-wise generated key ids, redacted key listing, numbered profile/model switching, direct and proxy provider modes, local proxy conversion tests, and live smoke scripts.

## Highest Value Additions

- Cross-platform installer scripts for Windows, macOS, and Linux that add launchers to PATH, verify Node and Claude Code, and explain PowerShell Core requirements.
- CI that runs syntax checks for PowerShell, Node proxies, Python tests, and markdown links on every pull request.
- Provider health matrix that records text, streaming, image, tool-call, and tool-result support per model.
- Dynamic model cache with timestamps and a refresh command for providers with changing model catalogs.
- Clear per-provider capability flags such as vision, tools, streaming, reasoning controls, max output tokens, and max request size.
- Safe debug mode that stores redacted request/response traces for proxy troubleshooting.
- Automated profile backup and rollback before migrations or bulk edits.
- Provider-specific payload policies for request limits, unsupported fields, reasoning-only models, and tool schema quirks.
- Integration tests with mock upstreams for Gemini, OpenAI-compatible, Groq, NVIDIA NIM, OpenRouter, and Hugging Face.
- Full macOS/Linux documentation including `pwsh`, executable permissions, PATH setup, and Claude binary discovery.

## Nice To Have

- TUI profile manager with searchable provider/model lists.
- Import/export profile bundles without secrets.
- `cc-manage doctor --fix` for common missing PATH/wrapper/proxy issues.
- `cc-manage provider explain <provider>` to show whether a proxy is required and why.
- Auto-detection for dead OpenRouter/free models with suggested replacements.
- Per-profile rate-limit and retry policy.
- JSON output mode for automation: `cc-manage doctor --json`, `cc-manage models groq --json`.
