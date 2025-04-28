param(
    [switch]$help,                         # Mostra aiuto
    [string]$Destination        = '.',   # Percorso di destinazione (default: corrente)
    [string]$MinecraftVersion   = '',    # Versione MC (es. "1.20.1"); se vuota, verrà chiesta
    [string]$ForgeVersion       = '',    # Build Forge (es. "1.20.1-47.4.0"); se vuota useremo la Recommended
    [ValidateSet('installer','universal')]
    [string]$Installer          = 'installer',  # Tipo di pacchetto (installer/universal)
    [switch]$Vanilla                      # Se presente, scarica solo il server vanilla
)

if ($help) {
    Write-Host @"
Uso: .\setup_server.ps1 [-help] [-Destination <path>] [-MinecraftVersion <versione>] [-ForgeVersion <build>|Recommended] [-Installer <installer|universal>] [-Vanilla]

  -help               Mostra questo messaggio di aiuto e esce.
  -Destination <path> Cartella di destinazione (default: corrente).
  -MinecraftVersion   Versione Minecraft (es. 1.20.1).
  -ForgeVersion       Build di Forge (es. 1.20.1-47.4.0) o "Recommended".
  -Installer          "installer" (default) o "universal".
  -Vanilla            Scarica il server Minecraft vanilla invece di Forge.
"@ -ForegroundColor Green
    exit 0
}

Write-Host "Usa '-help' per le opzioni di utilizzo." -ForegroundColor Yellow

# Se esiste .ini, carica tutte le coppie KEY=VALUE e sovrascrivi parametri non specificati
if (Test-Path 'server.ini') {
    Write-Host "Caricamento configurazione da .ini..." -ForegroundColor Cyan
    Get-Content 'server.ini' | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)=(.*)$') {
            $key   = $matches[1].Trim()
            $value = $matches[2].Trim()
            switch ($key) {
                'DESTINATION'      { if (-not $PSBoundParameters.ContainsKey('Destination'))      { $Destination      = $value } }
                'MINECRAFT_VERSION'{ if (-not $PSBoundParameters.ContainsKey('MinecraftVersion')) { $MinecraftVersion = $value } }
                'FORGE_VERSION'    { if (-not $PSBoundParameters.ContainsKey('ForgeVersion'))     { $ForgeVersion     = $value } }
                'INSTALLER'        { if (-not $PSBoundParameters.ContainsKey('Installer'))        { $Installer        = $value } }
                'VANILLA'          { if (-not $PSBoundParameters.ContainsKey('Vanilla'))          { $Vanilla          = $value -match '^(true|1)$' } }
            }
        }
    }
    Write-Host "Configurazione applicata:" `
        "`n Destination = $Destination" `
        "`n MinecraftVersion = $MinecraftVersion" `
        "`n ForgeVersion = $ForgeVersion" `
        "`n Installer = $Installer" `
        "`n Vanilla = $Vanilla" -ForegroundColor Green
}

Set-Location $PSScriptRoot

# 1) Recupero build tramite metadata, fallback su promotions JSON
$metadataUrl = 'https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml'
Write-Host "Recupero metadata da $metadataUrl" -ForegroundColor Cyan
try {
    $xml = Invoke-RestMethod -Uri $metadataUrl -ErrorAction Stop
    $allBuilds = $xml.metadata.versioning.versions.version
    Write-Host "Lista build ottenuta da metadata XML." -ForegroundColor Green
} catch {
    Write-Warning "Metadata non disponibile, uso JSON promozioni come fonte alternativa."
    $promosUrl = 'https://files.minecraftforge.net/maven/net/minecraftforge/forge/promotions_slim.json'
    Write-Host "Recupero promozioni da $promosUrl" -ForegroundColor Cyan
    $promos = Invoke-RestMethod -Uri $promosUrl -ErrorAction Stop
    # Estrai tutte le versioni chiave dal JSON
    $allBuilds = $promos.promos.PSObject.Properties | ForEach-Object { $_.Name } |
        Where-Object { $_ -match '^[\d\.]+-recommended$' } |
        ForEach-Object { ($_ -split '-recommended')[0] } | Sort-Object -Unique |
        ForEach-Object { "$($_)-$($promos.promos."$_")" }
    Write-Host "Lista build ottenuta da JSON promozioni." -ForegroundColor Green
}
$allBuilds = $allBuilds | Sort-Object -Descending

# Lista versioni Minecraft
$mcVersions = $allBuilds | ForEach-Object { ($_ -split '-')[0] } | Sort-Object -Unique

if (-not $Vanilla) {
    # Selezione MC
    if ([string]::IsNullOrEmpty($MinecraftVersion) -or -not ($mcVersions -contains $MinecraftVersion)) {
        Write-Host "Seleziona la versione di Minecraft da scaricare:" -ForegroundColor Green
        for ($i=0; $i -lt $mcVersions.Count; $i++) { Write-Host " [$($i+1)] $($mcVersions[$i])" }
        do { $choice = Read-Host "Digita il numero (1-$($mcVersions.Count))" } until ($choice -as [int] -and $choice -ge 1 -and $choice -le $mcVersions.Count)
        $selectedMc = $mcVersions[$choice-1]
    } else { $selectedMc = $MinecraftVersion; Write-Host "MC specificata: $selectedMc" -ForegroundColor Cyan }

    # Determina build Forge
    if ([string]::IsNullOrEmpty($ForgeVersion) -or $ForgeVersion -ieq 'Recommended') {
        # Prendo l'ultima build per selectedMc
        $selectedBuild = ($allBuilds | Where-Object { $_ -like "$selectedMc-*" } | Sort-Object -Descending)[0]
        Write-Host "Usata build predefinita: $selectedBuild" -ForegroundColor Cyan
    } else {
        $selectedBuild = $ForgeVersion
        Write-Host "Usata build specificata: $selectedBuild" -ForegroundColor Cyan
    }

    # Download Forge
    $baseUrl = 'https://maven.minecraftforge.net/net/minecraftforge/forge'
    $url = "$baseUrl/$selectedBuild/forge-$selectedBuild-$Installer.jar"
    $dest = Join-Path $Destination "forge-$selectedBuild-$Installer.jar"
    Write-Host "Scarico Forge $selectedBuild ($Installer) da:`n$url" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    Write-Host "Download completato:`n$dest" -ForegroundColor Green
    exit 0
} else {
    # Download vanilla
    if ([string]::IsNullOrEmpty($MinecraftVersion) -or -not ($mcVersions -contains $MinecraftVersion)) {
        Write-Error "Per vanilla, specifica -MinecraftVersion (<versione>)"; exit 1
    }
    $manifest = Invoke-RestMethod https://launchermeta.mojang.com/mc/game/version_manifest.json
    $entry = $manifest.versions | Where-Object { $_.id -eq $MinecraftVersion }
    if (-not $entry) { Write-Error "Versione MC non trovata nel manifest Mojang"; exit 1 }
    $verMeta = Invoke-RestMethod $entry.url
    $serverUrl = $verMeta.downloads.server.url
    Write-Host "Scarico server vanilla $MinecraftVersion da:`n$serverUrl" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $serverUrl -OutFile (Join-Path $Destination "minecraft_server.$MinecraftVersion.jar") -UseBasicParsing -ErrorAction Stop
    Write-Host "Download vanilla completato." -ForegroundColor Green
    exit 0
}
