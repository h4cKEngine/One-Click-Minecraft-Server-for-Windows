<#
setup_java.ps1
Script per installare/disinstallare Oracle JRE 8 e OpenJDK 17 Microsoft MSI.
Parametri da server.ini:
  JreVersion=8
  JdkVersion=17
  ForceInstall=true|false
  Uninstall=true|false
#>

# Carica configurazione da server.ini
$ini = Join-Path $PSScriptRoot 'server.ini'
if (-not (Test-Path $ini)) {
    Write-Error "File 'server.ini' non trovato in $PSScriptRoot"
    exit 1
}
$cfg = @{}
Get-Content $ini | ForEach-Object {
    if ($_ -match '^(?<k>[^#=]+)=(?<v>.*)$') {
        $cfg[$matches.k.Trim()] = $matches.v.Trim()
    }
}
[int]$JreVersion    = if ($cfg.ContainsKey('JreVersion'))    { [int]$cfg['JreVersion'] }    else { 8 }
[int]$JdkVersion    = if ($cfg.ContainsKey('JdkVersion'))    { [int]$cfg['JdkVersion'] }    else { 17 }
[bool]$ForceInstall = if ($cfg.ContainsKey('ForceInstall')) { $cfg['ForceInstall'] -match '^(true|1)$' } else { $false }
[bool]$Uninstall    = if ($cfg.ContainsKey('Uninstall'))    { $cfg['Uninstall']    -match '^(true|1)$' } else { $false }

# Disinstallazione JRE 8 e JDK 17
function Uninstall-Java {
    Write-Host "Disinstallazione Oracle JRE 8 e Microsoft OpenJDK 17..." -ForegroundColor Cyan

    # Pattern per riconoscere i pacchetti da disinstallare
#    $patterns = @(
#        '*Java(TM)*SE*Runtime*Environment*8*',
#        '*Java 8*',
#       '*OpenJDK*17*',
#        'Microsoft JDK*17*'
#   )
    $patterns = @(
    '*OpenJDK*17*',
    'Microsoft JDK*17*'
    )
    # Due hive: 64-bit e 32-bit
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $regPaths) {
        Get-ItemProperty $path -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($pat in $patterns) {
                if ($_.DisplayName -like $pat) {
                    $name = $_.DisplayName
                    $code = $_.PSChildName
                    Write-Host "Disinstallo: $name (ProductCode: $code)" -ForegroundColor Cyan
                    Start-Process msiexec.exe -ArgumentList "/x",$code,"/quiet","/norestart" `
                                  -Wait -NoNewWindow
                    break
                }
            }
        }
    }

    # Rimuovi JAVA_HOME e riferimenti Java/JDK da PATH utente
    Write-Host "Pulizia variabili d'ambiente..." -ForegroundColor Cyan
    [Environment]::SetEnvironmentVariable('JAVA_HOME',$null,'User')
    $userPath = [Environment]::GetEnvironmentVariable('Path','User').Split(';')
    $clean    = $userPath | Where-Object { $_ -and $_ -notmatch 'Java|jdk' }
    [Environment]::SetEnvironmentVariable('Path',($clean -join ';'),'User')
    $env:Path = [Environment]::GetEnvironmentVariable('Path','User')

    Write-Host "Disinstallazione completata. Riavvia la shell per applicare i cambiamenti." -ForegroundColor Green
}

if ($Uninstall) {
    Uninstall-Java
    exit 0
}

# Helper per download
function Download-IfNeeded {
    param([string]$url, [string]$out)
    if ((Test-Path $out) -and (-not $ForceInstall)) {
        Write-Host "File locale già presente: $out" -ForegroundColor Yellow
    } else {
        Write-Host "Download: $url -> $out" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -ErrorAction Stop
    }
}


# 1) Installazione Oracle JRE 8
# if ($JreVersion -eq 8) {
#     Write-Host "=== Installazione Oracle JRE 8 ===" -ForegroundColor Magenta
#     try {
#         & java -version *> $null
#         if (-not $ForceInstall) {
#             Write-Host "JRE già presente, skip installation." -ForegroundColor Green
#         } else {
#             throw
#         }
#     } catch {
#         $jreExe = Join-Path $PSScriptRoot 'jre8.exe'
#         $jreUrl = 'https://javadl.oracle.com/webapps/download/AutoDL?BundleId=252044_8a1589aa0fe24566b4337beee47c2d29'
#         # Download-IfNeeded -url $jreUrl -out $jreExe
#         Write-Host "Avvio installer JRE in silent mode (richiede admin)..." -ForegroundColor Cyan
#         $proc = Start-Process -FilePath $jreExe -ArgumentList '/s' -Verb RunAs -PassThru
#         $proc.WaitForExit()
#         if ($proc.ExitCode -eq 0) {
#             Write-Host "Oracle JRE 8 installato con successo." -ForegroundColor Green
#         } else {
#             Write-Warning "Errore installazione JRE: ExitCode $($proc.ExitCode)"
#         }
#     }
# } else {
#     Write-Warning "JreVersion=$JreVersion non supportato." -ForegroundColor Yellow
# }

# 2) Installazione OpenJDK 17 MSI
Write-Host "=== Installazione OpenJDK 17 MSI ===" -ForegroundColor Magenta
try {
    & javac -version *> $null
    if (-not $ForceInstall) {
        Write-Host "JDK già presente, skip installation." -ForegroundColor Green
        exit 0
    } else {
        throw
    }
} catch {
    $msiPath = Join-Path $PSScriptRoot 'jdk17.msi'
    $msiUrl  = 'https://aka.ms/download-jdk/microsoft-jdk-17.0.13-windows-x64.msi'
    Download-IfNeeded -url $msiUrl -out $msiPath

    Write-Host "Avvio installazione JDK in silent mode (richiede admin)..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath msiexec.exe `
                          -ArgumentList "/i `"$msiPath`" /quiet /norestart" `
                          -Verb RunAs -PassThru

    # -------------------------------------------
    # barra di progresso durante l'installazione
    # -------------------------------------------
    $startTime = Get-Date
    while (-not $proc.HasExited) {
        $elapsed   = (Get-Date) - $startTime
        # percentuale fittizia: max 5 minuti (300s)
        $percent   = [math]::Min( [int]( $elapsed.TotalSeconds / 300 * 100 ), 99 )
        Write-Progress `
            -Activity "Installazione OpenJDK 17" `
            -Status ("In corso da {0:N0} s" -f $elapsed.TotalSeconds) `
            -PercentComplete $percent
        Start-Sleep -Milliseconds 500
    }
    # pulisco la barra
    Write-Progress -Activity "Installazione OpenJDK 17" -Completed

    if ($proc.ExitCode -eq 0) {
        Write-Host "OpenJDK 17 installato con successo." -ForegroundColor Green
    } else {
        Write-Warning "Errore installazione JDK: ExitCode $($proc.ExitCode)"
    }
}

Write-Host "Setup Java completato. Verifica con: java -version e javac -version" -ForegroundColor Magenta

function Set-JavaHomeForJdk17 {
    [CmdletBinding()]
    param(
        # Se vuoi forzare un percorso alternativo, puoi passarlo qui:
        [string]$PreferredInstallDir = $null
    )

    Write-Host "Ricerca del JDK 17 installato..." -ForegroundColor Cyan

    # Se l'utente fornisce direttamente un percorso, lo usiamo
    if ($PreferredInstallDir -and (Test-Path $PreferredInstallDir)) {
        $installDir = $PreferredInstallDir
    }
    else {
        # Altrimenti tentiamo di ricavarlo dal registro di Windows
        $regPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $installDir = $null
        foreach ($p in $regPaths) {
            Get-ItemProperty $p -ErrorAction SilentlyContinue |
              Where-Object { $_.DisplayName -match 'OpenJDK.*17|Microsoft JDK.*17' } |
              ForEach-Object {
                  if ($_.InstallLocation -and (Test-Path $_.InstallLocation)) {
                      $installDir = $_.InstallLocation
                  }
              }
            if ($installDir) { break }
        }
    }

    if (-not $installDir) {
        Write-Warning "Non sono riuscito a trovare una cartella di installazione JDK 17."
        return
    }

    Write-Host "Imposto JAVA_HOME su: $installDir" -ForegroundColor Green
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $installDir, 'User')

    # Prepara il nuovo Path utente con %JAVA_HOME%\bin davanti
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User').Split(';') `
                  | Where-Object { $_ -and ($_ -notlike '*\Java*') -and ($_ -notlike '*\jdk*') }
    $newPath = @("%JAVA_HOME%\bin") + $userPath
    $newPathString = ($newPath -join ';')

    Write-Host "Aggiorno Path utente per includere JAVA_HOME:\bin" -ForegroundColor Green
    [Environment]::SetEnvironmentVariable('Path', $newPathString, 'User')

    Write-Host "Variabili d’ambiente aggiornate. Apri una nuova shell per applicare i cambiamenti." -ForegroundColor Green
}
