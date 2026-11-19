# PoC for install.ps1:17. Builds the scheduled-task -Command string exactly as install.ps1 does,
# for a folder name containing a single quote, then PARSES it (never runs it) to show what the
# relaunched powershell.exe would execute. No task is registered.
$cases = @(
  'C:\Users\demo\Downloads\Claude Progress\install.ps1',
  "C:\Users\demo\Downloads\Bob's tools\install.ps1",
  "C:\Users\demo\Downloads\x'; Start-Process calc; '\install.ps1",
  "C:\Users\demo\Downloads\x'; Start-Process calc; & 'y\install.ps1",
  # PowerShell also treats the typographic quotes U+2018/U+2019/U+201A/U+201B as single quotes.
  "C:\Users\demo\Downloads\Bob$([char]0x2019)s tools\install.ps1",
  "C:\Users\demo\Downloads\x$([char]0x2019); Start-Process calc; & $([char]0x2018)y\install.ps1"
)
$logFile = 'C:\Users\demo\.claude-progress\install.log'
foreach ($PSCommandPath in $cases) {
  # The line is read from install.ps1 itself (the "$a = New-ScheduledTaskAction ..." -Argument string) so the PoC tracks fixes.
  $line = (Select-String -Path (Join-Path $PSScriptRoot '..\..\install.ps1') -Pattern '-Argument "-NoProfile -ExecutionPolicy Bypass -Command').Line
  $argExpr = [regex]::Match($line, '-Argument (".*")\s*$').Groups[1].Value
  $testPath = $PSCommandPath
  $arg = Invoke-Expression ($argExpr.Replace('$PSCommandPath', '$testPath'))  # expands only install.ps1's own string expression with the test path
  if (-not $script:shown) { "install.ps1 expression: $argExpr"; $script:shown = $true }
  $cmd = ($arg -replace '^.*-Command "', '') -replace '"$', ''
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$errs)
  $cmds = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() + ' <= ' + $_.Extent.Text }
  "PATH: $PSCommandPath"
  "  parse errors: $(@($errs).Count)  $(@($errs | % Message) -join '; ')"
  "  commands:     $($cmds -join '  |  ')"
}
