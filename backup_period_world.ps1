param(
    [switch]$OneShot,
    [int]   $IntervalMinutes = 25,
    [int]   $StartupDelay    = 70,
    [string]$RconHost        = '127.0.0.1',
    [int]   $RconPort        = 25575,
    [string]$RconPass        = 'minecraft1'
)

# Set working directory
Set-Location $PSScriptRoot

function Perform-WorldBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorldDir,
        [Parameter(Mandatory)][string]$BackupDir,
        [int] $KeepLatest = 6
    )

    # 1. Create the backup folder if it doesn't exist
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir | Out-Null
    }

    # 2. Generate the timestamp
    $timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $archive     = Join-Path $BackupDir "world_backup_$timestamp.7z"
    $SevenZipExe = Join-Path $PSScriptRoot '7z.exe'

    # 3. Define exclusions
    $exclusions = @(
        '-xr!*.lock',
        '-xr!level.dat',
        '-xr!level.dat_old'
    )

    Write-Host "Starting backup of '$WorldDir' → '$archive' ..." -ForegroundColor Cyan
    & $SevenZipExe a -t7z -mx=3 -ssw @exclusions $archive "$WorldDir\*"
    Write-Host "Backup completed: $archive" -ForegroundColor Green

    # 4. Remove older backups, keeping only the latest $KeepLatest
    $files = Get-ChildItem -Path $BackupDir -Filter 'world_backup_*.7z' |
             Sort-Object LastWriteTime -Descending
    if ($files.Count -gt $KeepLatest) {
        $files | Select-Object -Skip $KeepLatest | ForEach-Object {
            Remove-Item $_.FullName -Force
            Write-Host "Removed old backup: $($_.Name)" -ForegroundColor Yellow
        }
    }

    $count = (Get-ChildItem -Path $BackupDir -Filter 'world_backup_*.7z').Count
    Write-Host "Total backups present: $count" -ForegroundColor Cyan
}

# If launched with -OneShot, perform a single backup and exit
if ($OneShot) {
    Perform-WorldBackup -WorldDir "$PSScriptRoot\world" -BackupDir "$PSScriptRoot\backups" -KeepLatest 6
    exit 0
}

# Initial delay to allow the server to start
Write-Host "[Periodic Backup] Waiting $StartupDelay seconds for server startup..."
Start-Sleep -Seconds $StartupDelay

# Poll RCON until it's responsive
Write-Host "[Periodic Backup] Checking if RCON is operational..."
for ($i = 0; $i -lt 12; $i++) {
    $out = & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "list" 2>$null
    if ($out -match 'There are \d+ of a max') {
        Write-Host "[Periodic Backup] RCON ready after $($i * 5) seconds."
        break
    }
    Start-Sleep -Seconds 5
}

# Function to detect if any Java process (i.e., the server) is running
function ServerRunning {
    Get-Process java -ErrorAction SilentlyContinue
}

Write-Host "[Periodic Backup] Starting backups every $IntervalMinutes minutes."

# Main loop: repeat as long as the server is running
while (ServerRunning) {
    # 1) Disable world saves and force a save
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-off" | Out-Null
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-all" | Out-Null
    Write-Host "[Periodic Backup] save-off/save-all sent at $(Get-Date -Format 'HH:mm:ss')."

    # 2) Perform main backup using the Perform-WorldBackup function
    $worldDir  = Join-Path $PSScriptRoot 'world'
    $backupDir = Join-Path $PSScriptRoot 'backups'
    Write-Host "[Periodic Backup] Running Perform-WorldBackup at $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
    Perform-WorldBackup -WorldDir  $worldDir `
                        -BackupDir  $backupDir `
                        -KeepLatest 6

    # 3) Re-enable world saves
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-on" | Out-Null
    Write-Host "[Periodic Backup] save-on sent at $(Get-Date -Format 'HH:mm:ss')."

    # 4) Wait for the next interval, checking server status periodically
    $waitTime = $IntervalMinutes * 60
    Write-Host "[Periodic Backup] Waiting $IntervalMinutes minutes (checking server every few seconds)..."
    while ($waitTime -gt 0 -and (ServerRunning)) {
        Start-Sleep -Seconds 3
        $waitTime -= 1
    }

    # If the server has stopped, break the loop immediately
    if (-not (ServerRunning)) {
        Write-Host "[Periodic Backup] Server stopped: exiting loop immediately." -ForegroundColor Yellow
    }
}

Write-Host "[Periodic Backup] No Java process detected. Script ended at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
Start-Sleep -Seconds 3
exit 0
