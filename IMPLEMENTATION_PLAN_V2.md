# V2 Implementation Plan

## Goal

Make Claude Code profile setup provider-aware instead of asking users to manually know base URLs, auth modes, proxy scripts, ports, and request/response compatibility rules.

## Research Summary

Claude Code expects an Anthropic Messages-compatible surface: `/v1/messages`, `/v1/messages/count_tokens`, Anthropic-shaped streaming events, tool use blocks, tool results, model aliases, and Anthropic-style errors.

Some providers expose that natively. Others expose OpenAI Chat Completions, Gemini APIs, or Ollama APIs, which need a local compatibility proxy.

V2 must be production-safe: profile files must not contain raw API keys. Profiles should reference automatically generated profile-wise key ids stored in `.env`, and the CLI should be able to create, edit, rotate, validate, and redact those keys.

| Provider | Native Surface | Proxy Needed For Claude Code? | V2 Default |
|---|---:|---:|---|
| Anthropic | Anthropic Messages API | No | Direct |
| Gemini | Gemini `generateContent` / `streamGenerateContent` | Yes | `gemini` proxy |
| OpenRouter | Anthropic Agent SDK env support and OpenAI-style chat completions | Prefer direct; proxy fallback | Direct first |
| Ollama Cloud | Ollama API and partial OpenAI compatibility | Yes | OpenAI/Ollama proxy |
| Groq | OpenAI-compatible `/openai/v1/chat/completions` | Yes | Generic OpenAI proxy |
| Mistral | Chat completions API | Yes | Generic OpenAI-style proxy with Mistral preset |
| DeepSeek | OpenAI and Anthropic-compatible base URLs | No if using Anthropic URL | Direct Anthropic |
| Together | OpenAI-compatible `/v1/chat/completions`, tools supported | Yes | Generic OpenAI proxy |
| Fireworks | OpenAI-compatible and Anthropic-compatible Messages API | No if using Anthropic URL | Direct Anthropic |
| xAI | OpenAI-compatible chat/responses; Anthropic support should be probed | Probe; proxy fallback | Direct if `/v1/messages` passes |
| Any OpenAI-compatible cloud endpoint | OpenAI Chat Completions | Yes | Generic OpenAI proxy |

Groq requires dynamic model discovery. Its model catalog changes over time, so V2 should fetch models from `GET https://api.groq.com/openai/v1/models` with `Authorization: Bearer <GROQ_API_KEY>` instead of relying only on hard-coded defaults. The CLI should still keep safe fallback defaults for offline setup.

Sources:

- Anthropic Messages API: https://docs.anthropic.com/ja/api/messages
- Gemini thought signatures: https://ai.google.dev/gemini-api/docs/thought-signatures
- OpenRouter Anthropic Agent SDK integration: https://openrouter.ai/docs/guides/community/anthropic-agent-sdk
- OpenRouter Chat Completions: https://openrouter.ai/docs/api-reference/chat-completion
- Ollama Cloud and API access: https://docs.ollama.com/cloud
- Ollama OpenAI compatibility: https://docs.ollama.com/api/openai-compatibility
- Groq API/OpenAI compatibility: https://console.groq.com/docs/api-reference
- Mistral Chat Completions: https://docs.mistral.ai/studio-api/conversations/chat-completion
- DeepSeek first API call and Anthropic base URL: https://api-docs.deepseek.com/
- Together OpenAI compatibility: https://docs.together.ai/docs/inference/openai-compatibility
- Fireworks Anthropic compatibility: https://docs.fireworks.ai/tools-sdks/anthropic-compatibility
- xAI Chat Completions: https://docs.x.ai/docs/guides/chat-completions

## Provider Add Flow

When adding a profile, prompt like this:

```text
Select provider:
  1. Anthropic
  2. Gemini
  3. OpenRouter
  4. Ollama Cloud
  5. Groq
  6. Mistral
  7. DeepSeek
  8. Together
  9. Fireworks
 10. xAI
 11. Any OpenAI-compatible cloud endpoint
```

Then ask only the fields needed for that provider:

- Profile filename and display name.
- Automatically generated profile-wise API key id from `.env`, with an option to create or update the key value.
- Model list, with provider defaults offered first.
- Base URL only when it is custom or ambiguous.
- Proxy choice only when the provider needs translation.
- Health check choice: skip, plain only, or full tool-call test.

For `Any OpenAI-compatible cloud endpoint`, show a warning before saving:

```text
Claude Code speaks Anthropic Messages. OpenAI-compatible endpoints use Chat Completions.
This profile needs request/response translation for:
- system/messages format
- tools and tool_results
- streaming SSE events
- stop reasons and usage
- provider-specific errors
```

Provider-specific add flow:

- `Anthropic`: ask for key name, default `ANTHROPIC_API_KEY`, direct base URL, model list.
- `Gemini`: ask for key name, default `GEMINI_API_KEY`, use Gemini proxy, warn that tool loops require thought-signature preservation.
- `OpenRouter`: ask for key name, default `OPENROUTER_API_KEY`, offer direct Anthropic Agent SDK mode first, proxy fallback second.
- `Ollama Cloud`: ask for key name, default `OLLAMA_API_KEY`, offer Ollama API proxy or OpenAI-compatible proxy depending on selected endpoint.
- `Groq`: ask for key name, default `GROQ_API_KEY`, fetch live models, group models by capability when metadata is available, then use OpenAI proxy.
- `Mistral`: ask for key name, default `MISTRAL_API_KEY`, use OpenAI-style proxy with Mistral request/response normalization.
- `DeepSeek`: ask for key name, default `DEEPSEEK_API_KEY`, prefer direct Anthropic base URL.
- `Together`: ask for key name, default `TOGETHER_API_KEY`, fetch or enter model names, use OpenAI proxy.
- `Fireworks`: ask for key name, default `FIREWORKS_API_KEY`, prefer direct Anthropic-compatible endpoint.
- `xAI`: ask for key name, default `XAI_API_KEY`, probe Anthropic `/v1/messages`; if probe fails, use OpenAI proxy.
- `Any OpenAI-compatible cloud endpoint`: ask for key name, base URL, optional models URL, and provider-specific quirks.

## Proxy Strategy

Use three proxy classes instead of many one-off scripts:

1. `anthropic-direct`
   - No local proxy.
   - Sets `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN`.
   - Used by Anthropic, DeepSeek Anthropic, Fireworks Anthropic, OpenRouter direct, and xAI if `/v1/messages` passes.

2. `openai-chat-proxy`
   - Converts Anthropic Messages to OpenAI Chat Completions.
   - Supports streaming, `tools`, `tool_calls`, tool result messages, model listing, token estimates, and Anthropic-shaped errors.
   - Used by Groq, Together, Mistral, Ollama OpenAI compatibility, xAI fallback, and custom OpenAI-compatible endpoints.

3. `gemini-proxy`
   - Converts Anthropic Messages to Gemini `generateContent`.
   - Converts Gemini `functionCall` to Anthropic `tool_use`.
   - Preserves Gemini thought signatures for tool-result follow-up.
   - Emits Claude-facing SSE even when upstream uses non-streaming calls to keep signatures intact.

## Error Handling Requirements

All proxy classes and CLI commands must return clear, sanitized, Anthropic-shaped errors where Claude Code expects Anthropic responses.

Required cases:

- Missing API key or missing `.env` variable.
- Invalid API key or provider `401` / `403`.
- Provider quota/rate limit `429`, including retry-after text when present.
- Invalid model, deprecated model, or model not available to the account.
- Network, DNS, TLS, proxy-port, and timeout failures.
- Stale local proxy process already listening on the target port.
- Malformed upstream JSON or malformed streaming SSE.
- Provider returned raw text where a tool call was expected.
- Tool-call JSON parse failure.
- Tool result follow-up rejected by provider.
- Upstream `5xx` with provider name and request id when available.

Rules:

- Never print API keys, auth headers, `.env` values, or full profile secret lines.
- Include provider, profile name, model, endpoint family, HTTP status, and short remedy.
- Normalize proxy errors to `{ type: "error", error: { type, message } }`.
- Use nonzero process exit codes for CLI failures.
- Keep debug logs opt-in and redact secrets before writing.
- Add retry only for safe transient cases, never for invalid auth or invalid model.

## Provider Registry

Add a registry file, for example:

```powershell
$script:PROVIDER_REGISTRY = @(
  @{
    Id = "anthropic"
    Name = "Anthropic"
    Mode = "anthropic-direct"
    BaseUrl = ""
    AuthMode = "api_key"
    DefaultModels = @("claude-sonnet-4-20250514", "claude-opus-4-20250514")
  },
  @{
    Id = "groq"
    Name = "Groq"
    Mode = "openai-chat-proxy"
    BaseUrl = "https://api.groq.com/openai/v1"
    AuthMode = "api_key"
    DefaultModels = @("llama-3.3-70b-versatile")
    ModelSource = "dynamic"
    ModelsEndpoint = "https://api.groq.com/openai/v1/models"
  }
)
```

Keep provider data separate from `claude-switch.ps1` so adding providers does not make the main script messy.

## Dynamic Model Discovery

The CLI should support provider model discovery:

```text
cc-manage models <provider>
cc-manage models groq --refresh
cc-manage models groq --capability tool-use
```

Groq implementation:

```python
import os
import requests

api_key = os.environ.get("GROQ_API_KEY")
url = "https://api.groq.com/openai/v1/models"

headers = {
    "Authorization": f"Bearer {api_key}",
    "Content-Type": "application/json",
}

response = requests.get(url, headers=headers)
print(response.json())
```

Equivalent SDK path:

```javascript
import Groq from "groq-sdk";

const groq = new Groq({ apiKey: process.env.GROQ_API_KEY });

const getModels = async () => {
  return await groq.models.list();
};
```

Groq model UI should group available models by capability when possible:

- Reasoning.
- Function calling / tool use.
- Text to text.
- Vision.
- Multilingual.
- Speech to text.
- Text to speech.
- Safety / content moderation.

Cache dynamic model lists locally with a short TTL, for example 24 hours, and store only non-secret metadata. Provide `--refresh` to force a new fetch.

## Secret Management

V2 must move all raw keys into `.env` using profile-wise generated key ids.

Expected `.env` shape:

```text
CCKEY_<PROVIDER>_<PROFILE>_<RANDOM_ID>=
```

Rules:

- Profiles store generated key ids, not key values.
- Runtime loads `.env` before launching Claude Code or a proxy.
- CLI edit mode can regenerate the key id assigned to a profile.
- CLI key mode can create/update/delete/rename `.env` key ids.
- Display keys as redacted only, for example `sk-...abcd`.
- Migration must extract existing profile keys into `.env` and rewrite profiles to generated profile-wise key id references.
- `.env.example` should explain generated `CCKEY_...` ids rather than hard-code shared provider names.

## Profile Shape V2

Generated profiles should include structured metadata:

```powershell
$script:PROFILE_VERSION = 2
$script:PROFILE_NAME = "groq-main"
$script:PROVIDER = "groq"
$script:MODE = "openai-chat-proxy"
$script:BASE_URL = "https://api.groq.com/openai/v1"
$script:AUTH_MODE = "api_key"
$script:API_KEY_ID = "CCKEY_<PROVIDER>_<PROFILE>_<RANDOM_ID>"
$script:API_KEY_NAME = "CCKEY_<PROVIDER>_<PROFILE>_<RANDOM_ID>"
$script:PROXY_SCRIPT = Join-Path $PSScriptRoot "..\proxy\openai-chat-proxy.js"
$script:PROXY_PORT = 18105
$script:DEFAULT_MODEL = "llama-3.3-70b-versatile"
$script:MODELS = @(
    "llama-3.3-70b-versatile"
)
```

Existing profiles must be rewritten to this shape during migration. The old `$script:API_KEY = "..."` style should be removed after the key is safely copied into `.env` under the generated profile-wise key id.

## Health Checks

Every provider should support a standard test command:

```text
cc-manage test <profile> [model]
```

Test levels:

- `basic`: `/v1/models` or known model list, `/v1/messages/count_tokens`, plain text.
- `stream`: Claude-style streaming response.
- `tools`: one Bash/PowerShell tool call.
- `tool-loop`: tool call, local result, model final answer.

Add a fresh Claude Code install validation phase:

1. Back up `.claude-profiles`, `.env`, and existing wrapper scripts.
2. Uninstall/delete the current Claude Code binary or package.
3. Install Claude Code again from the official current source.
4. Verify `claude --version`, `claude`, `cc`, `cc-switch`, `cc-status`, and `cc-manage`.
5. Run `cc-manage test` across direct, OpenAI-proxy, and Gemini-proxy profiles.
6. Confirm profile switching still works after a clean install.

This phase must not delete user profiles or `.env` secrets. It only validates that V2 works on a fresh Claude Code installation.

## CLI Requirements

New commands:

```text
cc-manage add
cc-manage edit <profile>
cc-manage key list
cc-manage key set <NAME>
cc-manage key rename <OLD> <NEW>
cc-manage key remove <NAME>
cc-manage models <provider> [--refresh]
cc-manage migrate
cc-manage doctor
cc-manage test <profile> [model] [--level basic|stream|tools|tool-loop]
```

Edit mode requirements:

- Change provider.
- Change base URL.
- Change auth mode.
- Change key name.
- Update key value in `.env` without printing it.
- Change model list and default model.
- Re-run health checks after saving.
- Offer rollback if the new profile fails tests.

Doctor mode requirements:

- Check Node and PowerShell availability.
- Check Claude Code binary and wrapper paths.
- Check `.env` exists and has referenced keys.
- Check profile files are V2 shape.
- Check proxy ports are free or owned by expected proxy scripts.
- Check provider endpoints with safe lightweight requests.

## Implementation Steps

1. Add production repo files: `.env.example`, `SECURITY.md`, `CONTRIBUTING.md`, issue templates, and release notes.
2. Add `.env` loader and redaction helpers shared by CLI and proxies.
3. Add `providers.ps1` registry.
4. Add dynamic model discovery, starting with Groq `/openai/v1/models`.
5. Add `proxy/openai-chat-proxy.js` and migrate OpenRouter/Nvidia/Hug-style logic into it.
6. Keep `proxy/anthropic-gemini-proxy.js` as the Gemini-specific adapter.
7. Update `Add-ProfileInteractive` to ask provider first.
8. Generate proxy settings automatically from provider mode.
9. Keep the existing "pick existing proxy" option as an advanced/custom path.
10. Add CLI key management for `.env`.
11. Rewrite all existing profiles into V2 profile shape with generated `$script:API_KEY_ID`.
12. Add migration support for old profiles with no `$script:PROFILE_VERSION`.
13. Add complete error normalization and redacted debug logging.
14. Add `cc-manage test`, `cc-manage doctor`, and `cc-manage models`.
15. Add fresh Claude Code uninstall/reinstall validation.
16. Update README with provider setup examples.
17. Run full regression tests for direct, OpenAI-proxy, and Gemini-proxy profiles.
18. Tag a V2 release after all health checks pass.

## Production Repository Standard

To make this suitable as a polished public GitHub project:

- Keep secrets out of Git with `.env.example` and clear setup docs.
- Add CI for PowerShell parse checks, Node syntax checks, and proxy unit tests.
- Add integration tests that can run only when provider keys are present.
- Add docs for each provider with direct/proxy explanation.
- Add screenshots or terminal demos for `cc-switch`, `cc-manage add`, and `cc-manage test`.
- Add `SECURITY.md` for responsible disclosure and secret-handling policy.
- Add `CONTRIBUTING.md` with coding style and test instructions.
- Add changelog and semantic version tags.
- Keep provider adapters modular and documented.
- Keep all logs redacted by default.

## Acceptance Criteria

- Adding a provider no longer requires manually knowing proxy paths.
- Direct providers do not start local proxies.
- OpenAI-compatible providers use one shared proxy.
- Gemini tool loops work with thought signatures.
- Groq models are fetched dynamically and can be refreshed from CLI.
- Profiles reference generated `.env` key ids and contain no raw API keys.
- Existing profiles are migrated and rewritten to V2 safely.
- CLI edit mode can change provider, model, proxy mode, and key name/value.
- Error handling is normalized, redacted, and actionable across all providers.
- Fresh Claude Code uninstall/reinstall validation passes.
- `cc-switch` still supports numeric profile/model selection.
- `cc --bare --print` works for at least one verified model per provider type.
- API keys are never printed in tests or logs.
