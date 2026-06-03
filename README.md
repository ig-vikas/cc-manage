# cc-manage

Claude Code profile switching, provider setup, and local compatibility proxies for Gemini, Groq, Mistral, NVIDIA NIM, Hugging Face, OpenRouter, and OpenAI-compatible APIs.

Repository: [ig-vikas/cc-manage](https://github.com/ig-vikas/cc-manage)

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

## What This Project Does

- Switches Claude Code profiles and models by number or name.
- Stores profile-specific generated key IDs instead of hardcoding secrets.
- Validates local proxy behavior for non-Anthropic APIs.
- Converts Anthropic Messages to Gemini, OpenAI-compatible Chat Completions, and provider-specific proxy formats.
- Handles text, images, tool calls, tool results, streaming, token counting, and provider errors.
- Adds provider-aware guardrails for Groq and NVIDIA NIM.
- Provides dedicated wrappers for Gemini, Hugging Face, Mistral, NVIDIA NIM, OpenRouter normalization, and generic OpenAI-compatible chat APIs.

## Useful Commands

```powershell
cc-manage -help
cc-manage -help commands
cc-manage doctor
cc-manage key list
cc-manage models groq --refresh
cc-manage models mistral --refresh
cc-manage models nvidia-nim --refresh
cc-switch
cc-switch 6 1
cc
```

## Project Layout

```text
.
|-- api_test_common.py              # Shared Python helpers for provider tests
|-- find_working_model.py           # Model probing helper
|-- test_anthropic_requests.py      # Anthropic-compatible request checks
|-- test_gemini_models.py           # Gemini model checks
|-- test_gemini_proxy.py            # Gemini proxy checks
|-- test_openrouter_anthropic.py    # OpenRouter/Anthropic compatibility checks
|-- test_proxy_conversions.py       # Local proxy conversion contract checks
|-- test_requests.py                # Generic request checks
|-- .env.example                    # Expected local key names
|-- SECURITY.md                     # Secret-handling and reporting policy
|-- CONTRIBUTING.md                 # Development and test guidance
`-- IMPLEMENTATION_PLAN_V2.md       # Planned v2 profile/provider architecture
```

The installed Claude Code profile manager and proxy scripts are stored at:

```text
~/.claude-profiles
```

## Help

```powershell
cc-manage -help
cc-manage -help commands
```

The help view has two pages: General and Commands.

## Cross Platform

Windows uses the `.bat` launchers. macOS/Linux can use the extensionless shell launchers in `~/.claude-profiles` after installing PowerShell Core (`pwsh`).

```sh
chmod +x ~/.claude-profiles/cc ~/.claude-profiles/cc-switch ~/.claude-profiles/cc-status ~/.claude-profiles/cc-manage ~/.claude-profiles/claude
export PATH="$HOME/.claude-profiles:$PATH"
```

Set `CLAUDE_CODE_BIN` if the `claude` executable is not discoverable from PATH or `~/.local/bin/claude`.

## Safety

Do not commit `.env`, API keys, key maps, debug logs, active-profile files, or runtime profile files. Local V2 profile files store generated key ids such as `CCKEY_<PROVIDER>_<PROFILE>_<RANDOM_ID>`; actual API key values stay in `.env`.

## Production Backlog

See [PRODUCTION_GRADE_BACKLOG.md](./PRODUCTION_GRADE_BACKLOG.md).
