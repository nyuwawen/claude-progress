# Claude Progress - installer. Run Install.cmd (double-click) rather than this file directly.
#   -Yes      skip the question (for scripted installs); the list of changes is still shown
#   -Outside  internal: the second half of an install started from inside the Claude app
param([switch]$Outside, [switch]$Yes)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$version = try { (Get-Content (Join-Path $src 'VERSION') -ErrorAction Stop | Select-Object -First 1).Trim() } catch { 'dev' }
# Lives next to the timing data. Not under AppData: when this runs from inside the Claude desktop
# app (a packaged app), Windows redirects AppData writes into a private copy only Claude can see.
$data = Join-Path $env:USERPROFILE '.claude-progress'
$dest = Join-Path $data 'app'
$startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# Before anything else: say exactly what will change, and wait for a Yes. Declining changes nothing.
if (-not $Outside) {
  $nodeFound = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $nodeFound) { Write-Host 'Node.js is required (https://nodejs.org). Install it, then run this again. Nothing was changed.' -ForegroundColor Red; exit 1 }
  $settingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'
  Write-Host ''
  Write-Host "Claude Progress $version - this install will:" -ForegroundColor Cyan
  Write-Host "  1. Copy the app to $dest"
  Write-Host "  2. Add 10 hooks to $settingsFile"
  Write-Host '     (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, Stop, SubagentStart, SubagentStop, Notification, StopFailure).'
  Write-Host '     A backup is saved first as settings.json.before-claude-progress.bak. Your other settings and hooks are kept.'
  Write-Host '  3. Add Start menu shortcuts (app with its settings, demo, uninstaller) and a shortcut that opens the window when you sign in'
  Write-Host "  4. Add a Task Scheduler entry 'Claude Progress' that reopens the window when Claude starts (runs as you, no admin)"
  Write-Host '  5. Open the window now, with its Settings'
  Write-Host 'It never: asks for admin rights, sends anything over the network, or changes any other setting.' -ForegroundColor DarkGray
  Write-Host "Node.js: $nodeFound" -ForegroundColor DarkGray
  Write-Host 'To undo it all later: Start menu > Claude Progress > Uninstall Claude Progress.' -ForegroundColor DarkGray
  Write-Host ''
  if (-not $Yes) {
    # No answer (e.g. run without a console) counts as No.
    # The question is printed either way, so whoever (or whatever) answers has seen it.
    $answer = if ([Console]::IsInputRedirected) { Write-Host 'Install? Type Y and press Enter (anything else cancels)'; [Console]::In.ReadLine() } else { Read-Host 'Install? Type Y and press Enter (anything else cancels)' }
    if ("$answer".Trim() -notmatch '^(y|yes)$') { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow; exit 0 }
  }
  # Install-timing check for testers: when the install started (the window adds when its first card appeared).
  New-Item -ItemType Directory -Force -Path $data | Out-Null
  $timing = [ordered]@{ version = $version; installerStartedAt = $startedAt; firstCardAt = $null }
  [IO.File]::WriteAllText((Join-Path $data 'install-timing.json'), ($timing | ConvertTo-Json -Compress))
}

# Run from inside a packaged app (e.g. Claude ran this)? Finish the install outside it, through
# Task Scheduler, so shortcuts and files land where Windows itself can see them.
Add-Type -Namespace CP -Name Pkg -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern int GetCurrentPackageFullName(ref int length, System.Text.StringBuilder name);'
$len = 0
if (-not $Outside -and [CP.Pkg]::GetCurrentPackageFullName([ref]$len, $null) -ne 15700) {
  $logFile = Join-Path $env:USERPROFILE '.claude-progress\install.log'
  New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null
  Remove-Item $logFile -ErrorAction SilentlyContinue
  # Escape for a single-quoted string the way PowerShell itself does (this also covers ’ ‘ quotes).
  $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"& '$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($PSCommandPath))' -Outside *> '$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($logFile))'`""
  Register-ScheduledTask -TaskName 'Claude Progress Setup' -Action $a -Force | Out-Null
  try {
    Start-ScheduledTask -TaskName 'Claude Progress Setup'
    Start-Sleep -Seconds 2
    while ((Get-ScheduledTask -TaskName 'Claude Progress Setup').State -eq 'Running') { Start-Sleep -Milliseconds 500 }
  } finally {
    # Removed even if this is stopped with Ctrl+C, so no leftover task.
    Unregister-ScheduledTask -TaskName 'Claude Progress Setup' -Confirm:$false -ErrorAction SilentlyContinue
  }
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
foreach ($f in 'hook.js','demo.js','settings-hooks.js','ClaudeProgress.ps1','chat-watch.ps1','uninstall.ps1','Uninstall.cmd','VERSION') {
  Copy-Item (Join-Path $src $f) (Join-Path $dest $f) -Force
}
# The Settings window's preview pictures (optional: it says so if they are missing).
$prev = Join-Path $src 'previews'
if (Test-Path $prev) {
  New-Item -ItemType Directory -Force -Path (Join-Path $dest 'previews') | Out-Null
  Copy-Item (Join-Path $prev 'style-*.png') (Join-Path $dest 'previews') -Force
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
# The Start menu entry opens Settings; the sign-in shortcut and the task start quietly (no argument).
New-Shortcut (Join-Path $menu 'Claude Progress.lnk') '-Settings' 'Shows what Claude is doing and how long is left, and its settings'
New-Shortcut (Join-Path $menu 'Claude Progress Demo.lnk') '-Demo' 'Plays a fake job to show how it looks'
Remove-Item (Join-Path $menu 'Claude Progress - Choose a style.lnk') -Force -ErrorAction SilentlyContinue   # from an earlier version
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

# 6. Start it. After a fresh install or an upgrade from before settings version 2, or if the style
#    Settings window was never seen, the window opens it:
#    - you ran this yourself: start it straight from here with -Settings, so Settings opens in front
#      with the keyboard (a Task Scheduler start may not take the foreground). This happens every time;
#    - it finished in the background (-Outside): the usual task start, plus a timed "open-picker" note
#      that opens it quietly, never taking the keyboard.
$wantPicker = $true
try {
  $wj = Get-Content -LiteralPath (Join-Path $data 'window.json') -Raw -ErrorAction Stop | ConvertFrom-Json
  if (($wj.prefsVersion -as [int]) -ge 2 -and $wj.pickerSeen) { $wantPicker = $false }
} catch {}
if (-not $Outside) {
  Start-Process powershell.exe -ArgumentList "$launchArgs -Settings" -WindowStyle Hidden
} else {
  if ($wantPicker) { [IO.File]::WriteAllText((Join-Path $data 'open-picker'), [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
  if ($haveTask) { Start-ScheduledTask -TaskName 'Claude Progress' }
  else { Start-Process powershell.exe -ArgumentList $launchArgs -WindowStyle Hidden }
}

Write-Host ''
Write-Host 'Done. The Claude Progress window is in the bottom-right corner.' -ForegroundColor Green
Write-Host 'Restart Claude (or start a new session) so it picks up the new hooks.'
Write-Host 'Start menu > Claude Progress opens the window and its Settings. There is also a demo and an uninstaller.'
