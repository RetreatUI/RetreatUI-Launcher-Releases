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

function Write-Info([string]$Message) {
    Write-Host "    INFO: $Message" -ForegroundColor Yellow
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
    $url = "${PublicBaseUrl}/${Key}?v=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
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

function Get-ContentLength($Response) {
    $values = @($Response.Headers['Content-Length'])
    if ($values.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$values[0])) {
        return $null
    }
    return [long]([string]$values[0])
}

function Assert-UrlReachable([string]$Url, [long]$ExpectedSize = 0, [string]$Label = 'asset') {
    $requestUrl = "${Url}?v=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    $response = Invoke-WebRequest -Uri $requestUrl -Method Head -UseBasicParsing -MaximumRedirection 10 -Headers @{ 'Cache-Control' = 'no-cache' }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "Asset request failed: $Url" }

    $actualLength = Get-ContentLength $response
    if ($ExpectedSize -gt 0 -and $null -ne $actualLength -and $ExpectedSize -ne $actualLength) {
        throw "Asset size mismatch for ${Label}: expected=$ExpectedSize, public=$actualLength."
    }
    Write-Ok "$Label is publicly reachable"
}

function Assert-PublicAsset($Found) {
    if (-not $Found) { throw 'Required asset was not present in the live feed.' }
    $url = [string]$Found.Asset.browser_download_url
    if ([string]::IsNullOrWhiteSpace($url)) { throw 'Live feed asset has no download URL.' }
    $expectedSize = 0
    if ($Found.Asset.size) { $expectedSize = [long]$Found.Asset.size }
    Assert-UrlReachable -Url $url -ExpectedSize $expectedSize -Label ([string]$Found.Asset.name)
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

Write-Step 'Checking live CoA R2 feed path'
$addonFeed = Get-Feed 'feed/addon-releases.json'
Assert-PublicAsset (Find-Asset $addonFeed 'RetreatUI_v1.1.7-beta.19.zip')

Write-Step 'Checking current TBC fallback path'
$tbcR2 = Find-Asset $addonFeed 'RetreatUI_TBC_v0.1.0-beta.16.zip'
if ($tbcR2) {
    Assert-PublicAsset $tbcR2
    Write-Ok 'TBC beta.16 is already served from R2'
}
else {
    Write-Info 'TBC beta.16 is not in the current R2 feed; Launcher 0.3.12 currently obtains it from the GitHub Releases fallback.'
    Assert-UrlReachable `
        -Url 'https://github.com/RetreatUI/RetreatUI-TBC/releases/download/v0.1.0-beta.16/RetreatUI_TBC_v0.1.0-beta.16.zip' `
        -ExpectedSize 107533 `
        -Label 'RetreatUI_TBC_v0.1.0-beta.16.zip GitHub fallback'
}

Write-Step 'Checking live launcher R2 feed'
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
Write-Host 'Current state is healthy. CoA and Launcher are served from R2; TBC beta.16 is currently served through the verified GitHub fallback.'
Write-Host 'No R2 objects were modified or uploaded.'
