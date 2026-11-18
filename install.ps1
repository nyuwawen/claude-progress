# Claude Progress - installer. Run Install.cmd (double-click) rather than this file directly.
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'ClaudeProgress'

Write-Host 'Installing Claude Progress...' -ForegroundColor Cyan

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Host 'Node.js is required (https://nodejs.org). Install it, then run this again.' -ForegroundColor Red; exit 1 }

# 1. Close a running copy (when updating), then copy the app
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*ClaudeProgress.ps1*' -and $_.CommandLine -notlike '*-SelfTest*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($f in 'hook.js','demo.js','settings-hooks.js','ClaudeProgress.ps1','uninstall.ps1','Uninstall.cmd') {
  Copy-Item (Join-Path $src $f) (Join-Path $dest $f) -Force
}

# 2. Check the window can be built
$test = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $dest 'ClaudeProgress.ps1') -SelfTest
if ($test -notmatch 'Window built OK') { Write-Host "The window failed to start: $test" -ForegroundColor Red; exit 1 }

# 3. Add the hooks to Claude Code's settings (a backup is saved next to it)
& $node (Join-Path $dest 'settings-hooks.js') add $node (Join-Path $dest 'hook.js')
if ($LASTEXITCODE -ne 0) { exit 1 }

# 4. Shortcuts: Start menu, and start with Windows
$shell = New-Object -ComObject WScript.Shell
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Progress'
New-Item -ItemType Directory -Force -Path $menu | Out-Null
function New-Shortcut($path, $extra, $desc) {
  $s = $shell.CreateShortcut($path)
  $s.TargetPath = 'powershell.exe'
  $s.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest\ClaudeProgress.ps1`" $extra"
  $s.WorkingDirectory = $dest
  $s.Description = $desc
  $s.IconLocation = 'shell32.dll,265'
  $s.Save()
}
New-Shortcut (Join-Path $menu 'Claude Progress.lnk') '' 'Shows what Claude is doing and how long is left'
New-Shortcut (Join-Path $menu 'Claude Progress Demo.lnk') '-Demo' 'Plays a fake job to show how it looks'
$u = $shell.CreateShortcut((Join-Path $menu 'Uninstall Claude Progress.lnk'))
$u.TargetPath = Join-Path $dest 'Uninstall.cmd'; $u.WorkingDirectory = $dest; $u.Save()
New-Shortcut (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Progress.lnk') '' 'Claude Progress'

# 5. Start it
Start-Process powershell.exe -ArgumentList "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest\ClaudeProgress.ps1`"" -WindowStyle Hidden

Write-Host ''
Write-Host 'Done. The Claude Progress window is in the bottom-right corner.' -ForegroundColor Green
Write-Host 'Restart Claude (or start a new session) so it picks up the new hooks.'
Write-Host 'Start menu > Claude Progress has the app, a demo and an uninstaller.'
