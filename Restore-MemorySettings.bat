@echo off
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
echo Requesting administrator permission for restore...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p = Join-Path -LiteralPath '%SCRIPT_DIR%' -ChildPath 'Restore-Settings.ps1'; Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$p)"
if errorlevel 1 (
  echo The restore workflow returned an error. Review Logs and Reports.
)
pause
endlocal
