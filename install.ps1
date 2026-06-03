$ErrorActionPreference = "Stop"

$Repo = if ($env:CC_MANAGE_REPO) { $env:CC_MANAGE_REPO } else { "ig-vikas/cc-manage" }
$Ref = if ($env:CC_MANAGE_REF) { $env:CC_MANAGE_REF } else { "main" }
$InstallDir = if ($env:CC_MANAGE_HOME) { $env:CC_MANAGE_HOME } else { Join-Path $HOME ".claude-profiles" }
$ArchiveUrl = "https://github.com/$Repo/archive/refs/heads/$Ref.zip"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cc-manage-install-" + [guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $TempRoot "source.zip"

function Add-UserPath {
    param([string]$PathToAdd)
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($current -split ";" | Where-Object { $_ })
    if ($parts -notcontains $PathToAdd) {
        $newPath = (@($parts) + $PathToAdd) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$env:Path;$PathToAdd"
        Write-Host "Added to user PATH: $PathToAdd" -ForegroundColor Green
    }
}

try {
    New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
    Write-Host "Downloading $ArchiveUrl" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $ArchiveUrl -OutFile $ZipPath
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $TempRoot -Force

    $sourceDir = Get-ChildItem -LiteralPath $TempRoot -Directory |
        Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName "src\cc-manage" }

    if (!(Test-Path -LiteralPath $sourceDir)) {
        throw "Installer payload not found: src/cc-manage"
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Get-ChildItem -LiteralPath $sourceDir -Force | Copy-Item -Destination $InstallDir -Recurse -Force
    Add-UserPath -PathToAdd $InstallDir

    Write-Host "Installed cc-manage to $InstallDir" -ForegroundColor Green

    $node = Get-Command node -ErrorAction SilentlyContinue
    if (!$node) { Write-Host "Warning: node was not found on PATH. Install Node.js before using proxy providers." -ForegroundColor Yellow }

    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (!$claude -and !(Test-Path (Join-Path $HOME ".local\bin\claude.exe"))) {
        Write-Host "Warning: Claude Code was not found. Install Claude Code before launching cc." -ForegroundColor Yellow
    }

    $manage = Join-Path $InstallDir "cc-manage-entry.ps1"
    if (Test-Path -LiteralPath $manage) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $manage doctor
    }

    Write-Host ""
    Write-Host "Next:" -ForegroundColor Cyan
    Write-Host "  cc-manage add"
    Write-Host "  cc-switch"
    Write-Host "  cc"
} finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
