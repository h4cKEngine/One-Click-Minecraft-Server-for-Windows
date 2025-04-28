<#
setup_java.ps1
Script to install/uninstall Oracle JRE 8 and Microsoft OpenJDK 17 via MSI.
Parametri da server.ini:
  JreVersion=8
  JdkVersion=17
  ForceInstall=true|false
  Uninstall=true|false
#>

# Load configuration from server.ini
$ini = Join-Path $PSScriptRoot 'server.ini'
if (-not (Test-Path $ini)) {
    Write-Error "File 'server.ini' not found in $PSScriptRoot"
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

# Uninstall JRE 8 and JDK 17
function Uninstall-Java {
    Write-Host "Uninstalling Oracle JRE 8 and Microsoft OpenJDK 17..." -ForegroundColor Cyan

    # Patterns to identify packages to uninstall
    $patterns = @(
    '*OpenJDK*17*',
    'Microsoft JDK*17*'
    )
    # Two registry hives: 64-bit and 32-bit
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
                    Write-Host "Uninstalling: $name (ProductCode: $code)" -ForegroundColor Cyan
                    Start-Process msiexec.exe -ArgumentList "/x",$code,"/quiet","/norestart" `
                                  -Wait -NoNewWindow
                    break
                }
            }
        }
    }

    # Remove JAVA_HOME and Java/JDK references from user PATH
    Write-Host "Cleaning up environment variables..." -ForegroundColor Cyan
    [Environment]::SetEnvironmentVariable('JAVA_HOME',$null,'User')
    $userPath = [Environment]::GetEnvironmentVariable('Path','User').Split(';')
    $clean    = $userPath | Where-Object { $_ -and $_ -notmatch 'Java|jdk' }
    [Environment]::SetEnvironmentVariable('Path',($clean -join ';'),'User')
    $env:Path = [Environment]::GetEnvironmentVariable('Path','User')

    Write-Host "Uninstallation complete. Restart the shell to apply changes." -ForegroundColor Green
}

if ($Uninstall) {
    Uninstall-Java
    exit 0
}

# Download helper
function Download-IfNeeded {
    param([string]$url, [string]$out)
    if ((Test-Path $out) -and (-not $ForceInstall)) {
        Write-Host "Local file already present: $out" -ForegroundColor Yellow
    } else {
        Write-Host "Downloading: $url -> $out" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -ErrorAction Stop
    }
}

# 1) Installazione Oracle JRE 8
# if ($JreVersion -eq 8) {
#     Write-Host "=== Installing Oracle JRE 8 ===" -ForegroundColor Magenta
#     try {
#         & java -version *> $null
#         if (-not $ForceInstall) {
#             Write-Host "JRE already present, skipping installation." -ForegroundColor Green
#         } else {
#             throw
#         }
#     } catch {
#         $jreExe = Join-Path $PSScriptRoot 'jre8.exe'
#         $jreUrl = 'https://javadl.oracle.com/webapps/download/AutoDL?BundleId=252044_8a1589aa0fe24566b4337beee47c2d29'
#         # Download-IfNeeded -url $jreUrl -out $jreExe
#         Write-Host "Starting JRE installer in silent mode (requires admin)..." -ForegroundColor Cyan
#         $proc = Start-Process -FilePath $jreExe -ArgumentList '/s' -Verb RunAs -PassThru
#         $proc.WaitForExit()
#         if ($proc.ExitCode -eq 0) {
#             Write-Host "Oracle JRE 8 installed successfully." -ForegroundColor Green
#         } else {
#             Write-Warning "JRE installation error: ExitCode $($proc.ExitCode)"
#         }
#     }
# } else {
#     Write-Warning "JreVersion=$JreVersion not supported." -ForegroundColor Yellow
# }

# 2) Install OpenJDK 17 MSI
Write-Host "=== Installing OpenJDK 17 MSI ===" -ForegroundColor Magenta
try {
    & javac -version *> $null
    if (-not $ForceInstall) {
        Write-Host "JDK already present, skipping installation." -ForegroundColor Green
        exit 0
    } else {
        throw
    }
} catch {
    $msiPath = Join-Path $PSScriptRoot 'jdk17.msi'
    $msiUrl  = 'https://aka.ms/download-jdk/microsoft-jdk-17.0.13-windows-x64.msi'
    Download-IfNeeded -url $msiUrl -out $msiPath

    Write-Host "Starting JDK installation in silent mode (requires admin)..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath msiexec.exe `
                          -ArgumentList "/i `"$msiPath`" /quiet /norestart" `
                          -Verb RunAs -PassThru

    # -------------------------------------------
    # Installation Progress bar
    # -------------------------------------------
    $startTime = Get-Date
    while (-not $proc.HasExited) {
        $elapsed   = (Get-Date) - $startTime
        # Fake percentage: max 5 minutes (300 seconds)
        # Just to show that it isn't stuck
        $percent   = [math]::Min( [int]( $elapsed.TotalSeconds / 300 * 100 ), 99 )
        Write-Progress `
            -Activity "Installing OpenJDK 17" `
            -Status ("Running for {0:N0} s" -f $elapsed.TotalSeconds) `
            -PercentComplete $percent
        Start-Sleep -Milliseconds 500
    }
    # Clear the progress bar
    Write-Progress -Activity "Installing OpenJDK 17" -Completed

    if ($proc.ExitCode -eq 0) {
        Write-Host "OpenJDK 17 installed successfully." -ForegroundColor Green
    } else {
        Write-Warning "JDK installation error: ExitCode $($proc.ExitCode)"
    }
}

Write-Host "Java setup complete. Verify with: java -version and javac -version" -ForegroundColor Magenta

function Set-JavaHomeForJdk17 {
    [CmdletBinding()]
    param(
        # If you want to force an alternative directory, pass it here:
        [string]$PreferredInstallDir = $null
    )

    Write-Host "Looking for installed JDK 17..." -ForegroundColor Cyan

    # If you want to force an alternative directory, pass it here:
    if ($PreferredInstallDir -and (Test-Path $PreferredInstallDir)) {
        $installDir = $PreferredInstallDir
    }
    else {
        # Otherwise, attempt to derive it from the Windows registry
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
        Write-Warning "Could not find a JDK 17 installation directory."
        return
    }

    Write-Host "Setting JAVA_HOME to: $installDir" -ForegroundColor Green
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $installDir, 'User')

    # Prepare the new user Path with %JAVA_HOME%\bin at the front
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User').Split(';') `
                  | Where-Object { $_ -and ($_ -notlike '*\Java*') -and ($_ -notlike '*\jdk*') }
    $newPath = @("%JAVA_HOME%\bin") + $userPath
    $newPathString = ($newPath -join ';')

    Write-Host "Updating user Path to include JAVA_HOME:\bin" -ForegroundColor Green
    [Environment]::SetEnvironmentVariable('Path', $newPathString, 'User')

    Write-Host "Environment variables updated. Open a new shell to apply changes." -ForegroundColor Green
}
