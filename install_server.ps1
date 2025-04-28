<#
install_server.ps1
Installs/configures the Minecraft server with Forge or Vanilla, delegating Java management to setup_java.ps1 and download to setup_server.ps1.
Periodic or one-shot backups are delegated to backup_period_world.ps1.
Parameters from server.ini:
  DESTINATION, MINECRAFT_VERSION, FORGE_VERSION, INSTALLER, VANILLA, Uninstall
#>

param(
    [string]$ConfigFile = "server.ini"
)

# —— Detecting JDK 17 in default install paths ——
function Resolve-JavaCmd {
    [CmdletBinding()]
    param()

    # Search for JDK 17 in default install paths
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
        Write-Host "Found JDK 17 at: $foundHome" -ForegroundColor Green
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $foundHome, 'User')
        $env:JAVA_HOME = $foundHome
        $javaCmd = Join-Path $foundHome 'bin\java.exe'
    }
    else {
        Write-Warning "JDK 17 not found in default paths."
        try {
            $javaCmd = (Get-Command java -ErrorAction Stop).Source
            Write-Host "Found java.exe on PATH: $javaCmd" -ForegroundColor Cyan
        }
        catch {
            # throw "java.exe not found in JAVA_HOME or on PATH. Check JDK 17 installation."
            Write-Host "java.exe not found in JAVA_HOME or on PATH." -ForegroundColor Cyan
        }
    }

    return $javaCmd
}

# Import setup_java, which defines Uninstall-Java, Download-IfNeeded, etc.
. (Join-Path $PSScriptRoot 'setup_java.ps1')


# Load configuration from server.ini
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file '$ConfigFile' not found."; exit 1
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

Write-Host "Configuration loaded from server.ini." -ForegroundColor Green

# --- Ensure a valid javaCmd exists; if not, install JDK 17 and retry ---
try {
    $javaCmd = Resolve-JavaCmd
}
catch {
    Write-Warning "JDK 17 not found: terminating execution."
}

Write-Host "Using this java to start the server: $javaCmd" -ForegroundColor Green

# Obtain Uninstall flag
[bool]$Uninstall = if ($cfg.ContainsKey('Uninstall')) { $cfg['Uninstall'] -match '^(true|1)$' } else { $false }
# If Uninstall=true, clean server folders and then uninstall JDK
if ($Uninstall) {
    Write-Host "Uninstall flag enabled: cleaning server files and uninstalling JDK..." -ForegroundColor Cyan

    # Clean server files/folders
    $items = Get-ChildItem -Path $installPath -Force | Where-Object {
        ($_.PSIsContainer -and $_.Name -notin 'backups','world') -or
        (-not $_.PSIsContainer -and $_.Name -notin 'server.ini' -and $_.Extension -notin '.ps1','.bat','.md')
    }
    foreach ($item in $items) {
        Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $runBat = Join-Path $installPath 'run.bat'
    if (Test-Path $runBat) { Remove-Item -Path $runBat -Force }

    # Uninstall JDK
    $javaCmd = Resolve-JavaCmd
    Uninstall-Java

    Write-Host "Cleanup and uninstallation complete." -ForegroundColor Green
    exit 0
}

# Generate run.bat
function Generate-RunBat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][bool]  $VanillaSwitch,
        [Parameter(Mandatory)][string]$MinecraftVersion,
        [Parameter(Mandatory)][string]$JavaCmd
    )

    $mode = if ($VanillaSwitch) { 'Vanilla' } else { 'Forge' }
    Write-Host "Generating run.bat in $mode mode (cmd: $JavaCmd)" -ForegroundColor Cyan

    if ($VanillaSwitch) {
        # Vanilla
        $jar = Get-ChildItem -Path $InstallPath -Filter "minecraft_server.$MinecraftVersion.jar" |
               Select-Object -First 1
        if (-not $jar) { Write-Warning "Vanilla jar not found in $InstallPath" }
        $jarName = $jar.Name

        $runContent = @"
@echo off
cd /d "%~dp0"

REM Launch periodic backup script in background
if exist "%~dp0backup_period_world.ps1" (
  start "Periodic Backup" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_period_world.ps1"
)

echo Starting Minecraft Vanilla server $MinecraftVersion
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

REM Launch periodic backup script in background
if exist "%~dp0backup_period_world.ps1" (
  start "Periodic Backup" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_period_world.ps1"
)

REM Calculate Forge version
for /f "delims=" %%F in ('dir /b /ad "%~dp0libraries\net\minecraftforge\forge"') do set "FORGE_VER=%%F"

echo Starting Minecraft server (Forge %FORGE_VER%)
"$JavaCmd" @user_jvm_args.txt @libraries\net\minecraftforge\forge\%FORGE_VER%\win_args.txt %*

if exist "%~dp0backup_period_world.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_period_world.ps1" -OneShot -WorldDir "%~dp0world" -BackupDir "%~dp0backups" -KeepLatest 6
)

"@
    }

    # Write run.bat
    $runBatPath = Join-Path $InstallPath 'run.bat'
    $runContent | Set-Content -Path $runBatPath -Encoding ASCII

    Write-Host "run.bat generated at $runBatPath" -ForegroundColor Green
}

function Install-7ZipCLI {
    [CmdletBinding()]
    param(
        [string]$Destination = $PSScriptRoot
    )
    Write-Host "Checking 7-Zip CLI installation..." -ForegroundColor Cyan
    $sevenExe = Join-Path $Destination '7z.exe'
    $sevenDll = Join-Path $Destination '7z.dll'
    if (-not (Test-Path $sevenExe) -or -not (Test-Path $sevenDll)) {
        Write-Host "Installing 7-Zip CLI..." -ForegroundColor Cyan
        $exeUrl  = 'https://www.7-zip.org/a/7z2409-x64.exe'
        $exePath = Join-Path $Destination '7z-installer.exe'
        Invoke-WebRequest -Uri $exeUrl -OutFile $exePath -UseBasicParsing
        $temp = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
        New-Item $temp -ItemType Directory | Out-Null
        Start-Process $exePath -ArgumentList "/S","/D=$temp" -Wait
        Copy-Item (Join-Path $temp '7z.exe') -Destination $Destination -Force
        Copy-Item (Join-Path $temp '7z.dll') -Destination $Destination -Force
        Remove-Item $exePath -Force
        Write-Host "7-Zip CLI installed in $Destination" -ForegroundColor Green
    }
    else {
        Write-Host "7-Zip CLI already present, skipping." -ForegroundColor Yellow
    }
}
function Install-Mcrcon {
    [CmdletBinding()]
    param(
        [string]$Destination = $PSScriptRoot,
        [string]$Version     = '0.7.2'
    )
    Write-Host "Checking mcrcon installation..." -ForegroundColor Cyan
    $exeDest = Join-Path $Destination 'mcrcon.exe'
    if (-not (Test-Path $exeDest)) {
        Write-Host "Installing mcrcon v$Version..." -ForegroundColor Cyan
        $zipUrl  = "https://github.com/Tiiffi/mcrcon/releases/download/v$Version/mcrcon-$Version-windows-x86-64.zip"
        $zipFile = Join-Path $Destination 'mcrcon.zip'
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing
        Expand-Archive -Path $zipFile -DestinationPath $Destination -Force
        Remove-Item $zipFile -Force

        # Copy the first mcrcon.exe found, but only if it's not already at the destination
        $found = Get-ChildItem $Destination -Filter 'mcrcon.exe' -Recurse | Select-Object -First 1
        if ($found) {
            if ($found.FullName -ne $exeDest) {
                Copy-Item $found.FullName -Destination $exeDest -Force
                Write-Host "mcrcon.exe placed at $exeDest" -ForegroundColor Green
            } else {
                Write-Host "mcrcon.exe already present at destination, skipping copy." -ForegroundColor Yellow
            }
        } else {
            Write-Warning "mcrcon.exe not found in the extracted archive."
        }

        # Remove any leftover LICENSE file
        $lic = Join-Path $Destination 'LICENSE'
        if (Test-Path $lic) { Remove-Item $lic -Force }
    }
    else {
        Write-Host "mcrcon.exe already present, skipping." -ForegroundColor Yellow
    }
}
# Handle Vanilla mode
if ($vanillaSwitch) {
    Write-Host "Vanilla mode enabled: installing Minecraft Vanilla server $selectedMc" -ForegroundColor Cyan
    $jarPath    = Join-Path $installPath "minecraft_server.$selectedMc.jar"
    $setupScript = Join-Path $PSScriptRoot 'setup_server.ps1'

    # Configure EULA
    Write-Host "Configuring EULA..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    Set-Content -Path (Join-Path $installPath 'eula.txt') -Value 'eula=true' -Encoding ASCII
    Write-Host "EULA set to true." -ForegroundColor Green

    Install-7ZipCLI -Destination $PSScriptRoot
    Install-Mcrcon  -Destination $PSScriptRoot

    if (Test-Path $jarPath) {
        Write-Host "Server JAR already present: $jarPath, skipping download." -ForegroundColor Yellow
    }
    elseif (Test-Path $setupScript) {
        & "$setupScript" -ConfigFile $ConfigFile
    }
    else {
        Write-Error "setup_server.ps1 not found."; exit 1
    }

    Write-Host "Vanilla server ready in $installPath" -ForegroundColor Green

    # Generate and launch Vanilla run.bat
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

# Check/install installer JAR
Write-Host "Checking for installer JAR in $PSScriptRoot..." -ForegroundColor Cyan
$jar = Get-ChildItem -Path $PSScriptRoot -Filter '*-installer.jar' | Select-Object -First 1
if (-not $jar) {
    Write-Host "Installer JAR not found: starting download with setup_server.ps1..." -ForegroundColor Yellow
    $setupScript = Join-Path $PSScriptRoot 'setup_server.ps1'
    if (Test-Path $setupScript) {
        & "$setupScript"
        $jar = Get-ChildItem -Path $PSScriptRoot -Filter '*-installer.jar' | Select-Object -First 1
        if (-not $jar) { Write-Error "Installer JAR not found after setup."; exit 1 }
    } else {
        Write-Error "setup_server.ps1 not found."; exit 1
    }
}
$installerJar = $jar.FullName

# Create server folder
if (-not (Test-Path $installPath)) {
    Write-Host "Creating server folder: $installPath" -ForegroundColor Cyan
    New-Item -Path $installPath -ItemType Directory | Out-Null
}

# Resolve 'Recommended' build via promotions_slim.json
if ($selectedBuild -eq 'Recommended') {
    $promUrl  = 'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json'
    $prom     = Invoke-RestMethod -Uri $promUrl -UseBasicParsing
    $promoKey = "${selectedMc}-recommended"
    if ($prom.promos.PSObject.Properties.Name -contains $promoKey) {
        $selectedBuild = $prom.promos.$promoKey
        Write-Host "Recommended build for MC ${selectedMc}: $selectedBuild" -ForegroundColor Green
    } else {
        Write-Warning "No recommended build found for Minecraft ${selectedMc}" -ForegroundColor Yellow
    }
}

# Define baseUrl for Forge
$baseUrl = 'https://maven.minecraftforge.net/net/minecraftforge/forge'

# Prepare download URL and JAR path
$downloadUrl   = "$baseUrl/$selectedBuild/forge-$selectedMc-$selectedBuild-$installerType.jar"
$forgeJar      = Join-Path $PSScriptRoot "forge-$selectedMc-$selectedBuild-$installerType.jar"

# Download Forge installer if missing
if (-not (Test-Path $forgeJar)) {
    Write-Host "Downloading Forge $selectedBuild ($installerType) from: $downloadUrl" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $downloadUrl -OutFile $forgeJar -UseBasicParsing -ErrorAction Stop
    Write-Host "Download complete: $forgeJar" -ForegroundColor Green
} else {
    Write-Host "Forge installer already present: $forgeJar" -ForegroundColor Yellow
}

# Run Forge installer
Write-Host "Running Forge installer with: $javaCmd -jar $forgeJar --installServer $installPath" -ForegroundColor Cyan
& $javaCmd -jar $forgeJar --installServer $installPath
if ($LASTEXITCODE -ne 0) {
    Write-Error "Forge installer error (exit code $LASTEXITCODE)"
    exit $LASTEXITCODE
}
Write-Host "Forge installed in $installPath" -ForegroundColor Green

# Configure EULA
Write-Host "Configuring EULA..." -ForegroundColor Cyan
Start-Sleep -Seconds 2
Set-Content -Path (Join-Path $installPath 'eula.txt') -Value 'eula=true' -Encoding ASCII
Write-Host "EULA set to true." -ForegroundColor Green

# Invoke final setup_server.ps1
$setupScript = Join-Path $PSScriptRoot 'setup_server.ps1'
if (Test-Path $setupScript) { & $setupScript } else { Write-Warning "setup_server.ps1 not found." }

# 7-Zip CLI install
Install-7ZipCLI -Destination $PSScriptRoot

# mcrcon install
Install-Mcrcon  -Destination $PSScriptRoot

# Generate and launch Forge run.bat
Generate-RunBat `
  -InstallPath       $installPath `
  -VanillaSwitch     $false `
  -MinecraftVersion  $selectedMc `
  -JavaCmd           $javaCmd
$bat = Join-Path $installPath 'run.bat'
Start-Process -FilePath 'cmd.exe' `
              -ArgumentList "/c `"$bat`"" `
              -WorkingDirectory $installPath


# --- Clean up local installer files ---
Write-Host "Removing installer files" -ForegroundColor Cyan
$patterns = @(
    "$PSScriptRoot\7z-installer.exe",
    "$PSScriptRoot\jre8.exe",
    "$PSScriptRoot\jdk*.msi",
    "$PSScriptRoot\*-installer.jar"
)
foreach ($pattern in $patterns) {
    Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Removing $($_.FullName)" -ForegroundColor Yellow
        Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Cleanup complete." -ForegroundColor Green
