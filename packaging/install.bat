@echo off
rem Kyn installer wrapper for cmd.exe.
rem Prefer running install.ps1 directly; this exists so double-clicking works.
where powershell >nul 2>nul
if errorlevel 1 (
    echo error: Windows PowerShell was not found on PATH.
    echo Install it, or use Git Bash and run: ./install.sh
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
