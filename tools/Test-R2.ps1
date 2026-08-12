#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$AwsProfile = 'retreatui-r2',
    [string]$Bucket = 'retreatui-releases',
    [string]$EndpointUrl = 'https://f2f139a476f03851f203d52e399a8ffb.eu.r2.cloudflarestorage.com',
    [string]$PublicBaseUrl = 'https://pub-1f3b72d79f1d4138945f7bd13e131def.r2.dev'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$PublicBaseUrl = $PublicBaseUrl.TrimEnd('/')

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "    OK: $Message" -ForegroundColor Green
}

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $aws = Get-Command aws.exe -ErrorAction SilentlyContinue
    if (-not $aws) { $aws = Get-Command aws -ErrorAction SilentlyContinue }
    if (-not $aws) { throw 'AWS CLI was not found in PATH.' }

    & $aws.Source @Arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed with exit code ${LASTEXITCODE}."
    }
}

function Get-Feed([string]$Key) {
    $url = "$PublicBaseUrl/$Key?v=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Feed request failed: $url"
    }
    return @($response.Content | ConvertFrom-Json)
}

function Find-Asset($Releases, [string]$AssetName) {
    foreach ($release in @($Releases)) {
        foreach ($asset in @($release.assets)) {
            if ($asset -and [string]$asset.name -eq $AssetName) {
                return [pscustomobject]@{ Release = $release; Asset = $asset }
            }
        }
    }
    return $null
}

function Assert-PublicAsset($Found) {
    if (-not $Found) { throw 'Required asset was not present in the live feed.' }
    $url = [string]$Found.Asset.browser_download_url
    if ([string]::IsNullOrWhiteSpace($url)) { throw 'Live feed asset has no download URL.' }
    $response = Invoke-WebRequest -Uri "$url?v=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -Method Head -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "Asset request failed: $url" }
    if ($Found.Asset.size -and $response.Headers['Content-Length']) {
        if ([long]$Found.Asset.size -ne [long]$response.Headers['Content-Length']) {
            throw "Asset size mismatch for $($Found.Asset.name)."
        }
    }
    Write-Ok "$($Found.Asset.name) is publicly reachable"
}

Write-Step 'Checking existing R2 AWS profile and bucket access'
Invoke-Aws @(
    's3api', 'list-objects-v2',
    '--bucket', $Bucket,
    '--max-keys', '1',
    '--profile', $AwsProfile,
    '--endpoint-url', $EndpointUrl,
    '--region', 'auto',
    '--no-cli-pager'
)
Write-Ok "AWS profile '$AwsProfile' can access bucket '$Bucket'"

Write-Step 'Checking live addon feed'
$addonFeed = Get-Feed 'feed/addon-releases.json'
Assert-PublicAsset (Find-Asset $addonFeed 'RetreatUI_v1.1.7-beta.19.zip')
Assert-PublicAsset (Find-Asset $addonFeed 'RetreatUI_TBC_v0.1.0-beta.16.zip')

Write-Step 'Checking live launcher feed'
$launcherFeed = Get-Feed 'feed/launcher-releases.json'
$launcher = Find-Asset $launcherFeed 'RetreatUI_Launcher.exe'
if (-not $launcher) { throw 'RetreatUI_Launcher.exe was not present in the live launcher feed.' }
$launcherVersion = ([string]$launcher.Release.tag_name).Replace('launcher-v', '').Replace('v', '')
if ($launcherVersion -ne '0.3.12') {
    throw "Live launcher feed reports $launcherVersion, expected 0.3.12."
}
Assert-PublicAsset $launcher
Assert-PublicAsset (Find-Asset $launcherFeed 'RetreatUI_Launcher.exe.sha256')

Write-Host "`nR2 PRE-FLIGHT PASSED" -ForegroundColor Green
Write-Host 'No R2 objects were modified or uploaded.'
