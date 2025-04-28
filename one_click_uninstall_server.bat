@echo off
:: Check if we're already in an admin-privileged console
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb runAs"
    exit /b
)

:: From here on, use an elevated shell
cd /d "%~dp0"

:: Prompt for confirmation to uninstall
echo Uninstalling the Minecraft server will remove all files and folders associated with the server (backups and scripts excluded).
set /p confirm="Are you sure you want to uninstall the Minecraft server? (Y/N): "

:: Treat empty input as "Y"
if "%confirm%"=="" set confirm=Y

if /i "%confirm%" NEQ "Y" (
    echo Uninstallation canceled.
    exit /b
)

echo Starting Minecraft server uninstallation...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install_server.ps1" -UninstallSwitch

pause