@echo off
setlocal
cd /d "%~dp0"

rem Default behavior: do NOT force any COM port.
rem FIX_AND_FLASH.ps1 defaults to -Port AUTO and safely probes for ESP32-S3.
rem Optional manual override: RUN_FIX_AND_FLASH.bat COM8
if "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0FIX_AND_FLASH.ps1"
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0FIX_AND_FLASH.ps1" -Port "%~1"
)

set EXITCODE=%ERRORLEVEL%
echo.
if "%EXITCODE%"=="0" (
  echo Proceso finalizado correctamente.
) else (
  echo El proceso termino con codigo %EXITCODE%. Revisa el mensaje superior.
)
pause
exit /b %EXITCODE%
