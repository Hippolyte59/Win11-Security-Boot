@echo off
setlocal

for /f %%e in ('echo prompt $E ^| cmd') do set "ESC=%%e"
set "C_RESET=%ESC%[0m"
set "C_INFO=%ESC%[96m"
set "C_OK=%ESC%[92m"
set "C_WARN=%ESC%[93m"
set "C_ERR=%ESC%[91m"
set "C_TITLE=%ESC%[95m"

title Win11 Security Boot - Uninstall

echo %C_TITLE%============================================================%C_RESET%
echo %C_TITLE%   Win11 Security Boot - Suppression tache / Remove startup task %C_RESET%
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

set "TASK_NAME=Win11SecurityBoot"

choice /C YN /N /M "Supprimer la tache de demarrage / Remove startup task now ? [Y/N]: "
if errorlevel 2 (
  echo %C_WARN%Desinstallation annulee / Uninstall cancelled by user.%C_RESET%
  exit /b 0
)

echo.
echo %C_INFO%Suppression de la tache "%TASK_NAME%" / Removing task "%TASK_NAME%"...%C_RESET%
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
if errorlevel 1 (
  echo %C_WARN%Aucune tache "%TASK_NAME%" trouvee (ou deja supprimee) / No "%TASK_NAME%" task found (or already removed).%C_RESET%
) else (
  echo %C_OK%Tache "%TASK_NAME%" supprimee / Task "%TASK_NAME%" removed.%C_RESET%
)

echo %C_OK%Desinstallation terminee / Uninstall completed.%C_RESET%
exit /b 0
