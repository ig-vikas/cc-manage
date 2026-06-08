$script:PROVIDER_REGISTRY = @(
    @{
        Id = "anthropic"
        Name = "Anthropic"
        Mode = "anthropic-direct"
        BaseUrl = "https://api.anthropic.com"
        AuthMode = "api_key"
        KeyName = "ANTHROPIC_API_KEY"
        DefaultModels = @("claude-sonnet-4-20250514", "claude-opus-4-20250514")
    },
    @{
        Id = "gemini"
        Name = "Gemini"
        Mode = "gemini-proxy"
        BaseUrl = "http://127.0.0.1:18000"
        AuthMode = "api_key"
        KeyName = "GEMINI_API_KEY"
        ProxyScript = 'Join-Path $PSScriptRoot "..\proxy\anthropic-gemini-proxy.js"'
        ProxyPort = 18000
        DefaultModels = @("gemini-2.5-flash", "gemini-3.5-flash", "gemini-3-flash-preview")
    },
    @{
        Id = "openrouter"
        Name = "OpenRouter"
        Mode = "anthropic-direct"
        BaseUrl = "https://openrouter.ai/api"
        AuthMode = "api_key"
        KeyName = "OPENROUTER_API_KEY"
        DefaultModels = @("anthropic/claude-sonnet-4", "google/gemini-2.5-flash")
    },
    @{
        Id = "ollama-cloud"
        Name = "Ollama Cloud"
        Mode = "openai-chat-proxy"
        BaseUrl = "https://ollama.com/v1"
        AuthMode = "api_key"
        KeyName = "OLLAMA_API_KEY"
        DefaultModels = @("gpt-oss:120b", "llama3.3:70b")
    },
    @{
        Id = "groq"
        Name = "Groq"
        Mode = "openai-chat-proxy"
        BaseUrl = "https://api.groq.com/openai/v1"
        AuthMode = "api_key"
        KeyName = "GROQ_API_KEY"
        ModelSource = "dynamic"
        ModelsEndpoint = "https://api.groq.com/openai/v1/models"
        DefaultModels = @("openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3-32b")
    },
    @{
        Id = "mistral"
        Name = "Mistral"
        Mode = "mistral-proxy"
        BaseUrl = "http://127.0.0.1:18005"
        AuthMode = "api_key"
        KeyName = "MISTRAL_API_KEY"
        ModelSource = "dynamic"
        ModelsEndpoint = "https://api.mistral.ai/v1/models"
        ProxyScript = 'Join-Path $PSScriptRoot "..\proxy\mistral-anthropic-proxy.js"'
        ProxyPort = 18005
        DefaultModels = @("mistral-large-latest", "pixtral-large-latest", "ministral-8b-latest")
    },
    @{
        Id = "mistral-vibe"
        Name = "Mistral Vibe"
        Mode = "mistral-vibe-proxy"
        BaseUrl = "http://127.0.0.1:18007"
        AuthMode = "api_key"
        KeyName = "MISTRAL_VIBE_API_KEY"
        ModelSource = "dynamic"
        ModelsEndpoint = "https://api.mistral.ai/v1/models"
        ProxyScript = 'Join-Path $PSScriptRoot "..\proxy\mistral-vibe-anthropic-proxy.js"'
        ProxyPort = 18007
        DefaultModels = @("mistral-vibe-cli-latest", "mistral-medium-3.5", "devstral-small-latest")
    },
    @{
        Id = "codestral"
        Name = "Codestral"
        Mode = "codestral-proxy"
        BaseUrl = "http://127.0.0.1:18006"
        AuthMode = "api_key"
        KeyName = "CODESTRAL_API_KEY"
        ProxyScript = 'Join-Path $PSScriptRoot "..\proxy\codestral-anthropic-proxy.js"'
        ProxyPort = 18006
        DefaultModels = @("codestral-latest", "codestral-2508")
    },
    @{
        Id = "opencode_nemotron"
        Name = "OpenCode Nemotron"
        Mode = "opencode-nemotron-proxy"
        BaseUrl = "http://127.0.0.1:18100"
        AuthMode = "auth_token"
        KeyName = "OPENCODE_API_KEY"
        ProxyScript = 'Join-Path $PSScriptRoot "..\proxy\opencode-nemotron-proxy.js"'
        ProxyPort = 18100
        DefaultModels = @("nemotron-3-ultra-free")
    },
    @{
        Id = "deepseek"
        Name = "DeepSeek"
        Mode = "anthropic-direct"
        BaseUrl = "https://api.deepseek.com/anthropic"
        AuthMode = "api_key"
        KeyName = "DEEPSEEK_API_KEY"
        DefaultModels = @("deepseek-chat", "deepseek-reasoner")
    },
    @{
        Id = "together"
        Name = "Together"
        Mode = "openai-chat-proxy"
        BaseUrl = "https://api.together.xyz/v1"
        AuthMode = "api_key"
        KeyName = "TOGETHER_API_KEY"
        DefaultModels = @("meta-llama/Llama-3.3-70B-Instruct-Turbo")
    },
    @{
        Id = "fireworks"
        Name = "Fireworks"
        Mode = "anthropic-direct"
        BaseUrl = "https://api.fireworks.ai/inference/v1/anthropic"
        AuthMode = "api_key"
        KeyName = "FIREWORKS_API_KEY"
        DefaultModels = @("accounts/fireworks/models/llama-v3p3-70b-instruct")
    },
    @{
        Id = "xai"
        Name = "xAI"
        Mode = "openai-chat-proxy"
        BaseUrl = "https://api.x.ai/v1"
        AuthMode = "api_key"
        KeyName = "XAI_API_KEY"
        DefaultModels = @("grok-4", "grok-3")
    },
    @{
        Id = "nvidia-nim"
        Name = "NVIDIA NIM"
        Mode = "nvidia-proxy"
        BaseUrl = "http://127.0.0.1:18003"
        AuthMode = "api_key"
        KeyName = "NVIDIA_API_KEY"
        ModelSource = "dynamic"
        ModelsEndpoint = "https://integrate.api.nvidia.com/v1/models"
        ProxyScript = 'Join-Path $PSScriptRoot "..\proxy\nvidia-anthropic-proxy.js"'
        ProxyPort = 18003
        DefaultModels = @("nvidia/nemotron-3-super-120b-a12b", "qwen/qwen3.5-397b-a17b", "qwen/qwen3.5-122b-a10b")
    },
    @{
        Id = "openai-compatible"
        Name = "Any OpenAI-compatible cloud endpoint"
        Mode = "openai-chat-proxy"
        BaseUrl = ""
        AuthMode = "api_key"
        KeyName = "CUSTOM_API_KEY"
        DefaultModels = @()
    },
    @{
        Id = "huggingface"
        Name = "Hugging Face"
        Mode = "huggingface-proxy"
        BaseUrl = "http://127.0.0.1:18004"
        AuthMode = "api_key"
        KeyName = "HUGGINGFACE_API_KEY"
        ProxyScript = 'Join-Path $PSScriptRoot "..\proxy\hug-anthropic-proxy.js"'
        ProxyPort = 18004
        DefaultModels = @("moonshotai/Kimi-K2.6", "moonshotai/Kimi-K2.5")
    },
    @{
        Id = "nvidia"
        Name = "NVIDIA"
        Mode = "nvidia-proxy"
        BaseUrl = "http://127.0.0.1:18003"
        AuthMode = "api_key"
        KeyName = "NVIDIA_API_KEY"
        ProxyScript = 'Join-Path $PSScriptRoot "..\proxy\nvidia-anthropic-proxy.js"'
        ProxyPort = 18003
        DefaultModels = @("qwen/qwen3.5-397b-a17b", "nvidia/nemotron-3-super-120b-a12b")
    }
)

function Get-ProviderRegistry {
    return $script:PROVIDER_REGISTRY
}

function Get-ProviderDefinition {
    param([string]$IdOrName)
    return $script:PROVIDER_REGISTRY | Where-Object {
        $_.Id -eq $IdOrName -or $_.Name -eq $IdOrName
    } | Select-Object -First 1
}

function Show-ProviderMenu {
    $index = 1
    Write-Host "Select provider:" -ForegroundColor Yellow
    foreach ($provider in $script:PROVIDER_REGISTRY | Where-Object { $_.Id -ne "huggingface" -and $_.Id -ne "nvidia" }) {
        Write-Host ("  {0,2}. {1}" -f $index, $provider.Name) -ForegroundColor Green
        $provider.Index = $index
        $index++
    }
}

function Resolve-ProviderSelection {
    param([string]$Selection)
    $visible = @($script:PROVIDER_REGISTRY | Where-Object { $_.Id -ne "huggingface" -and $_.Id -ne "nvidia" })
    if ($Selection -match "^\d+$") {
        $idx = [int]$Selection
        if ($idx -ge 1 -and $idx -le $visible.Count) { return $visible[$idx - 1] }
        return $null
    }

    return $script:PROVIDER_REGISTRY | Where-Object {
        $_.Id -eq $Selection -or $_.Name -eq $Selection
    } | Select-Object -First 1
}
