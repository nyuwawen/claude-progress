# Builds the release ZIP and its SHA256 checksum from a committed version of the repo.
#   powershell -ExecutionPolicy Bypass -File tools\build-release.ps1            (uses HEAD and VERSION)
#   powershell -ExecutionPolicy Bypass -File tools\build-release.ps1 -Ref v1.0.0
# Output: dist\claude-progress-<version>.zip and dist\claude-progress-<version>.zip.sha256
# Only committed files go in (git archive), so local videos, logs and test output never ship.
param([string]$Ref = 'HEAD')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

# The ZIP is built from the commit, so uncommitted changes to the app would silently not ship.
$appFiles = 'install.ps1','uninstall.ps1','hook.js','ClaudeProgress.ps1','chat-watch.ps1','settings-hooks.js','demo.js','Install.cmd','Uninstall.cmd','VERSION'
if ($Ref -eq 'HEAD' -and (git status --porcelain -- $appFiles)) { throw 'App files have uncommitted changes. Commit them first: the ZIP is built from the commit.' }
if (git status --porcelain --untracked-files=no) { Write-Host 'Note: other uncommitted changes are not in the ZIP (it is built from the commit).' -ForegroundColor Yellow }
if ($Ref -like '-*') { throw "Bad ref '$Ref'" }
$version = ((git show "${Ref}:VERSION") -join "`n").Trim()
# The version goes into file and folder names inside the ZIP: only plain x.y.z is allowed.
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Bad VERSION at ${Ref}: '$version' (expected x.y.z)" }
$name = "claude-progress-$version"
$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "$name.zip"

# The tests, docs and tools folders are for developers; the ZIP holds what a user needs.
git archive --format=zip --prefix="$name/" -o $zip $Ref -- . ':(exclude)tests' ':(exclude)docs' ':(exclude)tools' ':(exclude).gitignore'
if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
# Same format as sha256sum: "<hash>  <file name>"
[IO.File]::WriteAllText("$zip.sha256", "$hash  $name.zip`n")

Write-Host "Built $zip" -ForegroundColor Green
Write-Host "SHA256 $hash"
Write-Host "To check a download (prints True if it matches):"
Write-Host "  (Get-FileHash .\$name.zip -Algorithm SHA256).Hash -eq (Get-Content .\$name.zip.sha256).Split(' ')[0]"
