@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "COLLECTOR=%SCRIPT_DIR%collect-issue.ps1"

if not exist "%COLLECTOR%" (
    echo [DND-COLLECT] Missing script:
    echo %COLLECTOR%
    echo.
    pause
    exit /b 1
)

echo [DND-COLLECT] Starting one-click issue collection...
echo.

if "%~1"=="" (
    powershell.exe ^
      -NoLogo ^
      -NoProfile ^
      -ExecutionPolicy Bypass ^
      -File "%COLLECTOR%"
) else (
    powershell.exe ^
      -NoLogo ^
      -NoProfile ^
      -ExecutionPolicy Bypass ^
      -File "%COLLECTOR%" ^
      -Preset "%~1"
)

set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo [DND-COLLECT] FAILED with exit code %EXIT_CODE%.
) else (
    echo [DND-COLLECT] SUCCESS.
)

echo.
pause
exit /b %EXIT_CODE%
