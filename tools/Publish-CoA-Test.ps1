#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Ref = 'refs/heads/agent/beta21-coa-test',
    [string]$AwsProfile = 'retreatui-r2',
    [string]$Bucket = 'retreatui-releases',
    [string]$EndpointUrl = 'https://f2f139a476f03851f203d52e399a8ffb.eu.r2.cloudflarestorage.com',
    [string]$PublicBaseUrl = 'https://pub-1f3b72d79f1d4138945f7bd13e131def.r2.dev',
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$PublicBaseUrl = $PublicBaseUrl.TrimEnd('/')
$workRoot = $null

function Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Ok([string]$Message) { Write-Host "    OK: $Message" -ForegroundColor Green }

function AwsBaseArgs {
    return @('--profile', $AwsProfile, '--endpoint-url', $EndpointUrl, '--region', 'auto', '--no-cli-pager')
}

function Invoke-Aws {
    param([string]$Aws, [string[]]$Arguments)
    & $Aws @Arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed with exit code $LASTEXITCODE." }
}

function Test-R2Object([string]$Aws, [string]$Key) {
    $args = @('s3api', 'head-object', '--bucket', $Bucket, '--key', $Key) + (AwsBaseArgs)
    & $Aws @args 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Put-R2Object {
    param([string]$Aws, [string]$Key, [string]$File, [string]$ContentType, [string]$CacheControl)
    Step "Uploading $Key"
    $args = @(
        's3api', 'put-object',
        '--bucket', $Bucket,
        '--key', $Key,
        '--body', $File,
        '--content-type', $ContentType,
        '--cache-control', $CacheControl
    ) + (AwsBaseArgs)
    Invoke-Aws -Aws $Aws -Arguments $args
    Ok "Uploaded $Key"
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-LiveFeed([string]$FeedKey) {
    $url = "${PublicBaseUrl}/${FeedKey}?v=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    Step "Loading current live feed $FeedKey"
    $raw = (Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }).Content
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    return @($parsed)
}

function FeedContainsAsset($Feed, [string]$AssetName) {
    foreach ($release in @($Feed)) {
        foreach ($asset in @($release.assets)) {
            if ($asset -and [string]$asset.name -eq $AssetName) { return $true }
        }
    }
    return $false
}

function Assert-Public([string]$Url) {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri ("${Url}?v=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())") -Method Head -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) { Ok "Public verification passed: $Url"; return }
        } catch { }
        Start-Sleep -Seconds 1
    }
    throw "Public verification failed: $Url"
}

if ([string]::IsNullOrWhiteSpace($Ref)) { throw 'A GitHub branch/ref is required.' }
if ($Ref -eq 'main' -or $Ref -eq 'refs/heads/main') { throw 'This script is for CoA prerelease branches only.' }

$packager = Join-Path $PSScriptRoot 'Publish-R2.ps1'
if (-not (Test-Path -LiteralPath $packager -PathType Leaf)) { throw "Packager not found: $packager" }

try {
    $tempRoot = [IO.Path]::GetTempPath()
    $before = @{}
    Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'RetreatUI-R2-Release-*' -ErrorAction SilentlyContinue | ForEach-Object { $before[$_.FullName] = $true }

    Step "Building CoA test package from $Ref"
    $packageParams = @{
        Product = 'CoA'
        Ref = $Ref
        DryRun = $true
        KeepWork = $true
    }
    & $packager @packageParams
    if (-not $?) { throw 'Validated CoA package build failed.' }

    $newRoots = @(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'RetreatUI-R2-Release-*' -ErrorAction SilentlyContinue | Where-Object { -not $before.ContainsKey($_.FullName) } | Sort-Object LastWriteTimeUtc -Descending)
    if ($newRoots.Count -eq 0) { throw 'Packager completed but its work directory could not be found.' }
    $workRoot = $newRoots[0].FullName
    Ok "Validated package work directory: $workRoot"

    $sourceContainer = Join-Path $workRoot 'source'
    $sourceRoot = (Get-ChildItem -LiteralPath $sourceContainer -Directory | Select-Object -First 1).FullName
    if (-not $sourceRoot) { throw 'Downloaded source root was not found.' }

    $manifestPath = Join-Path $sourceRoot '.github\release-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not [bool]$manifest.publish -or -not [bool]$manifest.prerelease) { throw 'CoA test manifest must have publish=true and prerelease=true.' }
    $version = [string]$manifest.version
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'CoA test manifest has no version.' }

    $assetName = "RetreatUI_v$version.zip"
    $assetPath = Join-Path $workRoot $assetName
    $checksumName = "$assetName.sha256"
    $checksumPath = "$assetPath.sha256"
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) { throw "Missing package: $assetPath" }
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { throw "Missing checksum: $checksumPath" }

    $notesPath = Join-Path $sourceRoot ([string]$manifest.notes_file)
    $body = if (Test-Path -LiteralPath $notesPath -PathType Leaf) { (Get-Content -LiteralPath $notesPath -Raw).Trim() } else { "RetreatUI v$version" }
    $title = if ($manifest.title) { [string]$manifest.title } else { "RetreatUI v$version" }

    $assetKey = "addons/coa/$version/$assetName"
    $checksumKey = "addons/coa/$version/$checksumName"
    $feedKey = 'feed/addon-releases.json'
    $assetUrl = "$PublicBaseUrl/$assetKey"
    $checksumUrl = "$PublicBaseUrl/$checksumKey"

    $awsCmd = Get-Command aws.exe -ErrorAction SilentlyContinue
    if (-not $awsCmd) { $awsCmd = Get-Command aws -ErrorAction SilentlyContinue }
    if (-not $awsCmd) { throw 'AWS CLI was not found in PATH.' }
    $aws = $awsCmd.Source

    Step 'Checking R2 write profile and bucket access'
    Invoke-Aws -Aws $aws -Arguments (@('s3api', 'list-objects-v2', '--bucket', $Bucket, '--max-keys', '1') + (AwsBaseArgs))
    Ok "AWS profile '$AwsProfile' can access bucket '$Bucket'"

    $feed = Get-LiveFeed $feedKey
    if (FeedContainsAsset -Feed $feed -AssetName $assetName) {
        Assert-Public $assetUrl
        Assert-Public $checksumUrl
        Write-Host "`nCoA $version is already present in the live Beta feed." -ForegroundColor Green
        return
    }

    $assetExists = Test-R2Object -Aws $aws -Key $assetKey
    $checksumExists = Test-R2Object -Aws $aws -Key $checksumKey

    if ($assetExists -xor $checksumExists) { throw 'Partial R2 state is inconsistent: only one of package/checksum exists.' }

    if ($assetExists -and $checksumExists) {
        Write-Host 'Existing package + checksum detected from an interrupted publish; resuming at feed publication.' -ForegroundColor Yellow
        Assert-Public $assetUrl
        Assert-Public $checksumUrl
    } else {
        Put-R2Object -Aws $aws -Key $assetKey -File $assetPath -ContentType 'application/zip' -CacheControl 'public, max-age=31536000, immutable'
        Put-R2Object -Aws $aws -Key $checksumKey -File $checksumPath -ContentType 'text/plain; charset=utf-8' -CacheControl 'public, max-age=31536000, immutable'
        Assert-Public $assetUrl
        Assert-Public $checksumUrl
    }

    $backupFile = Join-Path $workRoot 'addon-releases-backup.json'
    Write-Utf8NoBom -Path $backupFile -Text ((ConvertTo-Json -InputObject @($feed) -Depth 20) + "`n")
    $backupKey = "feed/backups/addon-releases-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')).json"
    Put-R2Object -Aws $aws -Key $backupKey -File $backupFile -ContentType 'application/json; charset=utf-8' -CacheControl 'private, max-age=0, no-store'

    $newEntry = [ordered]@{
        tag_name = "v$version"
        name = $title
        body = $body
        draft = $false
        prerelease = $true
        published_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        assets = @(
            [ordered]@{ name = $assetName; browser_download_url = $assetUrl; size = (Get-Item -LiteralPath $assetPath).Length },
            [ordered]@{ name = $checksumName; browser_download_url = $checksumUrl; size = (Get-Item -LiteralPath $checksumPath).Length }
        )
    }

    $merged = @($newEntry)
    foreach ($item in @($feed)) {
        $duplicate = $false
        foreach ($asset in @($item.assets)) {
            if ($asset -and [string]$asset.name -eq $assetName) { $duplicate = $true; break }
        }
        if (-not $duplicate) { $merged += $item }
        if ($merged.Count -ge 50) { break }
    }

    $feedFile = Join-Path $workRoot 'addon-releases.json'
    Write-Utf8NoBom -Path $feedFile -Text ((ConvertTo-Json -InputObject $merged -Depth 20) + "`n")
    Put-R2Object -Aws $aws -Key $feedKey -File $feedFile -ContentType 'application/json; charset=utf-8' -CacheControl 'no-store, max-age=0'

    $verifiedFeed = Get-LiveFeed $feedKey
    if (-not (FeedContainsAsset -Feed $verifiedFeed -AssetName $assetName)) { throw "Live feed verification failed for $assetName" }

    Write-Host "`nR2 BETA PUBLISHED" -ForegroundColor Green
    Write-Host "CoA $version is live and verified."
    Write-Host "Enable Beta in RetreatUI Launcher and check for updates."
}
finally {
    if ($workRoot -and (Test-Path -LiteralPath $workRoot) -and -not $KeepWork) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
