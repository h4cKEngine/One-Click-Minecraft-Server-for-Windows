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

echo Verifying Java setup...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\setup_java.ps1"

echo Starting Minecraft server installation...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install_server.ps1"

pause
