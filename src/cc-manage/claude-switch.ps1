$script:PROFILES_DIR = Join-Path $PSScriptRoot "profiles"
. "$PSScriptRoot\v2-core.ps1"
. "$PSScriptRoot\providers.ps1"

function Test-ClaudeWindows {
    try {
        return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    } catch {
        return ($env:OS -match "Windows")
    }
}

function Get-ClaudeHomeDir {
    $homeDir = [Environment]::GetFolderPath("UserProfile")
    if (![string]::IsNullOrWhiteSpace($homeDir)) { return $homeDir }
    if (![string]::IsNullOrWhiteSpace($env:HOME)) { return $env:HOME }
    if (![string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $env:USERPROFILE }
    return (Get-Location).Path
}

function Get-ClaudeExecutablePath {
    if (![string]::IsNullOrWhiteSpace($env:CLAUDE_CODE_BIN) -and (Test-Path -LiteralPath $env:CLAUDE_CODE_BIN)) {
        return $env:CLAUDE_CODE_BIN
    }

    $homeDir = Get-ClaudeHomeDir
    $candidates = @(
        (Join-Path $homeDir ".local/bin/claude.exe"),
        (Join-Path $homeDir ".local/bin/claude")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $command = Get-Command claude -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-NodeExecutablePath {
    if (![string]::IsNullOrWhiteSpace($env:NODE_EXE) -and (Test-Path -LiteralPath $env:NODE_EXE)) {
        return $env:NODE_EXE
    }
    $command = Get-Command node -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return "node"
}

function Test-LocalPortListening {
    param([int]$Port)
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (!$async.AsyncWaitHandle.WaitOne(300)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Get-LocalPortOwnerBestEffort {
    param([int]$Port)
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener) { return $listener.OwningProcess }
    }
    return $null
}

function Start-ClaudeProxyProcess {
    param([string]$ProxyScript, [int]$ProxyPort)
    $params = @{
        FilePath = Get-NodeExecutablePath
        ArgumentList = @("`"$ProxyScript`"", "$ProxyPort")
        PassThru = $true
    }
    if (Test-ClaudeWindows) { $params.WindowStyle = "Hidden" }
    return Start-Process @params
}

function Get-ActiveProfile {
    $file = Join-Path $PSScriptRoot ".claude_active_profile"
    if (!(Test-Path $file)) { return $null }
    $lines = Get-Content $file
    $result = @{}
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ($line -match "^(PROFILE|MODEL)=(.*)") {
            $result[$matches[1]] = $matches[2]
        }
    }
    return $result
}

function Set-ActiveProfile {
    param([string]$ProfileName, [string]$Model)
    $file = Join-Path $PSScriptRoot ".claude_active_profile"
    Set-Content -Path $file -Value "PROFILE=$ProfileName`nMODEL=$Model" -NoNewline
}

function Get-ProfileScript {
    param([string]$Name)
    $path = Join-Path $PROFILES_DIR "$Name.ps1"
    if (Test-Path $path) { return $path }
    return $null
}

function Test-Number {
    param([string]$Value)
    return $Value -match "^\d+$"
}

function Get-ProfileEntries {
    $index = 0
    Get-ChildItem $PROFILES_DIR -Filter "*.ps1" | Sort-Object BaseName | ForEach-Object {
        $index++
        . $_.FullName
        [pscustomobject]@{
            Index = $index
            Name = $_.BaseName
            DisplayName = if ($script:PROFILE_NAME) { $script:PROFILE_NAME } else { $_.BaseName }
            Path = $_.FullName
            BaseUrl = $script:BASE_URL
            DefaultModel = $script:DEFAULT_MODEL
            Models = @($script:MODELS)
        }
    }
}

function Show-ProfileMenu {
    param($Entries)
    Write-Host "Usage: cc-switch [profile-number|profile-name] [model-number|model-name]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Available profiles:" -ForegroundColor Yellow
    foreach ($entry in $Entries) {
        Write-Host ("  {0,2}. {1}" -f $entry.Index, $entry.Name) -ForegroundColor Green
        Write-Host "      Default: $($entry.DefaultModel)" -ForegroundColor DarkGray
        Write-Host "      Models:  $($entry.Models -join ', ')" -ForegroundColor DarkGray
    }
}

function Resolve-ProfileEntry {
    param(
        [string]$Selection,
        [switch]$Prompt
    )

    $entries = @(Get-ProfileEntries)
    if ($Prompt -or [string]::IsNullOrWhiteSpace($Selection)) {
        Show-ProfileMenu $entries
        $Selection = Read-Host "Select profile number"
        if ([string]::IsNullOrWhiteSpace($Selection)) { return $null }
    }

    if (Test-Number $Selection) {
        $profileNumber = [int]$Selection
        $entry = $entries | Where-Object { $_.Index -eq $profileNumber } | Select-Object -First 1
        if ($entry) { return $entry }

        Write-Host "Error: Profile number '$Selection' not found" -ForegroundColor Red
        Show-ProfileMenu $entries
        return $null
    }

    $entry = $entries | Where-Object {
        $_.Name -eq $Selection -or $_.DisplayName -eq $Selection
    } | Select-Object -First 1

    if ($entry) { return $entry }

    Write-Host "Error: Profile '$Selection' not found" -ForegroundColor Red
    Show-ProfileMenu $entries
    return $null
}

function Show-ModelMenu {
    param($ProfileEntry)
    Write-Host "Available models for $($ProfileEntry.Name):" -ForegroundColor Yellow
    for ($i = 0; $i -lt $ProfileEntry.Models.Count; $i++) {
        $number = $i + 1
        $suffix = if ($ProfileEntry.Models[$i] -eq $ProfileEntry.DefaultModel) { " (default)" } else { "" }
        Write-Host ("  {0,2}. {1}{2}" -f $number, $ProfileEntry.Models[$i], $suffix) -ForegroundColor Green
    }
}

function Resolve-ModelName {
    param(
        $ProfileEntry,
        [string]$Selection,
        [switch]$Prompt
    )

    if ($Prompt -and $ProfileEntry.Models.Count -gt 1 -and [string]::IsNullOrWhiteSpace($Selection)) {
        Show-ModelMenu $ProfileEntry
        $Selection = Read-Host "Select model number or press Enter for default [$($ProfileEntry.DefaultModel)]"
    }

    if ([string]::IsNullOrWhiteSpace($Selection)) {
        return $ProfileEntry.DefaultModel
    }

    if (Test-Number $Selection) {
        $modelNumber = [int]$Selection
        if ($modelNumber -ge 1 -and $modelNumber -le $ProfileEntry.Models.Count) {
            return $ProfileEntry.Models[$modelNumber - 1]
        }

        Write-Host "Error: Model number '$Selection' not found in profile '$($ProfileEntry.Name)'" -ForegroundColor Red
        Show-ModelMenu $ProfileEntry
        return $null
    }

    if ($ProfileEntry.Models -contains $Selection) {
        return $Selection
    }

    Write-Host "Error: Model '$Selection' not found in profile '$($ProfileEntry.Name)'" -ForegroundColor Red
    Show-ModelMenu $ProfileEntry
    return $null
}

function Get-ClaudeModelAliases {
    param([string]$SelectedModel)
    $models = @($script:MODELS)
    $fallbacks = @($models | Where-Object { $_ -ne $SelectedModel })

    return [pscustomobject]@{
        Sonnet = $SelectedModel
        Opus = if ($fallbacks.Count -ge 1) { $fallbacks[0] } else { $SelectedModel }
        Haiku = if ($fallbacks.Count -ge 2) { $fallbacks[1] } else { $SelectedModel }
    }
}

function cc-switch {
    param(
        [string]$ProfileName,
        [string]$Model = ""
    )

    $promptForProfile = [string]::IsNullOrWhiteSpace($ProfileName)
    $entry = Resolve-ProfileEntry $ProfileName -Prompt:$promptForProfile
    if (!$entry) { return }

    $modelName = Resolve-ModelName $entry $Model -Prompt:$promptForProfile
    if (!$modelName) { return }

    Set-ActiveProfile $entry.Name $modelName
    Write-Host "Switched to profile: $($entry.DisplayName) -> $modelName" -ForegroundColor Green
}

function cc {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$CcArgs
    )

    $active = Get-ActiveProfile
    if (!$active) {
        Write-Host "No active profile found. Use 'cc-switch <profile>' first." -ForegroundColor Red
        return
    }

    $profilePath = Get-ProfileScript $active["PROFILE"]
    if (!$profilePath) {
        Write-Host "Error: Profile script not found for '$($active['PROFILE'])'" -ForegroundColor Red
        return
    }

    . $profilePath

    $profileEntry = [pscustomobject]@{
        Name = $active["PROFILE"]
        DisplayName = if ($script:PROFILE_NAME) { $script:PROFILE_NAME } else { $active["PROFILE"] }
        Path = $profilePath
        BaseUrl = $script:BASE_URL
        DefaultModel = $script:DEFAULT_MODEL
        Models = @($script:MODELS)
    }

    $model = $active["MODEL"]
    $claudeArgs = @()
    if ($CcArgs -and $CcArgs.Count -gt 0) {
        $firstArg = $CcArgs[0]

        $modelOverride = $null
        if (Test-Number $firstArg) {
            $modelOverride = Resolve-ModelName $profileEntry $firstArg
        } elseif ($script:MODELS -contains $firstArg) {
            $modelOverride = $firstArg
        }

        if ($modelOverride) {
            $model = $modelOverride
            if ($CcArgs.Count -gt 1) {
                $claudeArgs = $CcArgs[1..($CcArgs.Count - 1)]
            }
        } elseif (Test-Number $firstArg) {
            return
        } else {
            $claudeArgs = $CcArgs
        }
    }

    if ($script:MODELS -contains $model) {
        try {
            $resolvedApiKey = Get-ProfileApiKey
        } catch {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
        }

        $env:CC_PROVIDER = $script:PROVIDER
        $env:CC_PROVIDER_MODE = $script:MODE
        $env:CC_PROFILE_BASE_URL = $script:BASE_URL
        $env:CC_UPSTREAM_BASE_URL = if ($script:UPSTREAM_BASE_URL) { $script:UPSTREAM_BASE_URL } else { $script:BASE_URL }
        $env:CC_DEFAULT_MODEL = $script:DEFAULT_MODEL
        $env:CC_MODELS = (@($script:MODELS) -join ",")

        $proxyProcess = $null
        $proxyScript = $null
        if ($script:PROXY_SCRIPT) {
            $resolvedProxyScript = Resolve-Path -LiteralPath $script:PROXY_SCRIPT -ErrorAction SilentlyContinue
            if ($resolvedProxyScript) {
                $proxyScript = $resolvedProxyScript.Path
            }
        }
        if ($proxyScript) {
            $proxyPort = if ($script:PROXY_PORT) { $script:PROXY_PORT } else { 18000 }
            $portInUse = Test-LocalPortListening -Port $proxyPort
            if (-not $portInUse) {
                Write-Host "  Starting proxy: $(Split-Path $proxyScript -Leaf) on :$proxyPort" -ForegroundColor DarkGray
                $proxyProcess = Start-ClaudeProxyProcess -ProxyScript $proxyScript -ProxyPort $proxyPort
                Start-Sleep -Milliseconds 1500
            } else {
                Write-Host "  Using existing proxy on :$proxyPort" -ForegroundColor DarkGray
                $ownerPid = Get-LocalPortOwnerBestEffort -Port $proxyPort
                if ($ownerPid) { Write-Host "  Proxy PID: $ownerPid" -ForegroundColor DarkGray }
            }
        } elseif ($script:PROXY_SCRIPT) {
            Write-Host "  Proxy script not found: $($script:PROXY_SCRIPT)" -ForegroundColor Yellow
        }

        $env:ANTHROPIC_BASE_URL = $script:BASE_URL
        $env:ANTHROPIC_MODEL = $model
        $modelAliases = Get-ClaudeModelAliases $model
        $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $modelAliases.Sonnet
        $env:ANTHROPIC_DEFAULT_OPUS_MODEL = $modelAliases.Opus
        $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $modelAliases.Haiku

        if ($script:AUTH_MODE -eq "auth_token") {
            $env:ANTHROPIC_AUTH_TOKEN = $resolvedApiKey
            Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
        } else {
            $env:ANTHROPIC_API_KEY = $resolvedApiKey
            Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
        }

        Write-Host "Launching Claude with profile: $($script:PROFILE_NAME) -> $model" -ForegroundColor Cyan
        Write-Host "  Base URL: $($script:BASE_URL)" -ForegroundColor DarkGray
        Write-Host "  /model aliases: sonnet=$($modelAliases.Sonnet), opus=$($modelAliases.Opus), haiku=$($modelAliases.Haiku)" -ForegroundColor DarkGray

        $claudeExe = Get-ClaudeExecutablePath
        if (!$claudeExe) {
            Write-Host "Error: Claude Code executable not found. Set CLAUDE_CODE_BIN or install the 'claude' command." -ForegroundColor Red
            $global:LASTEXITCODE = 1
        } else {
            & $claudeExe @claudeArgs
        }

        if ($proxyProcess -and !$proxyProcess.HasExited) {
            $proxyProcess.Kill()
            Write-Host "  Proxy stopped" -ForegroundColor DarkGray
        }

        Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\ANTHROPIC_MODEL -ErrorAction SilentlyContinue
        Remove-Item Env:\ANTHROPIC_DEFAULT_SONNET_MODEL -ErrorAction SilentlyContinue
        Remove-Item Env:\ANTHROPIC_DEFAULT_OPUS_MODEL -ErrorAction SilentlyContinue
        Remove-Item Env:\ANTHROPIC_DEFAULT_HAIKU_MODEL -ErrorAction SilentlyContinue
        Remove-Item Env:\CC_PROVIDER -ErrorAction SilentlyContinue
        Remove-Item Env:\CC_PROVIDER_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:\CC_PROFILE_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:\CC_UPSTREAM_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:\CC_DEFAULT_MODEL -ErrorAction SilentlyContinue
        Remove-Item Env:\CC_MODELS -ErrorAction SilentlyContinue
    } else {
        Write-Host "Error: Model '$model' not found in profile '$($active['PROFILE'])'" -ForegroundColor Red
        Write-Host "Available models:" -ForegroundColor Yellow
        $script:MODELS | ForEach-Object { Write-Host "  - $_" }
    }
}

function cc-status {
    $active = Get-ActiveProfile
    if (!$active) {
        Write-Host "No active profile set." -ForegroundColor Yellow
        Write-Host "Use 'cc-switch <profile>' to set one." -ForegroundColor Yellow
        return
    }

    $profilePath = Get-ProfileScript $active["PROFILE"]
    $profileName = $active["PROFILE"]
    $model = $active["MODEL"]

    if ($profilePath) {
        . $profilePath
        $displayName = $script:PROFILE_NAME
        $baseUrl = $script:BASE_URL
        $provider = $script:PROVIDER
        $mode = $script:MODE
        $keyId = $script:API_KEY_ID
        $keyName = if ($script:API_KEY_ID) { $script:API_KEY_ID } else { $script:API_KEY_NAME }
    } else {
        $displayName = $profileName
        $baseUrl = "?"
        $provider = "?"
        $mode = "?"
        $keyId = "?"
        $keyName = "?"
    }

    Write-Host "Active profile: $displayName -> $model" -ForegroundColor Green
    Write-Host "  Base URL: $baseUrl" -ForegroundColor DarkGray
    if ($provider) { Write-Host "  Provider: $provider ($mode)" -ForegroundColor DarkGray }
    if ($keyName) { Write-Host "  API Key ID: $keyName" -ForegroundColor DarkGray }
}

function Start-ProfileManager {
    while ($true) {
        Clear-Host
        Write-Host "--- Profile Management ($PROFILES_DIR) ---" -ForegroundColor Cyan
        Write-Host "1. List Profiles"
        Write-Host "2. Add New Profile"
        Write-Host "3. Edit Existing Profile"
        Write-Host "4. Delete Profile"
        Write-Host "5. Exit Management"
        $choice = Read-Host "`nSelect an option"
        
        switch ($choice) {
            "1" { 
                Show-ProfileMenu (Get-ProfileEntries)
                Read-Host "Press Enter to continue" 
            }
            "2" { Add-ProfileInteractive }
            "3" { Edit-ProfileInteractive }
            "4" { Delete-ProfileInteractive }
            "5" { return }
        }
    }
}

function Load-ProfileTemplate {
    param($Path)
    $content = Get-Content $Path -Raw
    $profile = @{
        Name = ""; BaseUrl = ""; AuthMode = "api_key"; ApiKey = "";
        ApiKeyId = ""; ApiKeyName = ""; Provider = ""; Mode = ""; UpstreamBaseUrl = "";
        ProxyScript = ""; ProxyPort = ""; DefaultModel = ""; Models = @()
    }
    
    if ($content -match '(?mi)^\$script:PROFILE_VERSION\s*=\s*(\d+)') { $profile.ProfileVersion = $matches[1] }
    if ($content -match '(?mi)^\$script:PROFILE_NAME\s*=\s*"(.*?)"') { $profile.Name = $matches[1] }
    if ($content -match '(?mi)^\$script:PROVIDER\s*=\s*"(.*?)"') { $profile.Provider = $matches[1] }
    if ($content -match '(?mi)^\$script:MODE\s*=\s*"(.*?)"') { $profile.Mode = $matches[1] }
    if ($content -match '(?mi)^\$script:BASE_URL\s*=\s*"(.*?)"') { $profile.BaseUrl = $matches[1] }
    if ($content -match '(?mi)^\$script:UPSTREAM_BASE_URL\s*=\s*"(.*?)"') { $profile.UpstreamBaseUrl = $matches[1] }
    if ($content -match '(?mi)^\$script:AUTH_MODE\s*=\s*"(.*?)"') { $profile.AuthMode = $matches[1] }
    if ($content -match '(?mi)^\$script:API_KEY\s*=\s*"(.*?)"') { $profile.ApiKey = $matches[1] }
    if ($content -match '(?mi)^\$script:API_KEY_ID\s*=\s*"(.*?)"') { $profile.ApiKeyId = $matches[1] }
    if ($content -match '(?mi)^\$script:API_KEY_NAME\s*=\s*"(.*?)"') { $profile.ApiKeyName = $matches[1] }
    if ($content -match '(?mi)^\$script:PROXY_SCRIPT\s*=\s*(.*?)\r?$') { $profile.ProxyScript = $matches[1] }
    if ($content -match '(?mi)^\$script:PROXY_PORT\s*=\s*(\d+)') { $profile.ProxyPort = $matches[1] }
    if ($content -match '(?mi)^\$script:DEFAULT_MODEL\s*=\s*"(.*?)"') { $profile.DefaultModel = $matches[1] }
    
    if ($content -match '(?si)\$script:MODELS\s*=\s*@\((.*?)\)') {
        $modelsBlock = $matches[1]
        $models = @()
        $modelsBlock -split "`n" | ForEach-Object {
            if ($_ -match '"(.*?)"') { $models += $matches[1] }
        }
        $profile.Models = $models
    }

    if ([string]::IsNullOrWhiteSpace($profile.Provider)) {
        $profile.Provider = Get-ProfileProviderGuess -ProfileName $profile.Name -BaseUrl $profile.BaseUrl -ProxyScript $profile.ProxyScript
    }
    if ([string]::IsNullOrWhiteSpace($profile.Mode)) {
        $profile.Mode = Get-ProfileModeGuess -Provider $profile.Provider -ProxyScript $profile.ProxyScript
    }
    if ([string]::IsNullOrWhiteSpace($profile.ApiKeyId) -and ![string]::IsNullOrWhiteSpace($profile.ApiKeyName) -and $profile.ApiKeyName -match '^CCKEY_') {
        $profile.ApiKeyId = $profile.ApiKeyName
    }
    if (![string]::IsNullOrWhiteSpace($profile.ApiKeyId) -and [string]::IsNullOrWhiteSpace($profile.ApiKeyName)) {
        $profile.ApiKeyName = $profile.ApiKeyId
    } elseif ([string]::IsNullOrWhiteSpace($profile.ApiKeyName)) {
        $profile.ApiKeyName = Get-DefaultKeyNameForProvider $profile.Provider
    }

    return $profile
}

function Save-ProfileTemplate {
    param($Path, $profile)
    $proxyScriptStr = if ($profile.ProxyScript) { "`n`$script:PROXY_SCRIPT = $($profile.ProxyScript)" } else { "" }
    $proxyPortStr = if ($profile.ProxyPort) { "`n`$script:PROXY_PORT = $($profile.ProxyPort)" } else { "" }
    $upstreamStr = if ($profile.UpstreamBaseUrl) { "`n`$script:UPSTREAM_BASE_URL = `"$($profile.UpstreamBaseUrl)`"" } else { "" }
    $modelsStr = ""
    if ($profile.Models.Count -gt 0) {
        $quotedModels = $profile.Models | ForEach-Object { "`"$_`"" }
        $modelsStr = "`n    " + ($quotedModels -join ",`n    ")
    }
    
    $newContent = @"
`$script:PROFILE_VERSION = 2
`$script:PROFILE_NAME = "$($profile.Name)"
`$script:PROVIDER = "$($profile.Provider)"
`$script:MODE = "$($profile.Mode)"
`$script:BASE_URL = "$($profile.BaseUrl)"
`$script:AUTH_MODE = "$($profile.AuthMode)"
`$script:API_KEY_ID = "$($profile.ApiKeyId)"
`$script:API_KEY_NAME = "$($profile.ApiKeyName)"$upstreamStr$proxyScriptStr$proxyPortStr
`$script:DEFAULT_MODEL = "$($profile.DefaultModel)"
`$script:MODELS = @($modelsStr
)
"@
    Set-Content -Path $Path -Value $newContent -Encoding UTF8
    Write-Host "Profile saved to $(Split-Path $Path -Leaf)" -ForegroundColor Green
}

function Get-ExistingProxyEntries {
    $proxyDir = Join-Path $PSScriptRoot "proxy"
    if (!(Test-Path $proxyDir)) { return @() }

    $proxyFiles = @(Get-ChildItem -Path $proxyDir -Filter "*.js" -File | Sort-Object Name)
    $entries = @()
    $index = 1

    foreach ($proxyFile in $proxyFiles) {
        $knownPorts = @()
        if (Test-Path $PROFILES_DIR) {
            Get-ChildItem -Path $PROFILES_DIR -Filter "*.ps1" -File | ForEach-Object {
                $content = Get-Content $_.FullName -Raw
                if ($content -match [regex]::Escape($proxyFile.Name) -and $content -match '(?mi)^\$script:PROXY_PORT\s*=\s*(\d+)') {
                    $knownPorts += $matches[1]
                }
            }
        }

        $suggestedPort = @($knownPorts | Select-Object -Unique | Sort-Object)[0]
        $entries += [pscustomobject]@{
            Index = $index
            Name = $proxyFile.Name
            Path = $proxyFile.FullName
            Expression = "Join-Path `$PSScriptRoot ""..\proxy\$($proxyFile.Name)"""
            SuggestedPort = $suggestedPort
        }
        $index++
    }

    return $entries
}

function Select-ExistingProxyInteractive {
    $proxyEntries = @(Get-ExistingProxyEntries)
    if ($proxyEntries.Count -eq 0) {
        Write-Host "No existing proxies found in $(Join-Path $PSScriptRoot "proxy")." -ForegroundColor Yellow
        return $null
    }

    Write-Host "`nExisting proxies:" -ForegroundColor Yellow
    foreach ($proxy in $proxyEntries) {
        $portText = if ($proxy.SuggestedPort) { " [port $($proxy.SuggestedPort)]" } else { "" }
        Write-Host ("  {0}. {1}{2}" -f $proxy.Index, $proxy.Name, $portText) -ForegroundColor Cyan
    }

    $selection = Read-Host "Select proxy number"
    if (!($selection -match '^\d+$')) {
        Write-Host "Invalid proxy selection." -ForegroundColor Red
        return $null
    }

    $selected = $proxyEntries | Where-Object { $_.Index -eq [int]$selection } | Select-Object -First 1
    if (!$selected) {
        Write-Host "Proxy number '$selection' not found." -ForegroundColor Red
        return $null
    }

    return $selected
}

function Set-ProfileProxyInteractive {
    param($profile)

    Write-Host "`nProxy options:" -ForegroundColor Yellow
    Write-Host "1. Pick existing proxy"
    Write-Host "2. Enter custom proxy path"
    $proxyMode = Read-Host "Select proxy option [1]"
    if ([string]::IsNullOrWhiteSpace($proxyMode)) { $proxyMode = "1" }

    if ($proxyMode -eq "1") {
        $selectedProxy = Select-ExistingProxyInteractive
        if (!$selectedProxy) { return }
        $profile.ProxyScript = $selectedProxy.Expression
        $defaultPort = if ($selectedProxy.SuggestedPort) { $selectedProxy.SuggestedPort } else { "18000" }
        $proxyPort = Read-Host "Proxy Port [$defaultPort]"
        $profile.ProxyPort = if ([string]::IsNullOrWhiteSpace($proxyPort)) { $defaultPort } else { $proxyPort }
        return
    }

    if ($proxyMode -eq "2") {
        $profile.ProxyScript = Read-Host "Proxy script path (e.g. Join-Path `$PSScriptRoot ""..\proxy\..."")"
        $proxyPort = Read-Host "Proxy Port [18000]"
        $profile.ProxyPort = if ([string]::IsNullOrWhiteSpace($proxyPort)) { "18000" } else { $proxyPort }
        return
    }

    Write-Host "Invalid proxy option. Skipping proxy setup." -ForegroundColor Yellow
}

function Add-ProfileInteractive {
    Write-Host "`n--- Add New Profile ---" -ForegroundColor Cyan
    Show-ProviderMenu
    $providerSelection = Read-Host "Provider number or name"
    $provider = Resolve-ProviderSelection $providerSelection
    if (!$provider) {
        Write-Host "Invalid provider selection." -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    $fileName = Read-Host "Filename (without .ps1, e.g. openrouter-new)"
    if ([string]::IsNullOrWhiteSpace($fileName)) { return }
    $Path = Join-Path $PROFILES_DIR "$fileName.ps1"
    if (Test-Path $Path) {
        Write-Host "Profile $fileName already exists!" -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    $profile = @{
        Name = ""; BaseUrl = ""; AuthMode = "api_key"; ApiKey = "";
        ApiKeyId = ""; ApiKeyName = ""; Provider = ""; Mode = ""; UpstreamBaseUrl = "";
        ProxyScript = ""; ProxyPort = ""; DefaultModel = ""; Models = @()
    }
    
    $profile.Name = Read-Host "Profile Display Name [$fileName]"
    if ([string]::IsNullOrWhiteSpace($profile.Name)) { $profile.Name = $fileName }

    $profile.Provider = $provider.Id
    $profile.Mode = $provider.Mode
    $profile.AuthMode = $provider.AuthMode

    $profile.ApiKeyId = New-ClaudeProfileKeyId -ProfileName $fileName -Provider $provider.Id
    $profile.ApiKeyName = $profile.ApiKeyId
    Set-ClaudeKeyMapping -Profile $fileName -Provider $provider.Id -KeyId $profile.ApiKeyId -SourceKeyName $provider.KeyName -Label $profile.Name
    Write-Host "Generated profile API key id: $($profile.ApiKeyId)" -ForegroundColor DarkGray
    $saveKey = Read-Host "Add/update value for $($profile.ApiKeyId) in .env now? (y/N)"
    if ($saveKey -match "^y") {
        $secure = Read-Host "API key value for $($profile.ApiKeyId)" -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        if (![string]::IsNullOrWhiteSpace($plain)) {
            Set-ClaudeEnvValue -Name $profile.ApiKeyId -Value $plain
            Write-Host "Saved $($profile.ApiKeyId) to .env as $(Protect-ClaudeSecret $plain)" -ForegroundColor Green
        }
    }

    if ($provider.Mode -eq "anthropic-direct") {
        $baseUrl = Read-Host "Base URL [$($provider.BaseUrl)]"
        $profile.BaseUrl = if ([string]::IsNullOrWhiteSpace($baseUrl)) { $provider.BaseUrl } else { $baseUrl }
    } elseif ($provider.Mode -eq "gemini-proxy" -or $provider.Mode -eq "huggingface-proxy" -or $provider.Mode -eq "nvidia-proxy" -or $provider.Mode -eq "mistral-proxy") {
        $profile.BaseUrl = $provider.BaseUrl
        $profile.ProxyScript = $provider.ProxyScript
        $profile.ProxyPort = "$($provider.ProxyPort)"
    } elseif ($provider.Mode -eq "openai-chat-proxy") {
        Write-Host "`nClaude Code uses Anthropic Messages, but this provider uses OpenAI-style Chat Completions." -ForegroundColor Yellow
        Write-Host "The shared OpenAI proxy will translate messages, tools, streaming, stop reasons, usage, and errors." -ForegroundColor Yellow
        $defaultPort = "18100"
        $proxyPort = Read-Host "Local proxy port [$defaultPort]"
        $profile.ProxyPort = if ([string]::IsNullOrWhiteSpace($proxyPort)) { $defaultPort } else { $proxyPort }
        $profile.BaseUrl = "http://127.0.0.1:$($profile.ProxyPort)"
        $upstreamBase = Read-Host "Upstream Base URL [$($provider.BaseUrl)]"
        $profile.UpstreamBaseUrl = if ([string]::IsNullOrWhiteSpace($upstreamBase)) { $provider.BaseUrl } else { $upstreamBase }
        $profile.ProxyScript = 'Join-Path $PSScriptRoot "..\proxy\openai-chat-proxy.js"'
    }

    $customProxy = Read-Host "Advanced: override with existing/custom proxy? (y/N)"
    if ($customProxy -match "^y") { Set-ProfileProxyInteractive $profile }
    
    $defaultModels = @($provider.DefaultModels)
    if ($provider.ModelSource -eq "dynamic") {
        $fetchModels = Read-Host "Fetch live models for $($provider.Name)? (y/N)"
        if ($fetchModels -match "^y") {
            $liveModels = @(Get-ProviderModels -ProviderId $provider.Id -KeyName $profile.ApiKeyId -Quiet)
            if ($liveModels.Count -gt 0) { $defaultModels = $liveModels }
        }
    }

    if ($defaultModels.Count -gt 0) {
        Write-Host "Suggested models: $($defaultModels -join ', ')" -ForegroundColor DarkGray
    }
    $modelsInput = Read-Host "Models (comma separated, blank for suggested)"
    if (![string]::IsNullOrWhiteSpace($modelsInput)) {
        $profile.Models = @($modelsInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    } elseif ($defaultModels.Count -gt 0) {
        $profile.Models = @($defaultModels)
    }
    
    if ($profile.Models.Count -gt 0) {
        Write-Host "Available Models: $($profile.Models -join ', ')" -ForegroundColor DarkGray
        $profile.DefaultModel = Read-Host "Default Model [$($profile.Models[0])]"
        if ([string]::IsNullOrWhiteSpace($profile.DefaultModel)) { $profile.DefaultModel = $profile.Models[0] }
    } else {
        $profile.DefaultModel = Read-Host "Default Model"
        if (![string]::IsNullOrWhiteSpace($profile.DefaultModel)) {
            $profile.Models += $profile.DefaultModel
        }
    }
    
    Save-ProfileTemplate -Path $Path -profile $profile
    Read-Host "Press Enter to continue"
}

function Edit-ProfileInteractive {
    $entries = @(Get-ProfileEntries)
    if ($entries.Count -eq 0) {
        Write-Host "No profiles available to edit." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }
    
    Show-ProfileMenu $entries
    if ($script:__EditProfileSelection) {
        $sel = "$script:__EditProfileSelection"
        Remove-Variable -Name __EditProfileSelection -Scope Script -ErrorAction SilentlyContinue
    } else {
        $sel = Read-Host "`nEnter profile number to edit"
    }
    if (!($sel -match '^\d+$')) { return }
    $entry = $entries | Where-Object { $_.Index -eq [int]$sel } | Select-Object -First 1
    if (!$entry) { return }
    
    $Path = $entry.Path
    $profile = Load-ProfileTemplate $Path
    
    Write-Host "`nEditing Profile: $($entry.Name)" -ForegroundColor Cyan
    Write-Host "Leave blank to keep current value.`n"
    
    $val = Read-Host "Profile Display Name [$($profile.Name)]"
    if (![string]::IsNullOrWhiteSpace($val)) { $profile.Name = $val }

    $val = Read-Host "Provider [$($profile.Provider)]"
    if (![string]::IsNullOrWhiteSpace($val)) { $profile.Provider = $val }

    $val = Read-Host "Mode [$($profile.Mode)]"
    if (![string]::IsNullOrWhiteSpace($val)) { $profile.Mode = $val }
    
    $val = Read-Host "Base URL [$($profile.BaseUrl)]"
    if (![string]::IsNullOrWhiteSpace($val)) { $profile.BaseUrl = $val }

    $val = Read-Host "Upstream Base URL [$($profile.UpstreamBaseUrl)]"
    if (![string]::IsNullOrWhiteSpace($val)) { $profile.UpstreamBaseUrl = $val }
    
    $val = Read-Host "Auth Mode [$($profile.AuthMode)]"
    if (![string]::IsNullOrWhiteSpace($val)) { $profile.AuthMode = $val }
    
    if ([string]::IsNullOrWhiteSpace($profile.ApiKeyId)) {
        $profile.ApiKeyId = New-ClaudeProfileKeyId -ProfileName $entry.Name -Provider $profile.Provider
        $profile.ApiKeyName = $profile.ApiKeyId
        Set-ClaudeKeyMapping -Profile $entry.Name -Provider $profile.Provider -KeyId $profile.ApiKeyId -SourceKeyName (Get-DefaultKeyNameForProvider $profile.Provider) -Label $profile.Name
    }
    Write-Host "API Key ID: $($profile.ApiKeyId)" -ForegroundColor DarkGray
    $regenKey = Read-Host "Generate a new unique API key id for this profile? (y/N)"
    if ($regenKey -match "^y") {
        $oldKeyId = $profile.ApiKeyId
        $profile.ApiKeyId = New-ClaudeProfileKeyId -ProfileName $entry.Name -Provider $profile.Provider
        $profile.ApiKeyName = $profile.ApiKeyId
        $oldValue = Get-ClaudeEnvValue $oldKeyId
        if (![string]::IsNullOrWhiteSpace($oldValue)) {
            Set-ClaudeEnvValue -Name $profile.ApiKeyId -Value $oldValue
        }
        Set-ClaudeKeyMapping -Profile $entry.Name -Provider $profile.Provider -KeyId $profile.ApiKeyId -SourceKeyName $oldKeyId -Label $profile.Name
        Write-Host "Generated new key id: $($profile.ApiKeyId)" -ForegroundColor Green
    }

    $changeKey = Read-Host "Add/update value for $($profile.ApiKeyId) in .env? (y/N)"
    if ($changeKey -match "^y") {
        $secure = Read-Host "API key value for $($profile.ApiKeyId)" -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        if (![string]::IsNullOrWhiteSpace($plain)) {
            Set-ClaudeEnvValue -Name $profile.ApiKeyId -Value $plain
            Write-Host "Saved $($profile.ApiKeyId) to .env as $(Protect-ClaudeSecret $plain)" -ForegroundColor Green
        }
    }
    
    while ($true) {
        Write-Host "`nCurrent Models: $($profile.Models -join ', ')" -ForegroundColor Yellow
        Write-Host "Default Model: $($profile.DefaultModel)" -ForegroundColor Green
        Write-Host "1. Add Model"
        Write-Host "2. Remove Model"
        Write-Host "3. Set Default Model"
        Write-Host "4. Done with Models"
        $mSel = Read-Host "Select option"
        
        switch ($mSel) {
            "1" {
                $nM = Read-Host "New Model Name"
                if (![string]::IsNullOrWhiteSpace($nM) -and $profile.Models -notcontains $nM) {
                    $profile.Models += $nM
                }
            }
            "2" {
                $nM = Read-Host "Model Name to Remove"
                $profile.Models = @($profile.Models | Where-Object { $_ -ne $nM })
            }
            "3" {
                $nM = Read-Host "Set Default To"
                if ($profile.Models -contains $nM) {
                    $profile.DefaultModel = $nM
                } else {
                    Write-Host "Model not in list!" -ForegroundColor Red
                }
            }
            "4" { break }
        }
        if ($mSel -eq "4") { break }
    }
    
    Save-ProfileTemplate -Path $Path -profile $profile
    Read-Host "Press Enter to continue"
}

function Delete-ProfileInteractive {
    $entries = @(Get-ProfileEntries)
    if ($entries.Count -eq 0) {
        Write-Host "No profiles available to delete." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }
    
    Show-ProfileMenu $entries
    $sel = Read-Host "`nEnter profile number to delete"
    if (!($sel -match '^\d+$')) { return }
    $entry = $entries | Where-Object { $_.Index -eq [int]$sel } | Select-Object -First 1
    if (!$entry) { return }
    
    $confirm = Read-Host "Are you sure you want to delete profile '$($entry.Name)'? (y/N)"
    if ($confirm -match "^y") {
        Remove-Item $entry.Path -Force
        Write-Host "Deleted $($entry.Name)" -ForegroundColor Red
    }
    Read-Host "Press Enter to continue"
}

function Get-ProviderModels {
    param(
        [string]$ProviderId,
        [string]$KeyName,
        [switch]$Refresh,
        [switch]$Quiet
    )

    $provider = Get-ProviderDefinition $ProviderId
    if (!$provider) {
        if (!$Quiet) { Write-Host "Provider '$ProviderId' not found." -ForegroundColor Red }
        return @()
    }

    if ($provider.ModelSource -ne "dynamic" -or [string]::IsNullOrWhiteSpace($provider.ModelsEndpoint)) {
        if (!$Quiet) { $provider.DefaultModels | ForEach-Object { Write-Host $_ } }
        return @($provider.DefaultModels)
    }

    $resolvedKeyName = if ($KeyName) { $KeyName } else { $provider.KeyName }
    try {
        $apiKey = Get-ClaudeEnvValue $resolvedKeyName
        if ([string]::IsNullOrWhiteSpace($apiKey) -and !$KeyName) {
            $providerAliases = @($ProviderId)
            if ($ProviderId -eq "nvidia-nim") { $providerAliases += "nvidia" }
            if ($ProviderId -eq "nvidia") { $providerAliases += "nvidia-nim" }

            foreach ($mapped in @(Get-ClaudeKeyMap | Where-Object { $providerAliases -contains $_.Provider })) {
                $candidateValue = Get-ClaudeEnvValue $mapped.KeyId
                if (![string]::IsNullOrWhiteSpace($candidateValue)) {
                    $resolvedKeyName = $mapped.KeyId
                    $apiKey = $candidateValue
                    break
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            throw "Missing API key '$resolvedKeyName'."
        }

        $headers = @{ Authorization = "Bearer $apiKey"; "Content-Type" = "application/json" }
        $response = Invoke-RestMethod -Method Get -Uri $provider.ModelsEndpoint -Headers $headers -TimeoutSec 30
        $models = @()
        if ($response.data) {
            $models = @($response.data | ForEach-Object { $_.id } | Where-Object { $_ })
        } elseif ($response.models) {
            $models = @($response.models | ForEach-Object { $_.id } | Where-Object { $_ })
        }

        if (!$Quiet) {
            Write-Host "$($provider.Name) models:" -ForegroundColor Green
            $models | ForEach-Object { Write-Host "  $_" }
        }
        return $models
    } catch {
        if (!$Quiet) {
            Write-Host "Unable to fetch models for $($provider.Name): $($_.Exception.Message)" -ForegroundColor Red
            if ($provider.DefaultModels.Count -gt 0) {
                Write-Host "Fallback models:" -ForegroundColor Yellow
                $provider.DefaultModels | ForEach-Object { Write-Host "  $_" }
            }
        }
        return @($provider.DefaultModels)
    }
}

function Show-ClaudeKeys {
    $values = Import-ClaudeDotEnv
    if ($values.Count -eq 0) {
        Write-Host "No keys found in $script:CLAUDE_ENV_PATH" -ForegroundColor Yellow
        return
    }
    $map = @(Get-ClaudeKeyMap)
    $values.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $envEntry = $_
        $owner = $map | Where-Object { $_.KeyId -eq $envEntry.Name } | Select-Object -First 1
        $ownerText = ""
        if ($owner) { $ownerText = " [$($owner.Profile) / $($owner.Provider)]" }
        Write-Host ("{0}={1}{2}" -f $envEntry.Name, (Protect-ClaudeSecret $envEntry.Value), $ownerText) -ForegroundColor Green
    }
}

function Invoke-ClaudeDoctor {
    Write-Host "Claude Profiles Doctor" -ForegroundColor Cyan
    $node = Get-Command node -ErrorAction SilentlyContinue
    $claude = Get-ClaudeExecutablePath
    Write-Host ("Node: {0}" -f $(if ($node) { $node.Source } else { "missing" }))
    Write-Host ("Claude Code: {0}" -f $(if ($claude -and (Test-Path -LiteralPath $claude)) { $claude } else { "missing" }))
    Write-Host ("Env file: {0}" -f $(if (Test-Path $script:CLAUDE_ENV_PATH) { $script:CLAUDE_ENV_PATH } else { "missing" }))

    $issues = 0
    foreach ($entry in Get-ProfileEntries) {
        . $entry.Path
        $keyName = if ($script:API_KEY_ID) { $script:API_KEY_ID } else { $script:API_KEY_NAME }
        if ([string]::IsNullOrWhiteSpace($keyName)) {
            Write-Host "Profile $($entry.Name): missing API_KEY_ID" -ForegroundColor Red
            $issues++
        } elseif ([string]::IsNullOrWhiteSpace((Get-ClaudeEnvValue $keyName))) {
            Write-Host "Profile $($entry.Name): .env missing $keyName" -ForegroundColor Yellow
            $issues++
        }

        if ($script:PROXY_SCRIPT) {
            $resolvedProxy = Resolve-Path -LiteralPath $script:PROXY_SCRIPT -ErrorAction SilentlyContinue
            if (!$resolvedProxy) {
                Write-Host "Profile $($entry.Name): proxy script not found: $script:PROXY_SCRIPT" -ForegroundColor Red
                $issues++
            }
        }
    }

    if ($issues -eq 0) { Write-Host "Doctor passed." -ForegroundColor Green }
    else { Write-Host "Doctor found $issues issue(s)." -ForegroundColor Yellow }
}

function Test-ClaudeProfile {
    param(
        [string]$ProfileName,
        [string]$Model,
        [string]$Level = "basic"
    )

    $entry = Resolve-ProfileEntry $ProfileName
    if (!$entry) { return }
    $selectedModel = Resolve-ModelName $entry $Model
    if (!$selectedModel) { return }

    $previous = Get-ActiveProfile
    try {
        Set-ActiveProfile $entry.Name $selectedModel
        $prompt = if ($Level -eq "tools" -or $Level -eq "tool-loop") {
            if (Test-ClaudeWindows) {
                "Use the shell tool. Run exactly: (Get-ChildItem -Directory | Measure-Object).Count . Return only the number, no words."
            } else {
                "Use the shell tool. Run exactly: find . -mindepth 1 -maxdepth 1 -type d | wc -l . Return only the number, no words."
            }
        } else {
            "Reply OK only."
        }
        cc --bare --print $prompt
    } finally {
        if ($previous) { Set-ActiveProfile $previous["PROFILE"] $previous["MODEL"] }
    }
}

function Migrate-ClaudeProfilesToV2 {
    $migrated = 0
    Get-ChildItem -LiteralPath $PROFILES_DIR -Filter "*.ps1" | Sort-Object Name | ForEach-Object {
        $path = $_.FullName
        $content = Get-Content -LiteralPath $path -Raw
        $rawKey = if ($content -match '(?mi)^\$script:API_KEY\s*=\s*"(.*?)"') { $matches[1] } else { "" }
        $profile = Load-ProfileTemplate $path
        $provider = if ($profile.Provider) { $profile.Provider } else { Get-ProfileProviderGuess -ProfileName $profile.Name -BaseUrl $profile.BaseUrl -ProxyScript $profile.ProxyScript }
        $isPlaceholder = [string]::IsNullOrWhiteSpace($rawKey) -or $rawKey -match '(?i)PASTE|YOUR|KEY_HERE|HERE$'

        $profile.Provider = $provider
        $profile.Mode = if ($profile.Mode) { $profile.Mode } else { Get-ProfileModeGuess -Provider $provider -ProxyScript $profile.ProxyScript }
        $oldPointer = if ($profile.ApiKeyId) { $profile.ApiKeyId } elseif ($profile.ApiKeyName) { $profile.ApiKeyName } else { Get-DefaultKeyNameForProvider $provider }
        $sourceValue = if (!$isPlaceholder) { $rawKey } else { Get-ClaudeEnvValue $oldPointer }

        if ([string]::IsNullOrWhiteSpace($profile.ApiKeyId) -or $profile.ApiKeyId -notmatch '^CCKEY_') {
            $profile.ApiKeyId = New-ClaudeProfileKeyId -ProfileName $_.BaseName -Provider $provider
        }
        $profile.ApiKeyName = $profile.ApiKeyId

        if (![string]::IsNullOrWhiteSpace($sourceValue)) {
            Set-ClaudeEnvValue -Name $profile.ApiKeyId -Value $sourceValue
        }

        $profile.ApiKey = ""
        Set-ClaudeKeyMapping -Profile $_.BaseName -Provider $provider -KeyId $profile.ApiKeyId -SourceKeyName $oldPointer -Label $profile.Name
        Save-ProfileTemplate -Path $path -profile $profile
        $migrated++
    }

    Write-Host "Migrated $migrated profile(s) to profile-wise V2 key ids." -ForegroundColor Green
    Write-Host "Secrets are stored in $script:CLAUDE_ENV_PATH and assignments are tracked in $script:CLAUDE_KEY_MAP_PATH." -ForegroundColor Green
}

function Write-ManageHelpTab {
    param([string]$Text, [string]$Page, [string]$Target)
    if ($Page -eq $Target) {
        Write-Host " $Text " -ForegroundColor Black -BackgroundColor Blue -NoNewline
    } else {
        Write-Host " $Text " -ForegroundColor Gray -NoNewline
    }
}

function Show-ManageHelp {
    param([string]$Page = "general")
    $normalized = $Page.ToLowerInvariant()
    if ($normalized -notin @("general", "commands")) { $normalized = "general" }

    Write-Host ""
    Write-Host " Help " -ForegroundColor Cyan -NoNewline
    Write-ManageHelpTab -Text "General" -Page $normalized -Target "general"
    Write-Host " " -NoNewline
    Write-ManageHelpTab -Text "Commands" -Page $normalized -Target "commands"
    Write-Host "`n"

    if ($normalized -eq "commands") {
        Write-Host "Commands" -ForegroundColor Yellow
        Write-Host "  cc-switch                         Show numbered profiles and select interactively"
        Write-Host "  cc-switch <profile#|name> [model#|name]"
        Write-Host "  cc [model#|name] [claude args...] Launch Claude Code with the active profile"
        Write-Host "  cc-status                         Show active profile and model"
        Write-Host "  cc-manage add                     Add a provider/profile"
        Write-Host "  cc-manage edit [profile#|name]    Edit provider, keys, proxy, and models"
        Write-Host "  cc-manage key list                Show generated profile key ids with redacted values"
        Write-Host "  cc-manage key set <KEY_ID>        Add/update a key value in .env"
        Write-Host "  cc-manage models <provider>       Fetch dynamic provider models when supported"
        Write-Host "  cc-manage doctor                  Check keys, proxies, Node, and Claude Code"
        Write-Host "  cc-manage test <profile> [model] --level basic|tools"
        Write-Host ""
        Write-Host "Examples" -ForegroundColor Yellow
        Write-Host "  cc-switch 9 1"
        Write-Host "  cc 3 --print `"Reply OK only.`""
        Write-Host "  cc-manage models groq --refresh"
        Write-Host "  cc-manage test api-test-gemini-working gemini-2.5-flash --level tools"
        Write-Host "  cc-manage -help general"
        return
    }

    Write-Host "General" -ForegroundColor Yellow
    Write-Host "  Profiles are stored in: $PROFILES_DIR"
    Write-Host "  Keys are stored in:     $script:CLAUDE_ENV_PATH"
    Write-Host "  Key assignments use generated CCKEY_* ids per profile."
    Write-Host ""
    Write-Host "Provider modes" -ForegroundColor Yellow
    Write-Host "  anthropic-direct     Sends Anthropic Messages directly to compatible providers."
    Write-Host "  gemini-proxy         Converts Anthropic Messages to Gemini generateContent."
    Write-Host "  openai-chat-proxy    Converts Anthropic Messages to OpenAI Chat Completions."
    Write-Host "  nvidia-proxy         NVIDIA NIM wrapper over the shared OpenAI-compatible proxy."
    Write-Host "  mistral-proxy        Mistral wrapper over the shared OpenAI-compatible proxy."
    Write-Host ""
    Write-Host "Notes" -ForegroundColor Yellow
    Write-Host "  Groq output tokens are clamped to 4096 by default and oversized requests are rejected locally."
    Write-Host "  NVIDIA NIM uses https://integrate.api.nvidia.com/v1 through the local proxy."
    Write-Host "  Mistral uses https://api.mistral.ai/v1 through the local proxy."
    Write-Host "  On macOS/Linux, run these scripts with PowerShell Core (pwsh) and set CLAUDE_CODE_BIN if needed."
    Write-Host ""
    Write-Host "Open another page with: cc-manage -help commands"
}

function cc-manage {
    param(
        [switch]$Help,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$ManageArgs
    )

    if ($Help) {
        $page = if ($ManageArgs -and $ManageArgs.Count -ge 1) { $ManageArgs[0] } else { "general" }
        Show-ManageHelp -Page $page
        return
    }

    if (!$ManageArgs -or $ManageArgs.Count -eq 0) {
        Start-ProfileManager
        return
    }

    $cmd = $ManageArgs[0]
    if ($cmd -in @("help", "--help", "-help", "/?")) {
        $page = if ($ManageArgs.Count -ge 2) { $ManageArgs[1] } else { "general" }
        Show-ManageHelp -Page $page
        return
    }

    switch ($cmd) {
        "add" { Add-ProfileInteractive }
        "edit" {
            if ($ManageArgs.Count -ge 2) {
                $entry = Resolve-ProfileEntry $ManageArgs[1]
                if ($entry) {
                    $script:__EditProfileSelection = $entry.Index
                    Edit-ProfileInteractive
                }
            } else { Edit-ProfileInteractive }
        }
        "key" {
            $sub = if ($ManageArgs.Count -ge 2) { $ManageArgs[1] } else { "list" }
            switch ($sub) {
                "list" { Show-ClaudeKeys }
                "set" {
                    if ($ManageArgs.Count -lt 3) { Write-Host "Usage: cc-manage key set <NAME>" -ForegroundColor Yellow; return }
                    $name = $ManageArgs[2]
                    $secure = Read-Host "Value for $name" -AsSecureString
                    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
                    Set-ClaudeEnvValue -Name $name -Value $plain
                    Write-Host "Saved $name as $(Protect-ClaudeSecret $plain)" -ForegroundColor Green
                }
                "rename" {
                    if ($ManageArgs.Count -lt 4) { Write-Host "Usage: cc-manage key rename <OLD> <NEW>" -ForegroundColor Yellow; return }
                    Rename-ClaudeEnvValue -OldName $ManageArgs[2] -NewName $ManageArgs[3]
                    Write-Host "Renamed key." -ForegroundColor Green
                }
                "remove" {
                    if ($ManageArgs.Count -lt 3) { Write-Host "Usage: cc-manage key remove <NAME>" -ForegroundColor Yellow; return }
                    Remove-ClaudeEnvValue -Name $ManageArgs[2]
                    Write-Host "Removed $($ManageArgs[2]) from .env." -ForegroundColor Green
                }
                default { Write-Host "Usage: cc-manage key list|set|rename|remove" -ForegroundColor Yellow }
            }
        }
        "models" {
            if ($ManageArgs.Count -lt 2) { Write-Host "Usage: cc-manage models <provider> [--refresh]" -ForegroundColor Yellow; return }
            Get-ProviderModels -ProviderId $ManageArgs[1] -Refresh:($ManageArgs -contains "--refresh") | Out-Null
        }
        "doctor" { Invoke-ClaudeDoctor }
        "migrate" { Migrate-ClaudeProfilesToV2 }
        "test" {
            if ($ManageArgs.Count -lt 2) { Write-Host "Usage: cc-manage test <profile> [model] [--level basic|tools]" -ForegroundColor Yellow; return }
            $model = if ($ManageArgs.Count -ge 3 -and $ManageArgs[2] -notmatch "^--") { $ManageArgs[2] } else { "" }
            $level = "basic"
            for ($i = 0; $i -lt $ManageArgs.Count; $i++) {
                if ($ManageArgs[$i] -eq "--level" -and $i + 1 -lt $ManageArgs.Count) { $level = $ManageArgs[$i + 1] }
            }
            Test-ClaudeProfile -ProfileName $ManageArgs[1] -Model $model -Level $level
        }
        default {
            Write-Host "Usage: cc-manage add|edit|key|models|migrate|doctor|test" -ForegroundColor Yellow
        }
    }
}
