# Contributing

Thanks for helping improve the Claude Code Provider Profile Lab.

## Development Checks

Run these before opening a change:

```powershell
[scriptblock]::Create((Get-Content "src\cc-manage\claude-switch.ps1" -Raw)) | Out-Null
node --check "src\cc-manage\proxy\openai-chat-proxy.js"
node --check "src\cc-manage\proxy\anthropic-gemini-proxy.js"
node --check "src\cc-manage\proxy\opencode-nemotron-proxy.js"
$env:CLAUDE_PROFILES_ROOT="$PWD\src\cc-manage"; python tests\test_proxy_conversions.py
```

Run provider health checks when keys are available:

```powershell
cc-manage doctor
cc-manage test hug-kimi moonshotai/Kimi-K2.6
cc-manage test api-test-gemini-working gemini-2.5-flash --level tools
```

## Coding Guidelines

- Keep provider behavior in the provider registry where possible.
- Keep request/response translation inside proxy adapters.
- Do not print raw secrets.
- Return actionable errors with provider, model, status, and remedy.
- Prefer shared proxies over one-off provider scripts unless the API shape truly differs.

## Pull Request Checklist

- PowerShell scripts parse successfully.
- Node proxies pass `node --check`.
- `.env.example` is updated for new providers.
- README or provider docs are updated.
- Tests do not require real API keys unless clearly marked as integration checks.
