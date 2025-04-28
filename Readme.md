```markdown
# Minecraft Server Setup Scripts

This README explains the role of each parameter in the `server.ini` file and provides an overview of the functions and scripts used to configure the Minecraft server (Vanilla or Forge).

## File `server.ini`
Contains the installation configuration:
- **DESTINATION**  
  - Destination folder for downloading and installing the server (default: `.`).
- **MINECRAFT_VERSION**  
  - Minecraft version to use (e.g. `1.20.1`).
- **VANILLA**  
  - If `true`, installs the Vanilla server; otherwise, installs Forge.
- **FORGE_VERSION**  
  - Forge version to install or `Recommended` for the recommended build.
- **INSTALLER**  
  - Forge package type: `installer` or `universal`.
- **JreVersion**, **JdkVersion**  
  - Versions of JRE and JDK to install (JRE 8, JDK 17).
- **ForceInstall**  
  - If `true`, forces download and installation even if already present.
- **Uninstall**  
  - If `true`, uninstalls Java and cleans the server folder, then exits.

## Script Overview

### `setup_java.ps1`
- Installs (or uninstalls) Oracle JRE 8 and OpenJDK 17.  
- Reads parameters `JreVersion`, `JdkVersion`, `ForceInstall`, and `Uninstall`.  
- Functions:  
  - `Uninstall-Java`: removes JRE/JDK and cleans environment variables.  
  - `Download-IfNeeded`: silently downloads installer/MSI if required.

### `install_server.ps1`
- Imports `setup_java.ps1`.  
- Detects the path to `java.exe` in JDK 17 and sets `$javaCmd`.  
- Reads parameters from `server.ini`.  
- Flows:  
  - **Uninstall**: uninstalls Java and cleans folders.  
  - **Vanilla** (`VANILLA=true`):  
    1. Downloads `minecraft_server.<version>.jar` if missing.  
    2. Configures `eula.txt` (`eula=true`).  
    3. Runs `Install-7ZipCLI` and `Install-Mcrcon`.  
    4. Generates `run.bat` via `Generate-RunBat -VanillaSwitch $true`.  
    5. Starts the server.  
  - **Forge** (`VANILLA=false`):  
    1. Downloads or uses the Forge installer.  
    2. Runs the Forge installer.  
    3. Configures `eula.txt`.  
    4. Runs `Install-7ZipCLI` and `Install-Mcrcon`.  
    5. Generates `run.bat` via `Generate-RunBat -VanillaSwitch $false`.  
    6. Starts the server.

### Auxiliary Functions
- `Generate-RunBat`: creates `run.bat` for Vanilla or Forge, including the correct Java command and backup script.  
- `Install-7ZipCLI`: installs the local 7-Zip CLI.  
- `Install-Mcrcon`: installs `mcrcon.exe` for remote management.

## Backup Script

### `backup_world.ps1`
Script to back up the `world` folder:

```powershell
param(
    [string]$ServerDir = "$PSScriptRoot",
    [string]$WorldDir  = "$PSScriptRoot\world",
    [string]$BackupDir = "$PSScriptRoot\backups"
)

# 1. Change to the script directory
Set-Location $PSScriptRoot

# 2. Create the backup folder if it doesn't exist
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
}

# 3. Generate timestamp (YYYY-MM-DD_HH-mm-ss)
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# 4. Set paths for 7z.exe and the archive file
$SevenZipExe = Join-Path $PSScriptRoot '7z.exe'
$archive     = Join-Path $BackupDir "world_backup_$timestamp.7z"

# 5. Run 7-Zip backup (excluding session.lock, level.dat, level.dat_old)
$exclusions = @('-xr!*.lock','-xr!level.dat','-xr!level.dat_old')
& $SevenZipExe a -t7z -mx=3 -ssw @exclusions $archive "$WorldDir\*"

# 6. Remove older backups, keeping only the latest 6
$limit = 6
$files = Get-ChildItem -Path $BackupDir -Filter 'world_backup_*.7z' | Sort-Object LastWriteTime -Descending
if ($files.Count -gt $limit) {
    $files | Select-Object -Skip $limit | Remove-Item -Force
}
```

- **ServerDir**: root of the server (defaults to script location).  
- **WorldDir**: game world directory.  
- **BackupDir**: folder to save archives.  
- Uses 7-Zip to create a `.7z` archive with medium compression and `-ssw` (include open files).  
- Excludes lock and temporary level files.  
- Automatically rotates backups, keeping the last 6.

**Recommended Use:**
1. Run `backup_world.ps1` before stopping the server to save the world state.  
2. The script handles automatic rotation to prevent accumulation.  
3. You can integrate calls to `backup_world.ps1` into your startup scripts or scheduled tasks.

## Periodic Backup Script

### `backup_period_world.ps1`
Script for automatic backups at regular intervals via RCON:

```powershell
param(
    [int]   $IntervalMinutes = 30,          # Interval between backups in minutes
    [int]   $StartupDelay    = 60,          # Initial delay in seconds for server startup
    [string]$RconHost        = '127.0.0.1',  # Default RCON host
    [int]   $RconPort        = 25575,       # RCON port
    [string]$RconPass        = 'minecraft1' # RCON password
)

# Set the working directory
Set-Location $PSScriptRoot

# Initial delay to ensure the server is running
Write-Host "[Periodic Backup] Waiting $StartupDelay seconds for server startup..."
Start-Sleep -Seconds $StartupDelay

# Poll RCON until ready
Write-Host "[Periodic Backup] Checking if RCON is ready..."
for ($i = 0; $i -lt 12; $i++) {
    $out = & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "list" 2>$null
    if ($out -match 'There are \d+ of a max') {
        Write-Host "[Periodic Backup] RCON ready after $($i * 5) seconds."
        break
    }
    Start-Sleep -Seconds 5
}

# Function to check if Java process is running
function ServerRunning {
    Get-Process java -ErrorAction SilentlyContinue
}

Write-Host "[Periodic Backup] Starting backups every $IntervalMinutes minutes."

while (ServerRunning) {
    # Disable and force-save the world
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-off" | Out-Null
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-all" | Out-Null
    Write-Host "[Periodic Backup] save-off/save-all sent at $(Get-Date -Format 'HH:mm:ss')."

    # Run world backup
    Write-Host "[Periodic Backup] Running backup_world.ps1 at $(Get-Date -Format 'HH:mm:ss')"
    & "$PSScriptRoot\backup_world.ps1"

    # Re-enable saving
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-on" | Out-Null
    Write-Host "[Periodic Backup] save-on sent at $(Get-Date -Format 'HH:mm:ss')."

    # Wait for the interval, checking the server every 10 seconds
    $waitTime = $IntervalMinutes * 60
    Write-Host "[Periodic Backup] Waiting $IntervalMinutes minutes..."
    while ($waitTime -gt 0) {
        Start-Sleep -Seconds 10
        $waitTime -= 10
        if (-not (ServerRunning)) { break }
    }
}

Write-Host "[Periodic Backup] No Java process detected. Exiting at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
```

- **IntervalMinutes**: interval between backups in minutes.  
- **StartupDelay**: initial pause to ensure server readiness.  
- **RconHost**, **RconPort**, **RconPass**: RCON settings for sending commands.  
- Uses `mcrcon.exe` to disable/enable saves for a consistent backup, then runs `backup_world.ps1` until the Java process stops.

## One-Click Startup Script

### `one_click_server_manager_RUNME.bat`
Batch file to:
1. Elevate to administrator privileges if needed.  
2. Execute in sequence:  
   - `setup_java.ps1` to prepare Java.  
   - `install_server.ps1` to install/configure Vanilla or Forge server.  
3. Keep the window open with `pause`.

```batch
@echo off
:: Require admin privileges if absent
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb runAs"
    exit /b
)

cd /d "%~dp0"

echo Verifying Java setup...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\setup_java.ps1"

echo Starting Minecraft server installation...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install_server.ps1"

pause
```

- Ensures all PowerShell scripts run with elevated privileges.  
- Allows one double-click to configure and launch the server.
```