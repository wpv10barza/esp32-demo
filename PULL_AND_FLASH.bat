@echo off
setlocal
cd /d "%~dp0"

echo ============================================
echo  WAVESHARE - GET LATEST + BUILD + FLASH
echo ============================================
echo.

where git >nul 2>nul
if errorlevel 1 (
  echo [ERROR] Git no esta instalado o no esta en PATH.
  echo Instala Git for Windows y vuelve a ejecutar.
  pause
  exit /b 1
)

if not exist ".git" (
  echo [ERROR] Esta carpeta aun no esta vinculada al repositorio GitHub.
  echo Ejecuta primero las instrucciones de ADOPT_EXISTING_FOLDER.txt.
  pause
  exit /b 1
)

echo [1/2] Descargando la ultima version...
git pull --ff-only
if errorlevel 1 (
  echo.
  echo [ERROR] git pull fallo. No se modificara ni cargara firmware.
  pause
  exit /b 1
)

echo.
echo [2/2] Compilando y cargando...
rem No argument = automatic ESP32-S3 detection.
rem Optional override: PULL_AND_FLASH.bat COM8
call "%~dp0RUN_FIX_AND_FLASH.bat" %*
exit /b %ERRORLEVEL%
