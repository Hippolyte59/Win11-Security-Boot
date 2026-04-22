@echo off
setlocal

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo Elevation administrateur requise...
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "SCRIPT_DIR=%~dp0"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "TASK_NAME=Win11SecurityBoot"
set "SECURITY_SCRIPT=%SCRIPT_DIR%win11-startup-security.ps1"

if not exist "%SECURITY_SCRIPT%" (
  echo Script introuvable: "%SECURITY_SCRIPT%"
  exit /b 1
)

echo [1/2] Installation de la tache de demarrage...
set "TASK_CMD=\"%PS_EXE%\" -NoProfile -ExecutionPolicy Bypass -File \"%SECURITY_SCRIPT%\""
schtasks /Create /TN "%TASK_NAME%" /TR "%TASK_CMD%" /SC ONSTART /RU SYSTEM /RL HIGHEST /F >nul
if errorlevel 1 (
  echo Echec de l'installation de la tache de demarrage.
  exit /b 1
)

echo [2/2] Lancement immediat du durcissement...
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SECURITY_SCRIPT%"
if errorlevel 1 (
  echo Echec du lancement du script de securisation.
  exit /b 1
)

echo Terminee. La securisation est appliquee et la tache de demarrage est active.
exit /b 0
