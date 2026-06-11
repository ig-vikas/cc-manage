# cc-manage

Provider-aware profile management for Claude Code.

`cc-manage` installs a small local command layer for switching Claude Code profiles, models, API keys, and provider modes without hand-editing runtime files. It is built for people who move between Anthropic-compatible APIs, Gemini, OpenAI-compatible providers, Mistral, Mistral Vibe, Codestral, OpenCode Zen, NVIDIA NIM, Hugging Face, OpenRouter, Groq, and custom endpoints.

The important idea: Claude Code expects an Anthropic Messages-style API surface. Many excellent model providers expose Gemini APIs, OpenAI Chat Completions, or provider-specific variants instead. `cc-manage` bridges those differences with local compatibility proxies that translate requests and responses into a Claude Code-compatible structure.

Repository: [ig-vikas/cc-manage](https://github.com/ig-vikas/cc-manage)

## Highlights

- Profile and model switching through `cc-switch`, `cc`, and `cc-manage`.
- Provider-first setup, including Anthropic, Gemini, Groq, Mistral, Mistral Vibe, Codestral, OpenCode Zen, NVIDIA NIM, Hugging Face, OpenRouter, DeepSeek, Fireworks, Together, xAI, Ollama Cloud, and custom OpenAI-compatible endpoints.
- Multiple local compatibility proxies that normalize provider APIs into the request, streaming, tool-call, tool-result, usage, stop-reason, and error shapes Claude Code can work with.
- Dedicated provider wrappers for Mistral, Mistral Vibe, Codestral, OpenCode Zen, NVIDIA NIM, Hugging Face, Gemini, and OpenRouter normalization.
- Dynamic model refresh where supported, including Groq, Mistral, Mistral Vibe, and NVIDIA NIM.
- Local secret handling with generated profile key IDs, so runtime profile files reference key names instead of storing raw API keys.
- Local proxy contract tests for conversion behavior across non-Anthropic providers.

## Install From GitHub

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/ig-vikas/cc-manage/main/install.ps1 | iex
```

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/ig-vikas/cc-manage/main/install.sh | sh
```

After install:

```powershell
cc-manage doctor
cc-manage add
cc-switch
cc
```

API keys are entered through `cc-manage add` or `cc-manage key set <KEY_ID>` and saved locally in `~/.claude-profiles/.env`.

`cc-manage` also repairs Claude Code's persistent `~/.claude/settings.json` when you run `cc-manage doctor` or launch through `cc`. It removes cc-manage-managed Anthropic auth/base/model overrides from that file so Claude Code does not see both `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY`. Other settings, such as unrelated `env` entries, are preserved. You can run the repair directly with:

```powershell
cc-manage settings repair
```

## How It Works

`cc-manage` keeps provider configuration, profile metadata, proxy startup, and key lookup in one predictable workflow:

1. Select a provider with `cc-manage add`.
2. Choose or enter the API key used by that provider.
3. Select a model from defaults or a refreshed provider model list.
4. Let `cc-manage` configure direct mode or a local proxy automatically.
5. Launch Claude Code through `cc` or switch profiles through `cc-switch`.

Mistral Vibe, Codestral, and OpenCode Zen are first-class provider choices in the provider picker. They use local proxy wrappers with provider-specific defaults so Claude Code can interact with their chat endpoints through the expected Anthropic-compatible message structure.

## Compatibility Proxy Layer

The proxy layer is the core bridge between Claude Code and providers that do not expose Anthropic Messages directly. When a selected provider needs translation, `cc-manage` starts a local proxy on `127.0.0.1`, points Claude Code at that local endpoint, and forwards normalized traffic to the upstream provider.

| Proxy mode | Used for | Professional role |
| --- | --- | --- |
| `anthropic-direct` | Anthropic, OpenRouter, DeepSeek, Fireworks | Sends Claude Code's Anthropic Messages requests directly to compatible upstream APIs. |
| `gemini-proxy` | Gemini | Converts Anthropic Messages to Gemini `generateContent` and maps Gemini responses back into Claude Code-compatible content blocks, streaming events, tools, and errors. |
| `openai-chat-proxy` | Groq, Together, xAI, Ollama Cloud, custom OpenAI-compatible endpoints | Converts Anthropic Messages to OpenAI Chat Completions and normalizes text, images, tool calls, tool results, usage, stop reasons, streaming, and provider errors. |
| `mistral-proxy` | Mistral | Wraps the shared OpenAI-compatible proxy with Mistral defaults and dynamic model discovery. |
| `mistral-vibe-proxy` | Mistral Vibe | Wraps Mistral chat completions with Mistral Vibe key and model defaults, including `mistral-vibe-cli-latest`. |
| `codestral-proxy` | Codestral | Wraps `https://codestral.mistral.ai/v1/chat/completions` for Claude Code-compatible chat usage. Codestral FIM remains available upstream at `/v1/fim/completions`. |
| `opencode-zen-proxy` | OpenCode Zen | Converts Claude Code's Anthropic Messages request to OpenCode's documented `https://opencode.ai/zen/v1/chat/completions` shape, preserves tool calls/results through OpenAI function-calling fields, strips Claude-only thinking/container metadata, disables upstream streaming, and rebuilds Claude Code-compatible JSON or SSE responses. |
| `nvidia-proxy` | NVIDIA NIM | Adds NVIDIA NIM defaults, model discovery, and request-size guardrails over the shared OpenAI-compatible proxy. |
| `huggingface-proxy` | Hugging Face | Adds Hugging Face defaults over the shared OpenAI-compatible proxy path. |

The result is a clean Claude Code-facing API shape even when the upstream model provider speaks a different protocol.

## Design Boundary

`cc-manage` is intentionally not an AI-insertion layer for competitive programming editors or contest workflows. Competitive programming works best when the attention stays on reading the statement, forming invariants, testing ideas, and debugging from first principles. An always-on assistant can make help too immediate, break concentration, and turn practice into answer-chasing instead of skill-building.

This project keeps that boundary clear. It manages Claude Code provider profiles and compatibility proxies; it does not place AI inside CP loops where the user is trying to train focus, speed, and independent problem-solving.

## Provider Support

| Provider | Mode | Notes |
| --- | --- | --- |
| Anthropic | Direct | Native Claude Code-compatible API behavior. |
| OpenRouter | Direct | Uses OpenRouter's Anthropic-compatible path by default. |
| Gemini | Proxy | Dedicated Gemini request and response conversion. |
| Groq | Proxy | OpenAI-compatible proxy with dynamic model refresh. |
| Mistral | Proxy | Mistral chat completions through local normalization. |
| Mistral Vibe | Proxy | Mistral Vibe provider entry with dedicated key and model defaults. |
| Codestral | Proxy | Codestral chat completions through local normalization. |
| OpenCode Zen | Proxy | OpenCode `/zen/v1/chat/completions` with tool-call conversion, Claude-only fields stripped, and Anthropic-compatible response shaping. |
| NVIDIA NIM | Proxy | NVIDIA hosted models with dynamic model refresh. |
| Hugging Face | Proxy | Hugging Face model access through local normalization. |
| DeepSeek | Direct | Anthropic-compatible base URL. |
| Fireworks | Direct | Anthropic-compatible base URL. |
| Together | Proxy | OpenAI-compatible proxy mode. |
| xAI | Proxy | OpenAI-compatible proxy mode. |
| Ollama Cloud | Proxy | OpenAI-compatible proxy mode. |
| Custom OpenAI-compatible | Proxy | Bring your own base URL and model name. |

## Useful Commands

```powershell
cc-manage -help
cc-manage -help commands
cc-manage -help uninstall
cc-manage doctor
cc-manage add
cc-manage edit
cc-manage key list
cc-manage models groq --refresh
cc-manage models mistral --refresh
cc-manage models mistral-vibe --refresh
cc-manage models nvidia-nim --refresh
cc-switch
cc-switch 6 1
cc
```

Provider setup examples:

```powershell
cc-manage add  # select Mistral Vibe for https://api.mistral.ai/v1 through the local proxy
cc-manage add  # select Codestral for https://codestral.mistral.ai/v1/chat/completions through the local proxy
cc-manage add  # select OpenCode Zen for https://opencode.ai/zen/v1/chat/completions through the local proxy
```

## Local State And Secrets

Installed runtime files live in:

```text
~/.claude-profiles
```

Local V2 profile files store generated key IDs such as:

```text
CCKEY_<PROVIDER>_<PROFILE>_<RANDOM_ID>
```

Actual API key values stay in `~/.claude-profiles/.env`. Do not commit `.env`, API keys, key maps, debug logs, active-profile files, or generated runtime profile files.

## Project Layout

```text
.
|-- docs/                           # Plans, backlog, and long-form project notes
|-- governance/                     # Changelog, contribution guide, and security policy
|-- scripts/                        # One-off provider and model utilities
|-- src/cc-manage/                  # Installed profile manager, launchers, and proxies
|-- tests/                          # Local proxy contracts and provider smoke checks
|-- .env.example                    # Expected local key-name conventions
`-- README.md                       # Install, usage, architecture, and project overview
```

## Development Checks

Run focused checks before changing proxy or provider behavior:

```powershell
[scriptblock]::Create((Get-Content "src\cc-manage\claude-switch.ps1" -Raw)) | Out-Null
node --check "src\cc-manage\proxy\openai-chat-proxy.js"
node --check "src\cc-manage\proxy\anthropic-gemini-proxy.js"
node --check "src\cc-manage\proxy\opencode-zen-proxy.js"
$env:CLAUDE_PROFILES_ROOT="$PWD\src\cc-manage"; python tests\test_proxy_conversions.py
```

## Cross Platform

Windows uses the `.bat` launchers. macOS/Linux can use the extensionless shell launchers in `~/.claude-profiles` after installing PowerShell Core (`pwsh`).

```sh
chmod +x ~/.claude-profiles/cc ~/.claude-profiles/cc-switch ~/.claude-profiles/cc-status ~/.claude-profiles/cc-manage ~/.claude-profiles/claude
export PATH="$HOME/.claude-profiles:$PATH"
```

Set `CLAUDE_CODE_BIN` if the `claude` executable is not discoverable from PATH or `~/.local/bin/claude`.

## Uninstall

Back up local profiles and keys before removing the install:

```powershell
Rename-Item "$HOME\.claude-profiles" ".claude-profiles.backup"
```

Remove cc-manage on Windows PowerShell:

```powershell
$installDir = Join-Path $HOME ".claude-profiles"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$newUserPath = (($userPath -split ";") | Where-Object { $_ -and $_ -ne $installDir }) -join ";"
[Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
}
```

Remove cc-manage on macOS/Linux:

```sh
rm -rf "$HOME/.claude-profiles"
```

Then remove this block from `~/.zshrc`, `~/.bashrc`, or `~/.profile` if the installer added it:

```sh
# cc-manage PATH
export PATH="$HOME/.claude-profiles:$PATH"
```

## Help

```powershell
cc-manage -help
cc-manage -help commands
cc-manage -help uninstall
```

The default help view has three pages: General, Commands, and Uninstall. Use Left/Right arrows to move between pages. Menu selectors such as `cc-switch` and interactive `cc-manage` use Up/Down arrows and Enter.

## Governance

- [Changelog](./governance/CHANGELOG.md)
- [Contributing](./governance/CONTRIBUTING.md)
- [Security](./governance/SECURITY.md)

## Production Backlog

See [PRODUCTION_GRADE_BACKLOG.md](./docs/PRODUCTION_GRADE_BACKLOG.md).
