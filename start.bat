@echo off
setlocal

for /f %%e in ('echo prompt $E ^| cmd') do set "ESC=%%e"
set "C_RESET=%ESC%[0m"
set "C_INFO=%ESC%[96m"
set "C_OK=%ESC%[92m"
set "C_WARN=%ESC%[93m"
set "C_ERR=%ESC%[91m"
set "C_TITLE=%ESC%[95m"

title Win11 Security Boot - Installer / Setup

echo %C_TITLE%============================================================%C_RESET%
echo %C_TITLE%   Win11 Security Boot - Installation demarrage / Startup setup   %C_RESET%
echo %C_TITLE%============================================================%C_RESET%
echo %C_INFO%               ___  _  _  _  _   ___  ___                %C_RESET%
echo %C_INFO%              / __|| || || || | / _ \| _ )               %C_RESET%
echo %C_INFO%              \__ \| __ || __ || (_) | _ \               %C_RESET%
echo %C_INFO%              |___/|_||_||_||_| \___/|___/               %C_RESET%
echo.

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo %C_WARN%Elevation administrateur requise / Administrator elevation required...%C_RESET%
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "SCRIPT_DIR=%~dp0"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "TASK_NAME=Win11SecurityBoot"
set "SECURITY_SCRIPT=%SCRIPT_DIR%win11-startup-security.ps1"

if not exist "%SECURITY_SCRIPT%" (
  echo %C_ERR%Script introuvable / Script not found: "%SECURITY_SCRIPT%"%C_RESET%
  exit /b 1
)

choice /C YN /N /M "Lancer l'installation / Start installation now ? [Y/N]: "
if errorlevel 2 (
  echo %C_WARN%Installation annulee / Installation cancelled by user.%C_RESET%
  exit /b 0
)

echo.
echo %C_INFO%[1/2] Installation de la tache de demarrage / Creating startup task...%C_RESET%
set "TASK_CMD=\"%PS_EXE%\" -NoProfile -ExecutionPolicy Bypass -File \"%SECURITY_SCRIPT%\""
schtasks /Create /TN "%TASK_NAME%" /TR "%TASK_CMD%" /SC ONSTART /RU SYSTEM /RL HIGHEST /F >nul
if errorlevel 1 (
  echo %C_ERR%Echec installation tache demarrage / Failed to create startup task.%C_RESET%
  exit /b 1
)
echo %C_OK%Tache "%TASK_NAME%" installee / Task "%TASK_NAME%" installed.%C_RESET%

echo %C_INFO%[2/2] Lancement immediat durcissement / Running hardening now...%C_RESET%
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SECURITY_SCRIPT%"
if errorlevel 1 (
  echo %C_ERR%Echec lancement securisation / Failed to run hardening script.%C_RESET%
  exit /b 1
)

echo.
echo %C_OK%Terminee / Done. Securisation appliquee et tache active / Hardening applied and startup task enabled.%C_RESET%
exit /b 0
