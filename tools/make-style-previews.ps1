# Renders the style picker's preview pictures into previews\ (every style in every theme),
# from the real window code with sample chats. Run it again after changing how the window looks.
# Uses a throwaway profile folder, so your real settings and running window are never touched.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo 'previews'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('cp-previews-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $out, $tmp | Out-Null
$origProfile = $env:USERPROFILE
Push-Location $tmp
try {
  $env:USERPROFILE = $tmp
  & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $repo 'ClaudeProgress.ps1') -Snapshot $out -StylePreviews
  if ($LASTEXITCODE -ne 0) { throw "rendering failed (exit $LASTEXITCODE)" }
} finally {
  $env:USERPROFILE = $origProfile
  Pop-Location
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
