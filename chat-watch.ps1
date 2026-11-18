param([int]$ParentPid = 0, [int]$IntervalMs = 1500)
# Claude Progress - chat watcher.
# Regular Claude chats (the Claude tab of the desktop app) have no hooks, so this reads the
# app's window through Windows UI Automation instead:
#   - a chat in the sidebar whose name ends in "Running" is replying
#   - the open chat shows its current step ("Searching the web running") and a "Stop response" button
# Changes are sent through hook.js, so chats appear as cards just like Claude Code sessions.
# Only the Claude tab is read; Code sessions are already tracked by their hooks.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$root = Join-Path $env:USERPROFILE '.claude-progress'
$hook = Join-Path $PSScriptRoot 'hook.js'
$log = Join-Path $root 'window-errors.log'

$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeProgressChatWatch')
if (-not $mutex.WaitOne(0)) { exit 0 }
try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch {}

function Send-Hook($event, $payload) {
  $json = $payload | ConvertTo-Json -Compress
  try { $json | & node $hook $event 2>$null | Out-Null } catch {}
}

$cond = New-Object System.Windows.Automation.OrCondition(
  (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::Button)),
  (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::RadioButton)),
  (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::Document)))

# title -> @{ sid; stepId; stepText; n }
$live = @{}
$frozenSince = $null

function Read-Window {
  $p = Get-Process -Name 'claude' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { return $null }
  $win = $A::FromHandle($p.MainWindowHandle)
  $els = $win.FindAll('Descendants', $cond)
  $r = @{ chatTab = $false; codeTab = $false; running = New-Object System.Collections.Generic.List[string]; open = $null; step = $null; responding = $false }
  foreach ($e in $els) {
    $c = $e.Current; $name = $c.Name
    if (-not $name) { continue }
    if ($c.ControlType -eq $CT::RadioButton -and ($name -eq 'Claude' -or $name -eq 'Code')) {
      $sel = $false
      try { $sel = $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } catch {}
      if ($sel) { if ($name -eq 'Claude') { $r.chatTab = $true } else { $r.codeTab = $true } }
    } elseif ($c.ControlType -eq $CT::Document) {
      if ($name -cmatch '^(.+) - Claude$') { $r.open = $Matches[1] }
    } elseif ($name -ceq 'Stop response') {
      $r.responding = $true
    } elseif ($name -cmatch '^(.+?) Running( .*)?$') {
      $r.running.Add($Matches[1])
    } elseif ($name -cmatch '^(.+) running$') {
      $r.step = $Matches[1]
    }
  }
  # The window is first read before Chromium has built its accessibility tree: ask again next time.
  if (-not $r.chatTab -and -not $r.codeTab) { return @{ unknown = $true } }
  if ($r.responding -and $r.open -and -not $r.running.Contains($r.open)) { $r.running.Add($r.open) }
  $r
}

function Start-Chat($title) {
  $sid = 'chat:' + $title
  Send-Hook 'prompt' @{ session_id = $sid; cwd = 'Claude chat'; prompt = $title; turn_key = 'chat-turn' }
  $live[$title] = @{ sid = $sid; stepId = $null; stepText = $null; n = 0 }
}
function Set-Step($title, $text) {
  $s = $live[$title]
  if ($s.stepText -eq $text) { return }
  if ($s.stepId) { Send-Hook 'post' @{ session_id = $s.sid; cwd = 'Claude chat'; tool_name = 'ClaudeChat'; tool_input = @{ description = $s.stepText }; tool_use_id = $s.stepId } }
  $s.stepId = $null; $s.stepText = $text
  if ($text) {
    $s.n++; $s.stepId = "$($s.sid)-$($s.n)"
    Send-Hook 'pre' @{ session_id = $s.sid; cwd = 'Claude chat'; tool_name = 'ClaudeChat'; tool_input = @{ description = $text }; tool_use_id = $s.stepId }
  }
}
function Stop-Chat($title) {
  Send-Hook 'stop' @{ session_id = $live[$title].sid; cwd = 'Claude chat'; turn_key = 'chat-turn' }
  $live.Remove($title)
}

while ($true) {
  if ($ParentPid -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
  try {
    $w = Read-Window
    if ($null -eq $w) {
      foreach ($t in @($live.Keys)) { Stop-Chat $t }   # app closed: those replies are over
    } elseif ($w.unknown) {
    } elseif ($w.chatTab) {
      $frozenSince = $null
      foreach ($t in $w.running) { if (-not $live.ContainsKey($t)) { Start-Chat $t } }
      foreach ($t in @($live.Keys)) { if (-not $w.running.Contains($t)) { Stop-Chat $t } }
      if ($w.open -and $live.ContainsKey($w.open)) { Set-Step $w.open $w.step }
    } else {
      # On the Code tab the chat list can't be seen: keep chats as they were, for up to 10 minutes.
      if (-not $frozenSince) { $frozenSince = Get-Date }
      if (((Get-Date) - $frozenSince).TotalMinutes -gt 10) { foreach ($t in @($live.Keys)) { Stop-Chat $t } }
    }
  } catch {
    try { Add-Content -Path $log -Value "$(Get-Date -Format s) chat-watch: $($_.Exception.Message)" } catch {}
    Start-Sleep -Seconds 5
  }
  Start-Sleep -Milliseconds $IntervalMs
}
foreach ($t in @($live.Keys)) { Stop-Chat $t }
