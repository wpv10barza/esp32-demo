@echo off
setlocal
cd /d "%~dp0"

echo ============================================
echo  WAVESHARE HARDWARE IDENTIFICATION - SAFE
 echo ============================================
echo.
echo Expected target : ESP32-S3 / ESP32-S3R8 / 16 MB flash / 8 MB PSRAM
 echo This command DOES NOT flash firmware.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0FIX_AND_FLASH.ps1" -IdentifyOnly

set EXITCODE=%ERRORLEVEL%
echo.
if "%EXITCODE%"=="0" (
  echo Hardware identification completed. No firmware was written.
) else (
  echo Hardware identification ended with code %EXITCODE%.
)
pause
exit /b %EXITCODE%
