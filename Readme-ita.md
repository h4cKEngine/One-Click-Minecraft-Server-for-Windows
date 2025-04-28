# Minecraft Server Setup Scripts

Questo README spiega la funzione di ciascun parametro nel file `server.ini` e offre una panoramica delle funzioni e script utilizzati per configurare il server Minecraft (Vanilla o Forge).

## File `server.ini`
Contiene la configurazione dell’installazione:
- **DESTINATION**
  - Cartella di destinazione per il download e l’installazione del server (default: `.`).
- **MINECRAFT_VERSION**
  - Versione di Minecraft da utilizzare (es. `1.20.1`).
- **VANILLA**
  - Se `true`, installa il server Vanilla; altrimenti installerà Forge.
- **FORGE_VERSION**
  - Versione di Forge da installare o `Recommended` per la build consigliata.
- **INSTALLER**
  - Tipo di pacchetto Forge: `installer` o `universal`.
- **JreVersion**, **JdkVersion**
  - Versioni di JRE e JDK da installare (JRE 8, JDK 17).
- **ForceInstall**
  - Se `true`, forza il download e l’installazione anche se già presenti.
- **Uninstall**
  - Se `true`, disinstalla Java e pulisce la cartella server, poi esce.

## Panoramica degli script

### `setup_java.ps1`
- Installa (o disinstalla) Oracle JRE 8 e OpenJDK 17.
- Legge parametri `JreVersion`, `JdkVersion`, `ForceInstall`, `Uninstall`.
- Funzioni:
  - `Uninstall-Java`: rimuove JRE/JDK e pulisce variabili di ambiente.
  - `Download-IfNeeded`: scarica silent installer/MSI.

### `install_server.ps1`
- Importa `setup_java.ps1`.
- Rileva percorso di `java.exe` del JDK 17 e imposta `$javaCmd`.
- Legge parametri da `server.ini`.
- Flussi:
  - **Uninstall**: disinstalla Java e pulisce cartelle.
  - **Vanilla** (`VANILLA=true`):
    1. Scarica `minecraft_server.<version>.jar` se assente.
    2. Configura `eula.txt` (`eula=true`).
    3. Esegue `Install-7ZipCLI` e `Install-Mcrcon`.
    4. Genera `run.bat` con `Generate-RunBat -VanillaSwitch $true`.
    5. Avvia il server.
  - **Forge** (`VANILLA=false`):
    1. Scarica o utilizza installer Forge.
    2. Esegue installer Forge.
    3. Configura `eula.txt`.
    4. Esegue `Install-7ZipCLI` e `Install-Mcrcon`.
    5. Genera `run.bat` con `Generate-RunBat -VanillaSwitch $false`.
    6. Avvia il server.

### Funzioni ausiliarie
- `Generate-RunBat`: genera `run.bat` per Vanilla/Forge includendo il comando Java corretto e script di backup.
- `Install-7ZipCLI`: installa localmente 7-Zip CLI.
- `Install-Mcrcon`: installa `mcrcon.exe` per la gestione remota.

## Script di backup

### `backup_world.ps1`
Script per eseguire il backup della cartella `world`:

```powershell
param(
    [string]$ServerDir = "$PSScriptRoot",
    [string]$WorldDir  = "$PSScriptRoot\world",
    [string]$BackupDir = "$PSScriptRoot\backups"
)

# 1. Posizionamento nella cartella dello script
Set-Location $PSScriptRoot

# 2. Creazione della cartella di backup se mancante
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
}

# 3. Generazione del timestamp (YYYY-MM-DD_HH-mm-ss)
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# 4. Percorso 7z.exe e file di archivio
$SevenZipExe = Join-Path $PSScriptRoot '7z.exe'
$archive     = Join-Path $BackupDir "world_backup_$timestamp.7z"

# 5. Esecuzione backup con 7-Zip (esclude session.lock, level.dat, level.dat_old)
$exclusions = @('-xr!*.lock','-xr!level.dat','-xr!level.dat_old')
& $SevenZipExe a -t7z -mx=3 -ssw @exclusions $archive "$WorldDir\*"

# 6. Rimozione di backup più vecchi mantenendo gli ultimi 6
$limit = 6
$files = Get-ChildItem -Path $BackupDir -Filter 'world_backup_*.7z' | Sort-Object LastWriteTime -Descending
if ($files.Count -gt $limit) {
    $files | Select-Object -Skip $limit | Remove-Item -Force
}
```

- **ServerDir**: radice del server (default script).
- **WorldDir**: directory del mondo di gioco.
- **BackupDir**: cartella dove salvare gli archivi.
- Usa 7-Zip per creare un archivio `.7z` con compressione media e opzione `-ssw` (includi file aperti).
- Esclude file di lock e dati di livello temporanei.
- Pulisce automaticamente i backup più vecchi mantenendo solo gli ultimi 6.

---

**Utilizzo consigliato:**
1. Prima di arrestare il server, eseguire `backup_world.ps1` per salvare lo stato del mondo.
2. Lo script gestisce rotazione automatica, evitando accumulo eccessivo.
3. Puoi integrare chiamate a `backup_world.ps1` nei tuoi script di avvio o task schedulati.


## Script di backup periodico

### `backup_period_world.ps1`
Script per eseguire backup automatici a intervalli regolari tramite RCON:

```powershell
param(
    [int]   $IntervalMinutes = 30,          # Intervallo tra backup in minuti
    [int]   $StartupDelay    = 60,         # Delay iniziale in secondi per avviare il server
    [string]$RconHost        = '127.0.0.1', # Host RCON (default locale)
    [int]   $RconPort        = 25575,      # Porta RCON
    [string]$RconPass        = 'minecraft1' # Password RCON
)

# Imposto la directory di lavoro
Set-Location $PSScriptRoot

# Delay iniziale per assicurarsi che il server sia in esecuzione
Write-Host "[Backup Periodico] Attendo $StartupDelay secondi per l'avvio del server..."
Start-Sleep -Seconds $StartupDelay

# Polling RCON per verificare disponibilità
Write-Host "[Backup Periodico] Controllo che RCON sia operativo..."
for ($i = 0; $i -lt 12; $i++) {
    $out = & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "list" 2>$null
    if ($out -match 'There are \d+ of a max') {
        Write-Host "[Backup Periodico] RCON pronto dopo $($i * 5) secondi."
        break
    }
    Start-Sleep -Seconds 5
}

# Funzione per verificare processo Java
function ServerRunning {
    Get-Process java -ErrorAction SilentlyContinue
}

Write-Host "[Backup Periodico] Avvio backup ogni $IntervalMinutes minuti."

while (ServerRunning) {
    # Disabilito e forzo salvataggio del mondo
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-off" | Out-Null
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-all" | Out-Null
    Write-Host "[Backup Periodico] save-off/save-all inviati a $(Get-Date -Format 'HH:mm:ss')."

    # Eseguo backup del mondo
    Write-Host "[Backup Periodico] Eseguo backup_world.ps1 a $(Get-Date -Format 'HH:mm:ss')"
    & "$PSScriptRoot\backup_world.ps1"

    # Riabilito i salvataggi
    & "$PSScriptRoot\mcrcon.exe" -H $RconHost -P $RconPort -p $RconPass -c "save-on" | Out-Null
    Write-Host "[Backup Periodico] save-on inviato a $(Get-Date -Format 'HH:mm:ss')."

    # Attendo intervallo, controllando il server ogni 10 secondi
    $waitTime = $IntervalMinutes * 60
    Write-Host "[Backup Periodico] In attesa di $IntervalMinutes minuti..."
    while ($waitTime -gt 0) {
        Start-Sleep -Seconds 10
        $waitTime -= 10
        if (-not (ServerRunning)) { break }
    }
}

Write-Host "[Backup Periodico] Nessun processo Java rilevato. Terminato a $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
```

- **IntervalMinutes**: intervallo tra backup, in minuti.
- **StartupDelay**: pausa iniziale per assicurare che il server sia pronto.
- **RconHost**, **RconPort**, **RconPass**: configurazione RCON per inviare comandi al server.
- Utilizza `mcrcon.exe` per disabilitare/abilitare salvataggi e garantire backup coerenti.
- Esegue `backup_world.ps1` ad ogni intervallo fino a che il processo Java è attivo.

## Script di avvio in un click

### `one_click_server_manager_RUNME.bat`
Batch file per:
1. Elevare a privilegi di amministratore se necessario.
2. Eseguire in sequenza:
   - `setup_java.ps1` per preparazione Java.
   - `install_server.ps1` per installazione/configurazione server Vanilla o Forge.
3. Mantenere la finestra aperta con `pause`.

```batch
@echo off
:: Richiede privilegi admin se assenti
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Richiedo privilegi di amministratore...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb runAs"
    exit /b
)

cd /d "%~dp0"

echo Verifica setup Java...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\setup_java.ps1"

echo Avvio installazione server Minecraft...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install_server.ps1"

pause
```

- Garantisce che tutti gli script PowerShell vengano eseguiti con privilegi elevati.
- Consente un unico doppio click per configurare e avviare il server.

