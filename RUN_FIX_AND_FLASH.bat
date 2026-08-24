@echo off
setlocal
cd /d "%~dp0"

rem Default behavior: detect the Waveshare ESP32-S3 native USB first.
rem The board uses native USB, so Bluetooth COM ports and CH340 are not targets.
rem Optional manual override: RUN_FIX_AND_FLASH.bat COM8
if "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0WAVESHARE_USB_BOOT.ps1"
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0WAVESHARE_USB_BOOT.ps1" -Port "%~1"
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
