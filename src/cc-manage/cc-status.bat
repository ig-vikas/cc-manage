@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude-profiles\cc-status-entry.ps1" %*
