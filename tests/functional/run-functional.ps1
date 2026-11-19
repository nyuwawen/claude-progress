# Claude Progress - functional tests.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\functional\run-functional.ps1
# Safe to run next to a real install: every child process gets a temp USERPROFILE and/or
# CLAUDE_PROGRESS_DIR, nothing is clicked, and no window is shown on screen
# (-Snapshot renders off-screen at -10000,-10000).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$app = Join-Path $repo 'ClaudeProgress.ps1'
$hook = Join-Path $repo 'hook.js'
$demo = Join-Path $repo 'demo.js'
$work = Join-Path ([IO.Path]::GetTempPath()) ("cp-functional-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$node = (Get-Command node -ErrorAction Stop).Source
$utf8 = New-Object System.Text.UTF8Encoding($false)

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$id, [string]$status, [string]$detail) {
  $results.Add([pscustomobject]@{ id = $id; status = $status; detail = $detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'Yellow' }[$status]
  Write-Host ("{0} [{1}] {2}" -f $status, $id, $detail) -ForegroundColor $color
}
function Invoke-Check([string]$id, [scriptblock]$body) {
  try {
    $r = & $body
    if ($r -is [array]) { $r = $r[-1] }
    Add-Result $id $r.status $r.detail
  } catch { Add-Result $id 'FAIL' "exception: $($_.Exception.Message)" }
}
function Ok([string]$d) { @{ status = 'PASS'; detail = $d } }
function Bad([string]$d) { @{ status = 'FAIL'; detail = $d } }

# Runs a process hidden with extra environment variables; returns exit code, stdout, stderr.
function Start-Proc([string]$exe, [string[]]$argv, [hashtable]$envVars, [string]$cwd = $repo) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ($argv | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $cwd
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  if ($envVars) { foreach ($k in $envVars.Keys) { $psi.EnvironmentVariables[$k] = [string]$envVars[$k] } }
  $p = [System.Diagnostics.Process]::Start($psi)
  @{ proc = $p; out = $p.StandardOutput.ReadToEndAsync(); err = $p.StandardError.ReadToEndAsync() }
}
function Wait-Proc($h, [int]$timeoutMs = 120000) {
  if (-not $h.proc.WaitForExit($timeoutMs)) { try { $h.proc.Kill() } catch {}; throw "timed out after $timeoutMs ms" }
  $h.proc.WaitForExit()
  @{ code = $h.proc.ExitCode; out = $h.out.Result; err = $h.err.Result }
}
function Invoke-Proc([string]$exe, [string[]]$argv, [hashtable]$envVars, [int]$timeoutMs = 120000) {
  Wait-Proc (Start-Proc $exe $argv $envVars) $timeoutMs
}
# A throwaway home folder, so the app's %USERPROFILE%\.claude-progress writes land in temp.
function New-FakeHome([string]$name) {
  $h = Join-Path $work $name; New-Item -ItemType Directory -Force -Path $h | Out-Null
  @{ USERPROFILE = $h; CLAUDE_PROGRESS_DIR = (Join-Path $h '.claude-progress') }
}
function Invoke-App([string[]]$extra, [string]$homeName) {
  Invoke-Proc 'powershell.exe' (@('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $app) + $extra) (New-FakeHome $homeName)
}
function Read-JsonFile([string]$f) {
  try { if (Test-Path $f) { return ([IO.File]::ReadAllText($f) | ConvertFrom-Json) } } catch {}
  $null
}
function Get-Props($o) { if ($null -eq $o) { @() } else { @($o.PSObject.Properties) } }

Write-Host "Repo: $repo"
Write-Host "Temp: $work"
Write-Host ''

# ---------- 1. SelfTest ----------
Invoke-Check '1 SelfTest' {
  $r = Invoke-App @('-SelfTest') 'home-selftest'
  if ($r.code -ne 0) { return Bad "exit $($r.code): $($r.err.Trim())" }
  if ($r.out -notmatch 'Window built OK') { return Bad "output: $($r.out.Trim()) $($r.err.Trim())" }
  if ($r.err.Trim()) { return Bad "stderr: $($r.err.Trim())" }
  Ok $r.out.Trim()
}

# ---------- 2. Snapshot ----------
Add-Type -AssemblyName System.Drawing
$snapDir = Join-Path $work 'snapshots'
$snap = $null
try { $snap = Invoke-App @('-Snapshot', $snapDir) 'home-snapshot' } catch { $snapErr = $_.Exception.Message }
$sizes = @{}
foreach ($n in 'Normal', 'DADA', 'Ren', 'DADA-mini') {
  Invoke-Check "2 Snapshot $n" {
    if (-not $snap) { return Bad "snapshot run failed: $snapErr" }
    if ($snap.code -ne 0) { return Bad "exit $($snap.code): $($snap.err.Trim())" }
    $f = Join-Path $snapDir "theme-$n.png"
    if (-not (Test-Path $f)) { return Bad "missing $f" }
    $bmp = New-Object System.Drawing.Bitmap($f)
    try {
      $w = $bmp.Width; $h = $bmp.Height
      $sizes[$n] = @($w, $h)
      if ($w -lt 200 -or $h -lt 40 -or $w -gt 4000 -or $h -gt 6000) { return Bad "odd size ${w}x$h" }
      # Sample a 40x40 grid: count opaque pixels, distinct colours and luminance spread.
      $colors = @{}; $opaque = 0; $lum = New-Object System.Collections.Generic.List[double]
      for ($y = 0; $y -lt 40; $y++) { for ($x = 0; $x -lt 40; $x++) {
        $c = $bmp.GetPixel([int](($x + 0.5) * $w / 40), [int](($y + 0.5) * $h / 40))
        $colors[$c.ToArgb()] = 1
        if ($c.A -gt 200) { $opaque++; $lum.Add(0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) }
      } }
      $mean = ($lum | Measure-Object -Average).Average
      $sd = if ($lum.Count) { [math]::Sqrt((($lum | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum) / $lum.Count) } else { 0 }
      $d = "${w}x$h, opaque $opaque/1600, $($colors.Count) colours, luma sd $([math]::Round($sd,1))"
      if ($opaque -lt 160) { return Bad "mostly transparent: $d" }
      if ($colors.Count -lt 20 -or $sd -lt 3) { return Bad "looks blank: $d" }
      Ok $d
    } finally { $bmp.Dispose() }
  }
}
Invoke-Check '2 Snapshot distinct' {
  $files = 'Normal', 'DADA', 'Ren', 'DADA-mini' | ForEach-Object { Join-Path $snapDir "theme-$_.png" } | Where-Object { Test-Path $_ }
  if (@($files).Count -ne 4) { return Bad 'not all snapshots present' }
  $hashes = $files | ForEach-Object { (Get-FileHash $_ -Algorithm SHA256).Hash }
  if (@($hashes | Select-Object -Unique).Count -ne 4) { return Bad 'two or more theme snapshots are identical' }
  if ($sizes['DADA-mini'] -and $sizes['DADA'] -and $sizes['DADA-mini'][1] -ge $sizes['DADA'][1]) {
    return Bad "mini view not shorter than full (mini $($sizes['DADA-mini'] -join 'x'), full $($sizes['DADA'] -join 'x'))"
  }
  Ok "4 different images; mini $($sizes['DADA-mini'] -join 'x') < full $($sizes['DADA'] -join 'x')"
}

# ---------- 3. -Theme / -Mode with -SelfTest ----------
foreach ($a in @(@('-Theme', 'Normal'), @('-Theme', 'DADA'), @('-Theme', 'Ren'), @('-Mode', 'Saver'), @('-Mode', 'Neutral'), @('-Mode', 'Full'))) {
  Invoke-Check "3 SelfTest $($a -join ' ')" {
    $r = Invoke-App (@('-SelfTest') + $a) 'home-selftest-args'
    if ($r.code -ne 0 -or $r.out -notmatch 'Window built OK' -or $r.err.Trim()) { return Bad "exit $($r.code) out='$($r.out.Trim())' err='$($r.err.Trim())'" }
    Ok $r.out.Trim()
  }
}

# ---------- 4. Demo pipeline (no UI) ----------
$demoDir = Join-Path $work 'demo-data'
$stateF = Join-Path $demoDir 'state.json'; $histF = Join-Path $demoDir 'history.json'
$seen = @{ sessions = @{}; titles = @{}; stepKeys = @{}; renderEstimate = $null; polls = 0; maxRunning = 0 }
$demoRun = $null
try {
  $h = Start-Proc $node @($demo, $hook) @{ CLAUDE_PROGRESS_DIR = $demoDir }
  $deadline = (Get-Date).AddSeconds(90)
  while (-not $h.proc.HasExited -and (Get-Date) -lt $deadline) {
    $s = Read-JsonFile $stateF
    if ($s) {
      $seen.polls++
      foreach ($p in (Get-Props $s.sessions)) {
        $seen.sessions[$p.Name] = 1
        if ($p.Value.title) { $seen.titles[$p.Name] = $p.Value.title }
        $steps = @(Get-Props $p.Value.steps)
        if ($steps.Count -gt $seen.maxRunning) { $seen.maxRunning = $steps.Count }
        foreach ($st in $steps) {
          $seen.stepKeys[$st.Value.key] = 1
          if ($st.Value.key -eq 'Bash:ffmpeg:render') { $seen.renderEstimate = $st.Value.estimateMs }
        }
      }
    }
    Start-Sleep -Milliseconds 200
  }
  $demoRun = Wait-Proc $h 5000
} catch { $demoErr = $_.Exception.Message }
$final = Read-JsonFile $stateF
$hist = Read-JsonFile $histF

Invoke-Check '4 Demo exits cleanly' {
  if (-not $demoRun) { return Bad "demo did not finish: $demoErr" }
  if ($demoRun.code -ne 0) { return Bad "exit $($demoRun.code): $($demoRun.err.Trim())" }
  Ok "exit 0 after $($seen.polls) state.json polls"
}
Invoke-Check '4 Demo sessions + titles' {
  $want = @{ 'demo-video' = 'Render the product intro video in 4K'; 'demo-form' = 'Fix the contact form validation' }
  foreach ($k in $want.Keys) {
    if (-not $seen.sessions[$k]) { return Bad "session $k never appeared (saw: $($seen.sessions.Keys -join ', '))" }
    if ($seen.titles[$k] -ne $want[$k]) { return Bad "session $k title '$($seen.titles[$k])'" }
  }
  Ok "demo-video='$($seen.titles['demo-video'])', demo-form='$($seen.titles['demo-form'])'"
}
Invoke-Check '4 Demo steps start (live)' {
  foreach ($k in 'Read', 'Grep', 'Edit', 'Bash:ffmpeg:render', 'Bash:npm') { if (-not $seen.stepKeys[$k]) { return Bad "running step $k never seen (saw: $($seen.stepKeys.Keys -join ', '))" } }
  if ($seen.renderEstimate -ne 13000) { return Bad "render step estimate $($seen.renderEstimate), expected 13000 (median of seeded history)" }
  if ($seen.maxRunning -lt 1) { return Bad 'never saw a running step' }
  Ok "seen running: $(($seen.stepKeys.Keys | Sort-Object) -join ', '); render estimate 13000 ms"
}
Invoke-Check '4 Demo steps end (log)' {
  if (-not $final) { return Bad 'no final state.json' }
  $v = $final.sessions.'demo-video'; $f = $final.sessions.'demo-form'
  $vl = @($v.log); $fl = @($f.log)
  if (@(Get-Props $v.steps).Count -or @(Get-Props $f.steps).Count) { return Bad 'steps still running at the end' }
  if ($vl.Count -ne 3) { return Bad "demo-video log has $($vl.Count) entries, expected 3" }
  if ($fl.Count -ne 6) { return Bad "demo-form log has $($fl.Count) entries, expected 6" }
  if (@($vl | Where-Object { -not $_.endedAt -or $_.endedAt -lt $_.startedAt }).Count) { return Bad 'log entry without valid endedAt' }
  $render = $vl | Where-Object { $_.key -eq 'Bash:ffmpeg:render' }
  if (-not $render -or $render.cat -ne 'render' -or ($render.endedAt - $render.startedAt) -lt 20000) { return Bad 'render step missing/short in log' }
  Ok "video log: $(($vl | ForEach-Object { $_.label }) -join ' > '); form log: $($fl.Count) entries"
}
Invoke-Check '4 Demo failed npm test ok=false' {
  $fl = @($final.sessions.'demo-form'.log)
  $failRun = $fl | Where-Object { $_.detail -eq 'Run the test suite' }
  $passRun = $fl | Where-Object { $_.detail -eq 'Run the test suite again' }
  if (-not $failRun) { return Bad 'first npm test not in log' }
  if ($failRun.ok -ne $false) { return Bad "first npm test ok=$($failRun.ok)" }
  if ($passRun.ok -ne $true) { return Bad "second npm test ok=$($passRun.ok)" }
  if (@($fl | Where-Object { $_.ok -eq $false }).Count -ne 1) { return Bad 'more than one failed step' }
  Ok "'Run the test suite' ok=false, 'Run the test suite again' ok=true"
}
Invoke-Check '4 Demo history grows' {
  if (-not $hist) { return Bad 'no history.json' }
  $exp = @{ turn = 5; Read = 4; Grep = 2; Edit = 4; Write = 2; 'Bash:ffmpeg:render' = 4; 'Bash:npm' = 2 }
  $bad = @(); foreach ($k in $exp.Keys) { $n = @($hist.$k).Count; if ($n -ne $exp[$k]) { $bad += "$k=$n (want $($exp[$k]))" } }
  if ($bad) { return Bad ($bad -join '; ') }
  Ok (($exp.Keys | Sort-Object | ForEach-Object { "$_=$(@($hist.$_).Count)" }) -join ', ')
}
Invoke-Check '4 Demo sessions finished' {
  $bad = @()
  foreach ($k in 'demo-video', 'demo-form') {
    $s = $final.sessions.$k
    if (-not $s) { $bad += "$k missing"; continue }
    if (-not $s.finishedAt) { $bad += "$k finishedAt not set" }
    if ($null -ne $s.turnStartedAt) { $bad += "$k turnStartedAt=$($s.turnStartedAt)" }
    if (-not $s.lastTurnMs -or $s.lastTurnMs -lt 15000) { $bad += "$k lastTurnMs=$($s.lastTurnMs)" }
  }
  if ($bad) { return Bad ($bad -join '; ') }
  Ok "video lastTurnMs=$($final.sessions.'demo-video'.lastTurnMs), form lastTurnMs=$($final.sessions.'demo-form'.lastTurnMs)"
}

# ---------- 5. Chat watcher path ----------
# Runs chat-watch.ps1's own Send-Hook (pipe JSON into node, as the watcher does) in a child
# Windows PowerShell, replaying Start-Chat / Set-Step / Stop-Chat for one chat.
function Invoke-ChatReplay([string]$title, [string[]]$stepTexts, [string]$dir) {
  $driver = Join-Path $work ("chat-replay-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
  $src = @'
param([string]$Hook, [string]$TitleFile, [string]$StepsFile)
$ErrorActionPreference = 'Stop'
$hook = $Hook
# Use the watcher's real Send-Hook, taken from chat-watch.ps1, so the test can't drift from it.
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $Hook) 'chat-watch.ps1'), [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Send-Hook' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))
$title = [IO.File]::ReadAllText($TitleFile)
$steps = @([IO.File]::ReadAllLines($StepsFile) | Where-Object { $_ })
$sid = 'chat:' + $title
Send-Hook 'prompt' @{ session_id = $sid; cwd = 'Claude chat'; prompt = $title; turn_key = 'chat-turn' }
Start-Sleep -Milliseconds 400
$n = 0; $prevId = $null; $prevText = $null
foreach ($t in $steps) {
  if ($prevId) { Send-Hook 'post' @{ session_id = $sid; cwd = 'Claude chat'; tool_name = 'ClaudeChat'; tool_input = @{ description = $prevText }; tool_use_id = $prevId } }
  $n++; $prevId = "$sid-$n"; $prevText = $t
  Send-Hook 'pre' @{ session_id = $sid; cwd = 'Claude chat'; tool_name = 'ClaudeChat'; tool_input = @{ description = $t }; tool_use_id = $prevId }
  Start-Sleep -Milliseconds 400
}
if ($prevId) { Send-Hook 'post' @{ session_id = $sid; cwd = 'Claude chat'; tool_name = 'ClaudeChat'; tool_input = @{ description = $prevText }; tool_use_id = $prevId } }
Send-Hook 'stop' @{ session_id = $sid; cwd = 'Claude chat'; turn_key = 'chat-turn' }
'@
  [IO.File]::WriteAllText($driver, $src, $utf8)
  $tf = "$driver.title"; $sf = "$driver.steps"
  [IO.File]::WriteAllText($tf, $title, $utf8); [IO.File]::WriteAllLines($sf, $stepTexts, $utf8)
  Invoke-Proc 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driver, $hook, $tf, $sf) @{ CLAUDE_PROGRESS_DIR = $dir } 60000
}

$chatDir = Join-Path $work 'chat-data'
$chatTitle = 'Plan a weekend trip to Kyoto'
$chatSteps = @('Searching the web', 'Reading files', 'Creating an artifact', 'Analyzing data', 'Thinking deeply')
$chatRun = $null
try { $chatRun = Invoke-ChatReplay $chatTitle $chatSteps $chatDir } catch { $chatErr = $_.Exception.Message }
$cs = Read-JsonFile (Join-Path $chatDir 'state.json'); $ch = Read-JsonFile (Join-Path $chatDir 'history.json')

Invoke-Check '5 Chat session created' {
  if (-not $chatRun) { return Bad "replay failed: $chatErr" }
  if (-not $cs) { return Bad 'no state.json written' }
  $names = @(Get-Props $cs.sessions | ForEach-Object Name)
  $s = $cs.sessions."chat:$chatTitle"
  if (-not $s) { return Bad "no 'chat:$chatTitle' session (sessions: $($names -join ', '))" }
  if ($names -contains 'default') { return Bad "a 'default' session appeared (hook could not parse a payload)" }
  if ($s.cwd -ne 'Claude chat') { return Bad "cwd='$($s.cwd)'" }
  if ($s.title -ne $chatTitle) { return Bad "title='$($s.title)'" }
  if (-not $s.finishedAt -or $null -ne $s.turnStartedAt) { return Bad 'session not finished after stop' }
  Ok "session 'chat:$chatTitle', cwd 'Claude chat', finished"
}
Invoke-Check '5 Chat steps categorised' {
  $log = @($cs.sessions."chat:$chatTitle".log)
  $want = [ordered]@{ 'Searching the web' = 'web'; 'Reading files' = 'read'; 'Creating an artifact' = 'render'; 'Analyzing data' = 'run'; 'Thinking deeply' = 'other' }
  if ($log.Count -ne $want.Count) { return Bad "log has $($log.Count) entries, expected $($want.Count)" }
  $bad = @(); $i = 0
  foreach ($k in $want.Keys) {
    $e = $log[$i++]
    if ($e.label -ne $k -or $e.cat -ne $want[$k] -or $e.key -ne "chat:$($k.ToLower())" -or $e.ok -ne $true) { $bad += "$k -> label='$($e.label)' cat=$($e.cat) key=$($e.key) ok=$($e.ok)" }
  }
  if ($bad) { return Bad ($bad -join '; ') }
  Ok (($want.Keys | ForEach-Object { "$_=$($want[$_])" }) -join ', ')
}
Invoke-Check "5 Chat 'chat-turn' history" {
  if (-not $ch) { return Bad 'no history.json' }
  if (@($ch.'chat-turn').Count -ne 1) { return Bad "chat-turn entries: $(@($ch.'chat-turn').Count)" }
  if ($null -ne $ch.turn) { return Bad "'turn' history was written: $($ch.turn -join ',')" }
  Ok "chat-turn=[$($ch.'chat-turn' -join ',')] ms, no 'turn' key; step keys: $((Get-Props $ch | ForEach-Object Name | Where-Object { $_ -like 'chat:*' }) -join ', ')"
}

# Chat titles are often not plain ASCII (accents, CJK, emoji). Same replay, non-ASCII title.
$chatDir2 = Join-Path $work 'chat-data-unicode'
$uTitle = "Caf$([char]0xE9) menu $([char]0x2014) $([char]0x4E2D)$([char]0x6587)"
try { [void](Invoke-ChatReplay $uTitle @('Searching the web') $chatDir2) } catch {}
$cs2 = Read-JsonFile (Join-Path $chatDir2 'state.json')
Invoke-Check '5 Chat non-ASCII title' {
  if (-not $cs2) { return Bad 'no state.json written' }
  $names = @(Get-Props $cs2.sessions | ForEach-Object Name)
  if ($names -contains "chat:$uTitle") { return Ok "title kept: $uTitle" }
  Bad "title '$uTitle' arrived as session(s) $(($names | ForEach-Object { "'$_'" }) -join ', ') with title '$((Get-Props $cs2.sessions | Select-Object -First 1).Value.title)'"
}

# ---------- 6. Live read-only UI Automation probe ----------
Invoke-Check '6 Claude app UIA tabs' {
  $p = Get-Process -Name 'claude' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { return @{ status = 'SKIP'; detail = "no 'claude' process with a main window (desktop app not open)" } }
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  $A = [System.Windows.Automation.AutomationElement]; $CT = [System.Windows.Automation.ControlType]
  $cond = New-Object System.Windows.Automation.OrCondition(
    (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::Button)),
    (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::RadioButton)),
    (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::Document)))
  $tabs = @{}; $total = 0
  # Chromium builds its accessibility tree on first request: read up to 3 times.
  for ($try = 0; $try -lt 3 -and $tabs.Count -lt 2; $try++) {
    if ($try) { Start-Sleep -Seconds 2 }
    $win = $A::FromHandle($p.MainWindowHandle)
    $els = $win.FindAll('Descendants', $cond); $total = $els.Count
    foreach ($e in $els) {
      $c = $e.Current
      if ($c.ControlType -eq $CT::RadioButton -and ($c.Name -eq 'Claude' -or $c.Name -eq 'Code')) {
        $sel = $null
        try { $sel = $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } catch {}
        $tabs[$c.Name] = $sel
      }
    }
  }
  $d = "pid $($p.Id), $total elements; tabs: " + (($tabs.Keys | Sort-Object | ForEach-Object { "$_ selected=$($tabs[$_])" }) -join ', ')
  if (-not $tabs.ContainsKey('Claude') -or -not $tabs.ContainsKey('Code')) { return Bad "tab radio buttons not found: $d" }
  if (@($tabs.Values | Where-Object { $_ -eq $true }).Count -ne 1) { return Bad "expected exactly one selected tab: $d" }
  Ok $d
}

# ---------- 7. Parse checks ----------
$files = Get-ChildItem -Path $repo -Recurse -File -Include *.ps1, *.js | Where-Object { $_.FullName -notmatch '\\(node_modules|\.git)\\' }
foreach ($f in ($files | Where-Object Extension -eq '.ps1')) {
  Invoke-Check "7 parse $($f.FullName.Substring($repo.Length + 1))" {
    $tok = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$errs)
    if ($errs.Count) { return Bad (($errs | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') }
    Ok '0 parse errors'
  }
}
foreach ($f in ($files | Where-Object Extension -eq '.js')) {
  Invoke-Check "7 node --check $($f.FullName.Substring($repo.Length + 1))" {
    $r = Invoke-Proc $node @('--check', $f.FullName) @{} 30000
    if ($r.code -ne 0) { return Bad $r.err.Trim() }
    Ok 'syntax OK'
  }
}

# ---------- summary ----------
$pass = @($results | Where-Object status -eq 'PASS').Count
$fail = @($results | Where-Object status -eq 'FAIL').Count
$skip = @($results | Where-Object status -eq 'SKIP').Count
Write-Host ''
Write-Host "SUMMARY: $pass passed, $fail failed, $skip skipped ($($results.Count) checks). Temp files: $work"
if ($fail) { exit 1 } else { exit 0 }
