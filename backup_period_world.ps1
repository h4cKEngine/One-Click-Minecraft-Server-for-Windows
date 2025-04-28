param(
    [switch]$OneShot,
    [int]   $IntervalMinutes = 25,
    [int]   $StartupDelay    = 70,
    [string]$RconHost        = '127.0.0.1',
    [int]   $RconPort        = 25575,
    [string]$RconPass        = 'minecraft1'
)

# Imposto la directory di lavoro
Set-Location $PSScriptRoot

function Perform-WorldBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorldDir,
        [Parameter(Mandatory)][string]$BackupDir,
        [int] $KeepLatest = 6
    )

    # 1. Creo la cartella di backup se non esiste
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir | Out-Null
    }

    # 2. Genero il timestamp
    $timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $archive    = Join-Path $BackupDir "world_backup_$timestamp.7z"
    $SevenZipExe= Join-Path $PSScriptRoot '7z.exe'

    # 3. Definisco esclusioni
    $exclusions = @(
        '-xr!*.lock',
        '-xr!level.dat',
        '-xr!level.dat_old'
    )

    Write-Host "Avvio backup di '$WorldDir' → '$archive' ..." -ForegroundColor Cyan
    & $SevenZipExe a -t7z -mx=3 -ssw @exclusions $archive "$WorldDir\*"
    Write-Host "Backup completato: $archive" -ForegroundColor Green

    # 4. Rimuovo i backup più vecchi mantenendo solo gli ultimi $KeepLatest
    $files = Get-ChildItem -Path $BackupDir -Filter 'world_backup_*.7z' |
             Sort-Object LastWriteTime -Descending
    if ($files.Count -gt $KeepLatest) {
        $files | Select-Object -Skip $KeepLatest | ForEach-Object {
            Remove-Item $_.FullName -Force
            Write-Host "Rimosso backup vecchio: $($_.Name)" -ForegroundColor Yellow
        }
    }

    $count = (Get-ChildItem -Path $BackupDir -Filter 'world_backup_*.7z').Count
    Write-Host "Backup totali presenti: $count" -ForegroundColor Cyan
}

# Se lancio con -OneShot, eseguo una sola volta il backup e esco
if ($OneShot) {
    Perform-WorldBackup -WorldDir "$PSScriptRoot\world" -BackupDir "$PSScriptRoot\backups" -KeepLatest 6
    exit 0
}

# Delay iniziale per avviare il server
Write-Host "[Backup Periodico] Attendo $StartupDelay secondi per l'avvio del server..."
Start-Sleep -Seconds $StartupDelay

# Polling RCON fino a risposta
Write-Host "[Backup Periodico] Controllo che RCON sia operativo..."
for ($i = 0; $i -lt 12; $i++) {
    $out = & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "list" 2>$null
    if ($out -match 'There are \d+ of a max') {
        Write-Host "[Backup Periodico] RCON pronto dopo $($i * 5) secondi."
        break
    }
    Start-Sleep -Seconds 5
}

# Funzione di rilevamento del server (qualsiasi java)
function ServerRunning {
    Get-Process java -ErrorAction SilentlyContinue
}

Write-Host "[Backup Periodico] Avvio backup ogni $IntervalMinutes minuti."

# Loop principale: ripeti finchè il server è attivo
while (ServerRunning) {
    # 1) Disabilito e forzo salvataggio
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-off" | Out-Null
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-all" | Out-Null
    Write-Host "[Backup Periodico] save-off/save-all inviati alle $(Get-Date -Format 'HH:mm:ss')."

    # 2) Eseguo il backup principale con la funzione Perform-WorldBackup
    $worldDir  = Join-Path $PSScriptRoot 'world'
    $backupDir = Join-Path $PSScriptRoot 'backups'
    Write-Host "[Backup Periodico] Eseguo Perform-WorldBackup alle $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
    Perform-WorldBackup -WorldDir  $worldDir `
                        -BackupDir  $backupDir `
                        -KeepLatest 6

    # 3) Riabilito i salvataggi
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-on" | Out-Null
    Write-Host "[Backup Periodico] save-on inviato alle $(Get-Date -Format 'HH:mm:ss')."

    # 4) Attendo intervallo controllando server ogni 1 secondo per exit rapido
    $waitTime = $IntervalMinutes * 60
    Write-Host "[Backup Periodico] In attesa di $IntervalMinutes minuti (controllo server ogni 1s)..."

    while ($waitTime -gt 0 -and (ServerRunning)) {
        Start-Sleep -Seconds 3
        $waitTime -= 1
    }

    # Se siamo usciti perché il server non gira più:
    if (-not (ServerRunning)) {
        Write-Host "[Backup Periodico] Server fermato: esco immediatamente dal loop." -ForegroundColor Yellow
    }
}

Write-Host "[Backup Periodico] Nessun processo Java rilevato. Script terminato alle $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
Start-Sleep -Seconds 3
exit 0
