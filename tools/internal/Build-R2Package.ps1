#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('CoA', 'TBC', 'Launcher')]
    [string]$Product,
    [string]$Ref = 'main',
    [string]$NotesFile,
    [switch]$DryRun,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Script:WorkRoot = $null

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "    OK: $Message" -ForegroundColor Green }

function Invoke-External([string]$FilePath, [string[]]$Arguments) {
    & $FilePath @Arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $FilePath" }
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required JSON file was not found: $Path" }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-TocVersion([string]$Path) {
    $match = Select-String -LiteralPath $Path -Pattern '^## Version:\s*(.+?)\s*$' | Select-Object -First 1
    if (-not $match) { throw "No ## Version field found in $Path" }
    return $match.Matches[0].Groups[1].Value.Trim()
}

function Assert-Equal([string]$Name, [string]$Actual, [string]$Expected) {
    if ($Actual -ne $Expected) { throw "$Name is '$Actual', expected '$Expected'." }
}

function Download-Repo([string]$Repository) {
    $archive = Join-Path $Script:WorkRoot 'source.zip'
    $extract = Join-Path $Script:WorkRoot 'source'
    Write-Step "Downloading $Repository @ $Ref"
    Invoke-WebRequest -Uri "https://github.com/$Repository/archive/$Ref.zip" -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $root = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $root) { throw "Downloaded archive for $Repository contained no source root." }
    Write-Ok 'Source downloaded'
    return $root.FullName
}

function New-Package([string]$SourceRoot, [string[]]$Folders, [string]$DestinationZip) {
    $stage = Join-Path $Script:WorkRoot 'package'
    if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($folder in $Folders) {
        $source = Join-Path $SourceRoot $folder
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Required package folder missing: $source" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $folder) -Recurse -Force
    }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $DestinationZip -CompressionLevel Optimal -Force
}

function Assert-ZipEntries([string]$ZipPath, [string[]]$RequiredEntries) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\\','/') })
        foreach ($entry in $RequiredEntries) {
            if ($names -notcontains $entry) { throw "Package validation failed; missing ZIP entry: $entry" }
        }
    }
    finally { $zip.Dispose() }
}

function Write-Checksum([string]$File) {
    $hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($File))" | Set-Content -LiteralPath "$File.sha256" -Encoding ASCII
    return $hash
}

function Get-ProjectVersion([string]$Project) {
    $match = [regex]::Match((Get-Content -LiteralPath $Project -Raw), '<Version>\s*([^<]+?)\s*</Version>')
    if (-not $match.Success) { throw "Could not read launcher version from $Project" }
    return $match.Groups[1].Value.Trim()
}

function Normalize-Version([string]$Value) {
    $match = [regex]::Match($Value, '^(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) { return $Value.Trim() }
    return "$($match.Groups[1].Value).$($match.Groups[2].Value).$($match.Groups[3].Value)"
}

try {
    $Script:WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ("RetreatUI-R2-Release-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Script:WorkRoot | Out-Null

    Write-Step "Preparing $Product release package"

    if ($Product -eq 'CoA') {
        $source = Download-Repo 'RetreatUI/RetreatUI-Addon'
        $manifest = Read-Json (Join-Path $source '.github\release-manifest.json')
        $version = [string]$manifest.version
        if ([string]::IsNullOrWhiteSpace($version)) { throw 'CoA release manifest has no version.' }
        if (-not [bool]$manifest.publish) { throw 'CoA release manifest has publish=false.' }
        Assert-Equal 'RetreatUI.toc version' (Get-TocVersion (Join-Path $source 'RetreatUI\RetreatUI.toc')) $version
        Assert-Equal 'RetreatUI_Classes.toc version' (Get-TocVersion (Join-Path $source 'RetreatUI_Classes\RetreatUI_Classes.toc')) $version
        Assert-Equal 'RetreatUI_BuffManager.toc version' (Get-TocVersion (Join-Path $source 'RetreatUI_BuffManager\RetreatUI_BuffManager.toc')) $version
        $asset = Join-Path $Script:WorkRoot "RetreatUI_v$version.zip"
        New-Package -SourceRoot $source -Folders @('RetreatUI','RetreatUI_Classes','RetreatUI_BuffManager') -DestinationZip $asset
        Assert-ZipEntries -ZipPath $asset -RequiredEntries @('RetreatUI/RetreatUI.toc','RetreatUI_Classes/RetreatUI_Classes.toc','RetreatUI_BuffManager/RetreatUI_BuffManager.toc')
    }
    elseif ($Product -eq 'TBC') {
        $source = Download-Repo 'RetreatUI/RetreatUI-TBC'
        $manifest = Read-Json (Join-Path $source '.github\release-manifest.json')
        $version = [string]$manifest.version
        if ([string]::IsNullOrWhiteSpace($version)) { throw 'TBC release manifest has no version.' }
        if (($manifest.PSObject.Properties.Name -contains 'publish') -and -not [bool]$manifest.publish) { throw 'TBC release manifest has publish=false.' }
        Assert-Equal 'TBC RetreatUI.toc version' (Get-TocVersion (Join-Path $source 'RetreatUI\RetreatUI.toc')) $version
        $coreMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $source 'RetreatUI\Core.lua') -Raw), 'RUI\.version\s*=\s*"([^"]+)"')
        if (-not $coreMatch.Success) { throw 'Could not read RUI.version from TBC Core.lua.' }
        Assert-Equal 'TBC Core.lua version' $coreMatch.Groups[1].Value $version
        $asset = Join-Path $Script:WorkRoot "RetreatUI_TBC_v$version.zip"
        New-Package -SourceRoot $source -Folders @('RetreatUI') -DestinationZip $asset
        Assert-ZipEntries -ZipPath $asset -RequiredEntries @('RetreatUI/RetreatUI.toc')
    }
    else {
        $source = Download-Repo 'RetreatUI/RetreatUI-Launcher'
        $project = Join-Path $source 'RetreatUI.Launcher\RetreatUI.Launcher.csproj'
        $version = Get-ProjectVersion $project
        $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $dotnet) { throw 'dotnet was not found. Install the .NET 8 SDK.' }
        $publishDir = Join-Path $Script:WorkRoot 'launcher-publish'
        Write-Step "Building RetreatUI Launcher $version"
        Invoke-External -FilePath $dotnet.Source -Arguments @('publish',$project,'-c','Release','-r','win-x64','--self-contained','true','-o',$publishDir)
        $built = Join-Path $publishDir 'RetreatUI_Launcher.exe'
        if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { throw 'Launcher build did not produce RetreatUI_Launcher.exe.' }
        $asset = Join-Path $Script:WorkRoot 'RetreatUI_Launcher.exe'
        Copy-Item -LiteralPath $built -Destination $asset -Force
        $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($asset).FileVersion
        Assert-Equal 'Launcher executable version' (Normalize-Version $fileVersion) (Normalize-Version $version)
    }

    $sha = Write-Checksum $asset
    Write-Host "`nRelease summary" -ForegroundColor White
    Write-Host "  Product:    $Product"
    Write-Host "  Version:    $version"
    Write-Host "  Asset:      $([IO.Path]::GetFileName($asset))"
    Write-Host "  SHA-256:    $sha"
    Write-Host "  Source ref: $Ref"
    Write-Host "`nPACKAGE VALIDATED; nothing was uploaded." -ForegroundColor Yellow
    Write-Host "Work directory: $Script:WorkRoot"
}
finally {
    if ($Script:WorkRoot -and (Test-Path -LiteralPath $Script:WorkRoot) -and -not $KeepWork) {
        Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
