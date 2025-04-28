@echo off
:: Verifica se siamo già in una console con privilegi admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Richiedo privilegi di amministratore...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb runAs"
    exit /b
)

:: Da qui in poi si usa una shell elevata
cd /d "%~dp0"

echo Verifica setup Java...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\setup_java.ps1"

echo Avvio installazione server Minecraft...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install_server.ps1"

pause
