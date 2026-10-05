@echo off
chcp 65001 >nul
setlocal
title Reinstall Kit - Software Bootstrap

rem Prefer PowerShell 7 if available, otherwise Windows PowerShell 5.1
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
where pwsh.exe >nul 2>nul && set "PSEXE=pwsh.exe"

echo ============================================
echo   Reinstall Kit - installing your software
echo   (a UAC prompt may appear, please confirm)
echo ============================================
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
  echo [DONE] All requested software was installed.
) else (
  echo [ATTENTION] Some items failed - see install-result.csv and install-log.txt
)
echo.
pause
exit /b %RC%
