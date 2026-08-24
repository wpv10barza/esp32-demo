@echo off
setlocal
cd /d "%~dp0"
set PORT=COM9
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0FIX_AND_FLASH.ps1" -Port %PORT%
set EXITCODE=%ERRORLEVEL%
echo.
if "%EXITCODE%"=="0" (
  echo Proceso finalizado correctamente.
) else (
  echo El proceso termino con codigo %EXITCODE%. Revisa el mensaje superior.
)
pause
exit /b %EXITCODE%
