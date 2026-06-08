$script:CLAUDE_PROFILES_HOME = $PSScriptRoot
$script:CLAUDE_ENV_PATH = Join-Path $script:CLAUDE_PROFILES_HOME ".env"
$script:CLAUDE_KEY_MAP_PATH = Join-Path $script:CLAUDE_PROFILES_HOME ".key-map.json"

function Import-ClaudeDotEnv {
    param([string]$Path = $script:CLAUDE_ENV_PATH)
    if (!(Test-Path -LiteralPath $Path)) { return @{} }

    $values = @{}
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { return }
        if ($line -notmatch "^([A-Za-z_][A-Za-z0-9_]*)=(.*)$") { return }

        $name = $matches[1]
        $value = $matches[2]
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $values[$name] = $value
        Set-Item -Path "Env:\$name" -Value $value
    }

    return $values
}

function Get-ClaudeEnvValue {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    Import-ClaudeDotEnv | Out-Null
    return [Environment]::GetEnvironmentVariable($Name, "Process")
}

function Protect-ClaudeSecret {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return "<empty>" }
    if ($Value.Length -le 8) { return "<redacted>" }
    return "$($Value.Substring(0, 4))...$($Value.Substring($Value.Length - 4))"
}

function Set-ClaudeEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$Path = $script:CLAUDE_ENV_PATH
    )

    if ($Name -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") {
        throw "Invalid environment variable name '$Name'."
    }

    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        $lines = @(Get-Content -LiteralPath $Path)
    }

    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    $newLine = "$Name=""$escaped"""
    $updated = $false
    $out = @(foreach ($line in $lines) {
        if ($line -match "^\s*$([regex]::Escape($Name))=") {
            $updated = $true
            $newLine
        } else {
            $line
        }
    })

    if (!$updated) { $out = @($out) + $newLine }
    Set-Content -LiteralPath $Path -Value $out -Encoding UTF8
    Set-Item -Path "Env:\$Name" -Value $Value
}

function Remove-ClaudeEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Path = $script:CLAUDE_ENV_PATH
    )

    if (!(Test-Path -LiteralPath $Path)) { return }
    $out = @(Get-Content -LiteralPath $Path | Where-Object { $_ -notmatch "^\s*$([regex]::Escape($Name))=" })
    Set-Content -LiteralPath $Path -Value $out -Encoding UTF8
    Remove-Item "Env:\$Name" -ErrorAction SilentlyContinue
}

function Rename-ClaudeEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$OldName,
        [Parameter(Mandatory = $true)][string]$NewName
    )

    $value = Get-ClaudeEnvValue $OldName
    if ([string]::IsNullOrEmpty($value)) { throw "No value found for '$OldName'." }
    Set-ClaudeEnvValue -Name $NewName -Value $value
    Remove-ClaudeEnvValue -Name $OldName
}

function Get-ClaudeKeyMap {
    param([string]$Path = $script:CLAUDE_KEY_MAP_PATH)
    if (!(Test-Path -LiteralPath $Path)) { return @() }
    try {
        $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $items = @($parsed | ForEach-Object { $_ })
        $flat = @(foreach ($item in $items) {
            if ($item -and $item.KeyId) {
                [pscustomobject]@{
                    Profile = [string]$item.Profile
                    Provider = [string]$item.Provider
                    KeyId = [string]$item.KeyId
                    SourceKeyName = [string]$item.SourceKeyName
                    Label = [string]$item.Label
                    UpdatedAt = [string]$item.UpdatedAt
                }
            }
        })
        return @($flat)
    } catch {
        return @()
    }
}

function Save-ClaudeKeyMap {
    param(
        [array]$Map,
        [string]$Path = $script:CLAUDE_KEY_MAP_PATH
    )

    $clean = @(foreach ($item in @($Map)) {
        if ($item -and $item.PSObject.Properties["KeyId"]) {
            [pscustomobject]@{
                Profile = [string]$item.Profile
                Provider = [string]$item.Provider
                KeyId = [string]$item.KeyId
                SourceKeyName = [string]$item.SourceKeyName
                Label = [string]$item.Label
                UpdatedAt = [string]$item.UpdatedAt
            }
        }
    })
    $json = @($clean | Sort-Object Profile) | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function New-ClaudeProfileKeyId {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [string]$Provider = "custom"
    )

    $providerPart = ConvertTo-ClaudeEnvName $Provider
    $profilePart = ConvertTo-ClaudeEnvName $ProfileName
    if ($profilePart.Length -gt 42) { $profilePart = $profilePart.Substring(0, 42).Trim("_") }
    $suffix = ([guid]::NewGuid().ToString("N").Substring(0, 8)).ToUpperInvariant()
    return "CCKEY_${providerPart}_${profilePart}_$suffix"
}

function Set-ClaudeKeyMapping {
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$KeyId,
        [string]$SourceKeyName = "",
        [string]$Label = ""
    )

    $map = @(Get-ClaudeKeyMap | Where-Object { $_.Profile -ne $Profile })
    $map += [pscustomobject]@{
        Profile = $Profile
        Provider = $Provider
        KeyId = $KeyId
        SourceKeyName = $SourceKeyName
        Label = if ($Label) { $Label } else { $Profile }
        UpdatedAt = (Get-Date).ToString("s")
    }
    Save-ClaudeKeyMap $map
}

function Get-ClaudeKeyMapping {
    param([string]$Profile)
    return Get-ClaudeKeyMap | Where-Object { $_.Profile -eq $Profile } | Select-Object -First 1
}

function Get-ProfileApiKey {
    $keyName = if (![string]::IsNullOrWhiteSpace($script:API_KEY_ID)) { $script:API_KEY_ID } else { $script:API_KEY_NAME }
    if (![string]::IsNullOrWhiteSpace($keyName)) {
        $value = Get-ClaudeEnvValue $keyName
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Missing API key id '$keyName'. Add it with: cc-manage key set $keyName"
        }
        return $value
    }

    if (![string]::IsNullOrWhiteSpace($script:API_KEY)) {
        return $script:API_KEY
    }

    throw "Profile has no API key id. Set API_KEY_ID in the profile and add the key to .env."
}

function Get-ProfileProviderGuess {
    param(
        [string]$ProfileName,
        [string]$BaseUrl,
        [string]$ProxyScript
    )

    $haystack = "$ProfileName $BaseUrl $ProxyScript".ToLowerInvariant()
    if ($haystack -match "gemini") { return "gemini" }
    if ($haystack -match "openrouter") { return "openrouter" }
    if ($haystack -match "deepseek") { return "deepseek" }
    if ($haystack -match "groq") { return "groq" }
    if ($haystack -match "opencode|nemotron") { return "opencode_nemotron" }
    if ($haystack -match "codestral") { return "codestral" }
    if ($haystack -match "vibe") { return "mistral-vibe" }
    if ($haystack -match "mistral") { return "mistral" }
    if ($haystack -match "together") { return "together" }
    if ($haystack -match "fireworks") { return "fireworks" }
    if ($haystack -match "xai|x\.ai") { return "xai" }
    if ($haystack -match "ollama") { return "ollama-cloud" }
    if ($haystack -match "hug|huggingface") { return "huggingface" }
    if ($haystack -match "nvidia|nim") { return "nvidia-nim" }
    return "anthropic"
}

function Get-DefaultKeyNameForProvider {
    param([string]$Provider)
    switch ($Provider) {
        "anthropic" { "ANTHROPIC_API_KEY" }
        "gemini" { "GEMINI_API_KEY" }
        "openrouter" { "OPENROUTER_API_KEY" }
        "ollama-cloud" { "OLLAMA_API_KEY" }
        "groq" { "GROQ_API_KEY" }
        "opencode_nemotron" { "OPENCODE_API_KEY" }
        "codestral" { "CODESTRAL_API_KEY" }
        "mistral-vibe" { "MISTRAL_VIBE_API_KEY" }
        "mistral" { "MISTRAL_API_KEY" }
        "deepseek" { "DEEPSEEK_API_KEY" }
        "together" { "TOGETHER_API_KEY" }
        "fireworks" { "FIREWORKS_API_KEY" }
        "xai" { "XAI_API_KEY" }
        "huggingface" { "HUGGINGFACE_API_KEY" }
        "nvidia-nim" { "NVIDIA_API_KEY" }
        "nvidia" { "NVIDIA_API_KEY" }
        default { "CUSTOM_API_KEY" }
    }
}

function ConvertTo-ClaudeEnvName {
    param([string]$Value)
    $name = ($Value -replace '[^A-Za-z0-9_]', '_').ToUpperInvariant()
    $name = $name -replace '_+', '_'
    $name = $name.Trim('_')
    if ($name -notmatch '^[A-Z_]') { $name = "KEY_$name" }
    return $name
}

function Get-ProfileModeGuess {
    param(
        [string]$Provider,
        [string]$ProxyScript
    )

    if ($ProxyScript -match "gemini") { return "gemini-proxy" }
    if ($ProxyScript -match "hug") { return "huggingface-proxy" }
    if ($ProxyScript -match "nvidia") { return "nvidia-proxy" }
    if ($ProxyScript -match "opencode|nemotron") { return "opencode-nemotron-proxy" }
    if ($ProxyScript -match "codestral") { return "codestral-proxy" }
    if ($ProxyScript -match "vibe") { return "mistral-vibe-proxy" }
    if ($ProxyScript -match "mistral") { return "mistral-proxy" }
    if ($ProxyScript -match "openrouter") { return "openai-chat-proxy" }
    if (![string]::IsNullOrWhiteSpace($ProxyScript)) { return "custom-proxy" }

    switch ($Provider) {
        "anthropic" { "anthropic-direct" }
        "deepseek" { "anthropic-direct" }
        "fireworks" { "anthropic-direct" }
        "openrouter" { "anthropic-direct" }
        "nvidia-nim" { "nvidia-proxy" }
        "nvidia" { "nvidia-proxy" }
        "opencode_nemotron" { "opencode-nemotron-proxy" }
        "codestral" { "codestral-proxy" }
        "mistral-vibe" { "mistral-vibe-proxy" }
        "mistral" { "mistral-proxy" }
        default { "openai-chat-proxy" }
    }
}
