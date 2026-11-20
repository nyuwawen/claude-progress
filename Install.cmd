@echo off
if not exist "%~dp0install.ps1" (
  echo Unzip first: right-click the ZIP, choose Extract All, then run Install.cmd from the extracted folder.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
