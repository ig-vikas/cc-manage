param(
    [string]$ThemeName
)

$ValidThemes = @("light", "dark", "system", "default")
$ConfigFile = Join-Path $env:USERPROFILE ".claude.json"

if ([string]::IsNullOrWhiteSpace($ThemeName)) {
    Write-Host "--- Global Claude Theme Manager ---" -ForegroundColor Cyan
    Write-Host "Available themes:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $ValidThemes.Count; $i++) {
        Write-Host ("  {0,2}. {1}" -f ($i + 1), $ValidThemes[$i]) -ForegroundColor Green
    }
    
    $Selection = Read-Host "`nSelect a theme number or enter name"
    if ([string]::IsNullOrWhiteSpace($Selection)) { return }
    
    if ($Selection -match "^\d+$") {
        $idx = [int]$Selection - 1
        if ($idx -ge 0 -and $idx -lt $ValidThemes.Count) {
            $ThemeName = $ValidThemes[$idx]
        } else {
            Write-Host "Invalid selection." -ForegroundColor Red
            return
        }
    } else {
        $ThemeName = $Selection
    }
}

if ($ValidThemes -notcontains $ThemeName) {
    Write-Host "Invalid theme: $ThemeName" -ForegroundColor Red
    return
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Error: Claude config file not found at $ConfigFile" -ForegroundColor Red
    return
}

# Use regex to adjust theme to safely preserve any duplicate keys Claude creates
$content = Get-Content $ConfigFile -Raw

if ($ThemeName -eq "default") {
    # Remove theme line
    $content = $content -replace '(?mi)^\s*"theme":\s*".*?",?\r?\n?', ''
    Write-Host "Theme reset to default." -ForegroundColor Green
} else {
    if ($content -match '(?mi)^\s*"theme":\s*"(.*?)"') {
        # Update existing
        $content = $content -replace '(?mi)(^\s*"theme":\s*)".*?"', "`${1}`"$ThemeName`""
    } else {
        # Add after first brace
        $content = $content -replace '^\{', "{`n  `"theme`": `"$ThemeName`","
    }
    Write-Host "Theme set to: $ThemeName" -ForegroundColor Green
}

# Write without BOM for Node.js compatibility
$utf8NoBom = New-Object System.Text.UTF8Encoding $False
[System.IO.File]::WriteAllText($ConfigFile, $content, $utf8NoBom)

