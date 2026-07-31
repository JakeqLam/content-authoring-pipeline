@echo off
setlocal

set "PRESET=full-diagnostics"
if not "%~1"=="" set "PRESET=%~1"

powershell.exe ^
  -NoLogo ^
  -NoProfile ^
  -ExecutionPolicy Bypass ^
  -File "%~dp0collect-issue.ps1" ^
  -Preset "%PRESET%"

set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
    echo.
    echo Diagnostic collection failed with exit code %EXIT_CODE%.
    pause
)
exit /b %EXIT_CODE%
