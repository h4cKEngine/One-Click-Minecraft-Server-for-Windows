param(
    [switch]$help,                         # Shows help
    [string]$Destination        = '.',     # Destination path (default: current)
    [string]$MinecraftVersion   = '',      # Minecraft version (e.g. "1.20.1"); if empty, will be requested
    [string]$ForgeVersion       = '',      # Forge build (e.g. "1.20.1-47.4.0"); if empty, use Recommended
    [ValidateSet('installer','universal')]
    [string]$Installer          = 'installer',  # Package type (installer/universal)
    [switch]$Vanilla                     # If present, download only the vanilla server
)

if ($help) {
    Write-Host @"
Usage: .\setup_server.ps1 [-help] [-Destination <path>] [-MinecraftVersion <version>] [-ForgeVersion <build>|Recommended] [-Installer <installer|universal>] [-Vanilla]

  -help               Shows this help message and exits.
  -Destination <path> Destination folder (default: current).
  -MinecraftVersion   Minecraft version (e.g. 1.20.1).
  -ForgeVersion       Forge build (e.g. 1.20.1-47.4.0) or "Recommended".
  -Installer          "installer" (default) or "universal".
  -Vanilla            Download the vanilla Minecraft server instead of Forge.
"@ -ForegroundColor Green
    exit 0
}

Write-Host "Use '-help' for usage options." -ForegroundColor Yellow

# If a .ini exists, load all KEY=VALUE pairs and override unspecified parameters
if (Test-Path 'server.ini') {
    Write-Host "Loading configuration from .ini..." -ForegroundColor Cyan
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
    Write-Host "Configuration applied:" `
        "`n Destination       = $Destination" `
        "`n MinecraftVersion  = $MinecraftVersion" `
        "`n ForgeVersion      = $ForgeVersion" `
        "`n Installer         = $Installer" `
        "`n Vanilla           = $Vanilla" -ForegroundColor Green
}

Set-Location $PSScriptRoot

# 1) Retrieve builds via metadata, fallback to promotions JSON
$metadataUrl = 'https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml'
Write-Host "Retrieving metadata from $metadataUrl" -ForegroundColor Cyan
try {
    $xml = Invoke-RestMethod -Uri $metadataUrl -ErrorAction Stop
    $allBuilds = $xml.metadata.versioning.versions.version
    Write-Host "Build list obtained from metadata XML." -ForegroundColor Green
} catch {
    Write-Warning "Metadata unavailable, using promotions JSON as alternative source."
    $promosUrl = 'https://files.minecraftforge.net/maven/net/minecraftforge/forge/promotions_slim.json'
    Write-Host "Retrieving promotions from $promosUrl" -ForegroundColor Cyan
    $promos = Invoke-RestMethod -Uri $promosUrl -ErrorAction Stop
    $allBuilds = $promos.promos.PSObject.Properties | ForEach-Object { $_.Name } |
        Where-Object { $_ -match '^[\d\.]+-recommended$' } |
        ForEach-Object { ($_ -split '-recommended')[0] } | Sort-Object -Unique |
        ForEach-Object { "$($_)-$($promos.promos."$_")" }
    Write-Host "Build list obtained from promotions JSON." -ForegroundColor Green
}
$allBuilds = $allBuilds | Sort-Object -Descending

# Minecraft version list
$mcVersions = $allBuilds | ForEach-Object { ($_ -split '-')[0] } | Sort-Object -Unique

if (-not $Vanilla) {
    # Select Minecraft version
    if ([string]::IsNullOrEmpty($MinecraftVersion) -or -not ($mcVersions -contains $MinecraftVersion)) {
        Write-Host "Select the Minecraft version to download:" -ForegroundColor Green
        for ($i=0; $i -lt $mcVersions.Count; $i++) { Write-Host " [$($i+1)] $($mcVersions[$i])" }
        do { $choice = Read-Host "Enter the number (1-$($mcVersions.Count))" } until ($choice -as [int] -and $choice -ge 1 -and $choice -le $mcVersions.Count)
        $selectedMc = $mcVersions[$choice-1]
    } else {
        $selectedMc = $MinecraftVersion
        Write-Host "MC specified: $selectedMc" -ForegroundColor Cyan
    }

    # Determine Forge build
    if ([string]::IsNullOrEmpty($ForgeVersion) -or $ForgeVersion -ieq 'Recommended') {
        $selectedBuild = ($allBuilds | Where-Object { $_ -like "$selectedMc-*" } | Sort-Object -Descending)[0]
        Write-Host "Using default build: $selectedBuild" -ForegroundColor Cyan
    } else {
        $selectedBuild = $ForgeVersion
        Write-Host "Using specified build: $selectedBuild" -ForegroundColor Cyan
    }

    # Download Forge
    $baseUrl = 'https://maven.minecraftforge.net/net/minecraftforge/forge'
    $url = "$baseUrl/$selectedBuild/forge-$selectedBuild-$Installer.jar"
    $dest = Join-Path $Destination "forge-$selectedBuild-$Installer.jar"
    Write-Host "Downloading Forge $selectedBuild ($Installer) from:`n$url" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    Write-Host "Download complete:`n$dest" -ForegroundColor Green
    exit 0
} else {
    # Download vanilla
    if ([string]::IsNullOrEmpty($MinecraftVersion) -or -not ($mcVersions -contains $MinecraftVersion)) {
        Write-Error "For vanilla, specify -MinecraftVersion (<version>)"
        exit 1
    }
    $manifest = Invoke-RestMethod https://launchermeta.mojang.com/mc/game/version_manifest.json
    $entry = $manifest.versions | Where-Object { $_.id -eq $MinecraftVersion }
    if (-not $entry) {
        Write-Error "MC version not found in Mojang manifest"
        exit 1
    }
    $verMeta = Invoke-RestMethod $entry.url
    $serverUrl = $verMeta.downloads.server.url
    Write-Host "Downloading vanilla server $MinecraftVersion from:`n$serverUrl" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $serverUrl -OutFile (Join-Path $Destination "minecraft_server.$MinecraftVersion.jar") -UseBasicParsing -ErrorAction Stop
    Write-Host "Vanilla download complete." -ForegroundColor Green
    exit 0
}
