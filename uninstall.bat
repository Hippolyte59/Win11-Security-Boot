@echo off
setlocal

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo Elevation administrateur requise...
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "TASK_NAME=Win11SecurityBoot"

echo Suppression de la tache "%TASK_NAME%"...
schtasks /Query /TN "%TASK_NAME%" >nul 2>&1
if "%errorlevel%"=="0" (
  schtasks /Delete /TN "%TASK_NAME%" /F >nul
  if errorlevel 1 (
    echo Echec de suppression de la tache "%TASK_NAME%".
    exit /b 1
  )
  echo Tache "%TASK_NAME%" supprimee.
) else (
  echo Aucune tache "%TASK_NAME%" trouvee.
)

echo Desinstallation terminee.
exit /b 0
