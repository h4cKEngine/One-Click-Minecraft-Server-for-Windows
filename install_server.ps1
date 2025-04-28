<#
install_server.ps1
Installa/configura il server Minecraft con Forge o Vanilla, delegando la gestione di Java a setup_java.ps1 e il download a setup_server.ps1 .
Mentre il backup periodico o finale è delegato a backup_period_world.ps1 .
Parametri da server.ini:
  DESTINATION, MINECRAFT_VERSION, FORGE_VERSION, INSTALLER, VANILLA, Uninstall
#>

param(
    [string]$ConfigFile = "server.ini"
)

# ——— Rilevamento JDK 17 in percorsi di default ———
function Resolve-JavaCmd {
    [CmdletBinding()]
    param()

    # Cerca JDK 17 in percorsi di default
    $javaHomes = @(
        Join-Path $env:ProgramFiles 'Java\jdk-17*'
        Join-Path $env:ProgramFiles 'Microsoft\jdk-17*'
    )
    $foundHome = $null
    foreach ($pattern in $javaHomes) {
        $dirs = Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
        if ($dirs) {
            $foundHome = $dirs[0].FullName
            break
        }
    }

    if ($foundHome) {
        Write-Host "Trovato JDK 17 in: $foundHome" -ForegroundColor Green
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $foundHome, 'User')
        $env:JAVA_HOME = $foundHome
        $javaCmd = Join-Path $foundHome 'bin\java.exe'
    }
    else {
        Write-Warning "JDK 17 non trovato nei percorsi predefiniti."
        try {
            $javaCmd = (Get-Command java -ErrorAction Stop).Source
            Write-Host "Trovato java.exe sul PATH: $javaCmd" -ForegroundColor Cyan
        }
        catch {
            # throw "java.exe non trovato né in JAVA_HOME né sul PATH. Controlla l'installazione di JDK 17."
            Write-Host "java.exe non trovato né in JAVA_HOME né sul PATH." -ForegroundColor Cyan
        }
    }

    # Verifica che il file esista davvero
    #if (-not (Test-Path $javaCmd)) {
    #    throw "Impossibile trovare java.exe in '$javaCmd'. Controlla l'installazione di JDK 17."
    #}

    return $javaCmd
}

# Importa setup_java e definisce Uninstall-Java, Download-IfNeeded, ecc.
. (Join-Path $PSScriptRoot 'setup_java.ps1')


# Carica configurazione da server.ini
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file '$ConfigFile' non trovato."; exit 1
}
$cfg = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
Get-Content $ConfigFile | ForEach-Object {
    if ($_ -match '^(?<k>[^#=]+)=(?<v>.*)$') {
        $cfg[$matches.k.Trim()] = $matches.v.Trim()
    }
}
$installPath   = $cfg['DESTINATION']
$selectedMc    = $cfg['MINECRAFT_VERSION']
$selectedBuild = $cfg['FORGE_VERSION']
$installerType = $cfg['INSTALLER']
$vanillaSwitch = [bool]([string]$cfg['VANILLA'] -match '^(true|1)$')

Write-Host "Caricamento da server.ini completato." -ForegroundColor Green

# --- Assicuro che ci sia un javaCmd valido, altrimenti installo il JDK 17 e riprovo ---
try {
    $javaCmd = Resolve-JavaCmd
}
catch {
    Write-Warning "JDK 17 non trovato: termino l'esecuzione."
    # chiama il setup_java.ps1 per installare solo il JDK (la funzione Download-IfNeeded / MSI)
    # & (Join-Path $PSScriptRoot 'setup_java.ps1')
    # riprovo a risolvere il comando java
}

Write-Host "Userò questo java per avviare il server: $javaCmd" -ForegroundColor Green

# Ottengo flag Uninstall
[bool]$Uninstall = if ($cfg.ContainsKey('Uninstall')) { $cfg['Uninstall'] -match '^(true|1)$' } else { $false }
# Se Uninstall=true, faccio la pulizia cartelle server e poi disinstallo JDK
if ($Uninstall) {
    Write-Host "Flag Uninstall abilitato: pulizia file server e disinstallazione JDK..." -ForegroundColor Cyan

    # Pulizia file/cartelle del server
    $items = Get-ChildItem -Path $installPath -Force | Where-Object {
        ($_.PSIsContainer -and $_.Name -notin 'backups','world') -or
        (-not $_.PSIsContainer -and $_.Name -notin 'server.ini' -and $_.Extension -notin '.ps1','.bat','.md')
    }
    foreach ($item in $items) {
        Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $runBat = Join-Path $installPath 'run.bat'
    if (Test-Path $runBat) { Remove-Item -Path $runBat -Force }

    # Disinstalla JDK
    $javaCmd = Resolve-JavaCmd
    Uninstall-Java

    Write-Host "Pulizia e disinstallazione completate." -ForegroundColor Green
    exit 0
}


# Genera run.bat
function Generate-RunBat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][bool]  $VanillaSwitch,
        [Parameter(Mandatory)][string]$MinecraftVersion,
        [Parameter(Mandatory)][string]$JavaCmd
    )

    $mode = if ($VanillaSwitch) { 'Vanilla' } else { 'Forge' }
    Write-Host "Generazione run.bat in modalità $mode (cmd: $JavaCmd)" -ForegroundColor Cyan

    if ($VanillaSwitch) {
        # Vanilla
        $jar = Get-ChildItem -Path $InstallPath -Filter "minecraft_server.$MinecraftVersion.jar" |
               Select-Object -First 1
        if (-not $jar) { Write-Warning "Jar vanilla non trovato in $InstallPath" }
        $jarName = $jar.Name

        $runContent = @"
@echo off
cd /d "%~dp0"

REM Avvia script di backup periodico in background
if exist "%~dp0backup_period_world.ps1" (
  start "Backup Periodico" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_period_world.ps1"
)

echo Avvio Server Minecraft Vanilla $MinecraftVersion
"$JavaCmd" -jar "%~dp0$jarName" %*

if exist "%~dp0backup_period_world.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_period_world.ps1" -OneShot -WorldDir "%~dp0world" -BackupDir "%~dp0backups" -KeepLatest 6
)

"@
    }
    else {
        # Forge
        $runContent = @"
@echo off
cd /d "%~dp0"

REM Avvia script di backup periodico in background
if exist "%~dp0backup_period_world.ps1" (
  start "Backup Periodico" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_period_world.ps1"
)

REM Calcolo versione Forge
for /f "delims=" %%F in ('dir /b /ad "%~dp0libraries\net\minecraftforge\forge"') do set "FORGE_VER=%%F"

echo Avvio Server Minecraft (Forge %FORGE_VER%)
"$JavaCmd" @user_jvm_args.txt @libraries\net\minecraftforge\forge\%FORGE_VER%\win_args.txt %*

if exist "%~dp0backup_period_world.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_period_world.ps1" -OneShot -WorldDir "%~dp0world" -BackupDir "%~dp0backups" -KeepLatest 6
)

"@
    }

    # Scrive il run.bat
    $runBatPath = Join-Path $InstallPath 'run.bat'
    $runContent | Set-Content -Path $runBatPath -Encoding ASCII

    Write-Host "run.bat generato in $runBatPath" -ForegroundColor Green
}

function Install-7ZipCLI {
    [CmdletBinding()]
    param(
        [string]$Destination = $PSScriptRoot
    )
    Write-Host "Verifico installazione 7-Zip CLI..." -ForegroundColor Cyan
    $sevenExe = Join-Path $Destination '7z.exe'
    $sevenDll = Join-Path $Destination '7z.dll'
    if (-not (Test-Path $sevenExe) -or -not (Test-Path $sevenDll)) {
        Write-Host "Installazione 7-Zip CLI..." -ForegroundColor Cyan
        $exeUrl  = 'https://www.7-zip.org/a/7z2409-x64.exe'
        $exePath = Join-Path $Destination '7z-installer.exe'
        Invoke-WebRequest -Uri $exeUrl -OutFile $exePath -UseBasicParsing
        $temp = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
        New-Item $temp -ItemType Directory | Out-Null
        Start-Process $exePath -ArgumentList "/S","/D=$temp" -Wait
        Copy-Item (Join-Path $temp '7z.exe') -Destination $Destination -Force
        Copy-Item (Join-Path $temp '7z.dll') -Destination $Destination -Force
        Remove-Item $exePath -Force
        Write-Host "7-Zip CLI installato in $Destination" -ForegroundColor Green
    }
    else {
        Write-Host "7-Zip CLI già presente, skip." -ForegroundColor Yellow
    }
}

function Install-Mcrcon {
    [CmdletBinding()]
    param(
        [string]$Destination = $PSScriptRoot,
        [string]$Version     = '0.7.2'
    )
    Write-Host "Verifico installazione mcrcon..." -ForegroundColor Cyan
    $exeDest = Join-Path $Destination 'mcrcon.exe'
    if (-not (Test-Path $exeDest)) {
        Write-Host "Installazione mcrcon v$Version..." -ForegroundColor Cyan
        $zipUrl  = "https://github.com/Tiiffi/mcrcon/releases/download/v$Version/mcrcon-$Version-windows-x86-64.zip"
        $zipFile = Join-Path $Destination 'mcrcon.zip'
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing
        Expand-Archive -Path $zipFile -DestinationPath $Destination -Force
        Remove-Item $zipFile -Force

        # Copia il primo mcrcon.exe trovato, ma solo se diverso dalla destinazione
        $found = Get-ChildItem $Destination -Filter 'mcrcon.exe' -Recurse | Select-Object -First 1
        if ($found) {
            if ($found.FullName -ne $exeDest) {
                Copy-Item $found.FullName -Destination $exeDest -Force
                Write-Host "mcrcon.exe posizionato in $exeDest" -ForegroundColor Green
            } else {
                Write-Host "mcrcon.exe già presente nella destinazione, skip copy." -ForegroundColor Yellow
            }
        } else {
            Write-Warning "mcrcon.exe non trovato nell'archivio estratto."
        }

        # Rimuove eventuale LICENSE rimanente
        $lic = Join-Path $Destination 'LICENSE'
        if (Test-Path $lic) { Remove-Item $lic -Force }
    }
    else {
        Write-Host "mcrcon.exe già presente, skip." -ForegroundColor Yellow
    }
}

# Gestione modalità Vanilla
if ($vanillaSwitch) {
    Write-Host "Modalità Vanilla abilitata: installazione server Vanilla Minecraft $selectedMc" -ForegroundColor Cyan
    $jarPath    = Join-Path $installPath "minecraft_server.$selectedMc.jar"
    $setupScript = Join-Path $PSScriptRoot 'setup_server.ps1'

    # Configura EULA
    Write-Host "Configuro EULA..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    Set-Content -Path (Join-Path $installPath 'eula.txt') -Value 'eula=true' -Encoding ASCII
    Write-Host "EULA impostato a true." -ForegroundColor Green

    Install-7ZipCLI -Destination $PSScriptRoot
    Install-Mcrcon  -Destination $PSScriptRoot

    if (Test-Path $jarPath) {
        Write-Host "Server JAR già presente: $jarPath, salto download." -ForegroundColor Yellow
    }
    elseif (Test-Path $setupScript) {
        & "$setupScript" -ConfigFile $ConfigFile
    }
    else {
        Write-Error "setup_server.ps1 non trovato."; exit 1
    }

    Write-Host "Server vanilla pronto in $installPath" -ForegroundColor Green

    # Genera e avvia Vanilla run.bat
	Generate-RunBat `
	  -InstallPath       $installPath `
	  -VanillaSwitch     $true `
	  -MinecraftVersion  $selectedMc `
	  -JavaCmd           $javaCmd
    $bat = Join-Path $installPath 'run.bat'
    Start-Process -FilePath 'cmd.exe' `
                  -ArgumentList "/c `"$bat`"" `
                  -WorkingDirectory $installPath

    
    exit 0
}

# Verifica/installazione del jar installer
Write-Host "Verifico presenza dell'installer JAR in $PSScriptRoot..." -ForegroundColor Cyan
$jar = Get-ChildItem -Path $PSScriptRoot -Filter '*-installer.jar' | Select-Object -First 1
if (-not $jar) {
    Write-Host "Installer JAR non trovato: avvio download con setup_server.ps1..." -ForegroundColor Yellow
    $setupScript = Join-Path $PSScriptRoot 'setup_server.ps1'
    if (Test-Path $setupScript) {
        & "$setupScript"
        $jar = Get-ChildItem -Path $PSScriptRoot -Filter '*-installer.jar' | Select-Object -First 1
        if (-not $jar) { Write-Error "Installer JAR non trovato dopo setup."; exit 1 }
    } else {
        Write-Error "setup_server.ps1 non trovato."; exit 1
    }
}
$installerJar = $jar.FullName

# Crea cartella server
if (-not (Test-Path $installPath)) {
    Write-Host "Creo cartella server: $installPath" -ForegroundColor Cyan
    New-Item -Path $installPath -ItemType Directory | Out-Null
}

# Risolvi build "Recommended" tramite promotions_slim.json
if ($selectedBuild -eq 'Recommended') {
    $promUrl  = 'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json'
    $prom     = Invoke-RestMethod -Uri $promUrl -UseBasicParsing
    $promoKey = "${selectedMc}-recommended"
    if ($prom.promos.PSObject.Properties.Name -contains $promoKey) {
        $selectedBuild = $prom.promos.$promoKey
        Write-Host "Build raccomandata per MC ${selectedMc}: $selectedBuild" -ForegroundColor Green
    } else {
        Write-Warning "Nessuna build consigliata trovata per Minecraft ${selectedMc}" -ForegroundColor Yellow
    }
}

# Definisce baseUrl per Forge
$baseUrl = 'https://maven.minecraftforge.net/net/minecraftforge/forge'

# Prepara URL e percorso JAR
$downloadUrl   = "$baseUrl/$selectedBuild/forge-$selectedMc-$selectedBuild-$installerType.jar"
$forgeJar      = Join-Path $PSScriptRoot "forge-$selectedMc-$selectedBuild-$installerType.jar"

# Installazione Forge (con controllo esistenza JAR)
if (-not (Test-Path $forgeJar)) {
    Write-Host "Scarico Forge $selectedBuild ($installerType) da: $downloadUrl" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $downloadUrl -OutFile $forgeJar -UseBasicParsing -ErrorAction Stop
    Write-Host "Download completato: $forgeJar" -ForegroundColor Green
} else {
    Write-Host "Forge installer già presente: $forgeJar" -ForegroundColor Yellow
}

# Esecuzione installer Forge
Write-Host "Eseguo installer Forge con: $javaCmd -jar $forgeJar --installServer $installPath" -ForegroundColor Cyan
& $javaCmd -jar $forgeJar --installServer $installPath
if ($LASTEXITCODE -ne 0) {
    Write-Error "Errore installer Forge (exit code $LASTEXITCODE)"
    exit $LASTEXITCODE
}
Write-Host "Forge installato in $installPath" -ForegroundColor Green

# Configura EULA
Write-Host "Configuro EULA..." -ForegroundColor Cyan
Start-Sleep -Seconds 2
Set-Content -Path (Join-Path $installPath 'eula.txt') -Value 'eula=true' -Encoding ASCII
Write-Host "EULA impostato a true." -ForegroundColor Green

# Richiama setup_server.ps1 finale
$setupScript = Join-Path $PSScriptRoot 'setup_server.ps1'
if (Test-Path $setupScript) { & $setupScript } else { Write-Warning "setup_server.ps1 non trovato." }

# 7-Zip CLI install
Install-7ZipCLI -Destination $PSScriptRoot

# mcrcon install
Install-Mcrcon  -Destination $PSScriptRoot

# Genera e Avvia forge run.bat
Generate-RunBat `
  -InstallPath       $installPath `
  -VanillaSwitch     $false `
  -MinecraftVersion  $selectedMc `
  -JavaCmd           $javaCmd
$bat = Join-Path $installPath 'run.bat'
Start-Process -FilePath 'cmd.exe' `
              -ArgumentList "/c `"$bat`"" `
              -WorkingDirectory $installPath


# --- Pulizia file installer locali ---
Write-Host "Rimozione dei file installer" -ForegroundColor Cyan
$patterns = @(
    "$PSScriptRoot\7z-installer.exe",
    "$PSScriptRoot\jre8.exe",
    "$PSScriptRoot\jdk*.msi",
    "$PSScriptRoot\*-installer.jar"
)
foreach ($pattern in $patterns) {
    Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Rimuovo $($_.FullName)" -ForegroundColor Yellow
        Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Pulizia completata." -ForegroundColor Green
