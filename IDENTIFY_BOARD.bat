@echo off
setlocal
cd /d "%~dp0"

echo ============================================
echo  IDENTIFICAR CHIP ESPRESSIF - SIN FLASHEAR
echo ============================================
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0FIX_AND_FLASH.ps1" -IdentifyOnly

set EXITCODE=%ERRORLEVEL%
echo.
if "%EXITCODE%"=="0" (
  echo Identificacion finalizada. No se cargo firmware.
) else (
  echo La identificacion termino con codigo %EXITCODE%.
)
pause
exit /b %EXITCODE%
