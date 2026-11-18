# Claude Progress - uninstaller.
$ErrorActionPreference = 'Continue'
$dest = Join-Path $env:LOCALAPPDATA 'ClaudeProgress'
Write-Host 'Removing Claude Progress...' -ForegroundColor Cyan

# Close the window
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*ClaudeProgress.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Remove only our hooks from Claude Code's settings
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
$helper = Join-Path $dest 'settings-hooks.js'
if ($node -and (Test-Path $helper)) { & $node $helper remove }

# Shortcuts
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Progress') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Progress.lnk') -Force -ErrorAction SilentlyContinue

# App files (run from a copy outside the folder so it can delete itself)
Write-Host "Your timing history is kept in $env:USERPROFILE\.claude-progress (delete it if you like)."
Start-Process cmd.exe -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$dest`"" -WindowStyle Hidden
Write-Host 'Claude Progress is uninstalled.' -ForegroundColor Green
