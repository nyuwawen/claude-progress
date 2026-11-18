# Claude Progress - installer. Run Install.cmd (double-click) rather than this file directly.
param([switch]$Outside)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
# Lives next to the timing data. Not under AppData: when this runs from inside the Claude desktop
# app (a packaged app), Windows redirects AppData writes into a private copy only Claude can see.
$dest = Join-Path $env:USERPROFILE '.claude-progress\app'

# Run from inside a packaged app (e.g. Claude ran this)? Finish the install outside it, through
# Task Scheduler, so shortcuts and files land where Windows itself can see them.
Add-Type -Namespace CP -Name Pkg -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern int GetCurrentPackageFullName(ref int length, System.Text.StringBuilder name);'
$len = 0
if (-not $Outside -and [CP.Pkg]::GetCurrentPackageFullName([ref]$len, $null) -ne 15700) {
  $logFile = Join-Path $env:USERPROFILE '.claude-progress\install.log'
  New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null
  Remove-Item $logFile -ErrorAction SilentlyContinue
  $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"& '$PSCommandPath' -Outside *> '$logFile'`""
  Register-ScheduledTask -TaskName 'Claude Progress Setup' -Action $a -Force | Out-Null
  Start-ScheduledTask -TaskName 'Claude Progress Setup'
  Start-Sleep -Seconds 2
  while ((Get-ScheduledTask -TaskName 'Claude Progress Setup').State -eq 'Running') { Start-Sleep -Milliseconds 500 }
  Unregister-ScheduledTask -TaskName 'Claude Progress Setup' -Confirm:$false
  if (Test-Path $logFile) { Get-Content $logFile }
  exit 0
}

Write-Host 'Installing Claude Progress...' -ForegroundColor Cyan

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Host 'Node.js is required (https://nodejs.org). Install it, then run this again.' -ForegroundColor Red; exit 1 }

# 1. Close a running copy (when updating), then copy the app
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { ($_.CommandLine -like '*ClaudeProgress.ps1*' -or $_.CommandLine -like '*chat-watch.ps1*') -and $_.CommandLine -notlike '*-SelfTest*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
# Older versions installed to AppData\Local\ClaudeProgress
Remove-Item (Join-Path $env:LOCALAPPDATA 'ClaudeProgress') -Recurse -Force -ErrorAction SilentlyContinue
foreach ($f in 'hook.js','demo.js','settings-hooks.js','ClaudeProgress.ps1','chat-watch.ps1','uninstall.ps1','Uninstall.cmd') {
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

# 5. A Task Scheduler entry that opens the window. The hook runs it when a Claude session starts
#    and the window isn't open, so the window belongs to Windows (not to Claude) and survives
#    Claude closing or updating.
$launchArgs = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest\ClaudeProgress.ps1`""
$haveTask = $false
try {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $launchArgs -WorkingDirectory $dest
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  $who = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'Claude Progress' -Action $action -Settings $set -Principal $who -Description 'Opens the Claude Progress window' -Force | Out-Null
  $haveTask = $true
} catch { Write-Host "Couldn't add the Task Scheduler entry ($($_.Exception.Message)); the window still starts with Windows." -ForegroundColor Yellow }

# 6. Start it
if ($haveTask) { Start-ScheduledTask -TaskName 'Claude Progress' }
else { Start-Process powershell.exe -ArgumentList $launchArgs -WindowStyle Hidden }

Write-Host ''
Write-Host 'Done. The Claude Progress window is in the bottom-right corner.' -ForegroundColor Green
Write-Host 'Restart Claude (or start a new session) so it picks up the new hooks.'
Write-Host 'Start menu > Claude Progress has the app, a demo and an uninstaller.'
