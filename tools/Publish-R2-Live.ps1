#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('CoA', 'TBC', 'Launcher')]
    [string]$Product,

    [string]$Ref = 'main',
    [string]$AwsProfile = 'retreatui-r2',
    [string]$Bucket = 'retreatui-releases',
    [string]$EndpointUrl = 'https://f2f139a476f03851f203d52e399a8ffb.eu.r2.cloudflarestorage.com',
    [string]$PublicBaseUrl = 'https://pub-1f3b72d79f1d4138945f7bd13e131def.r2.dev',
    [string]$NotesFile,
    [switch]$Force,
    [switch]$KeepWork,
    [switch]$PushGitHubMirror
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$PublicBaseUrl = $PublicBaseUrl.TrimEnd('/')
$Script:WorkRoot = $null

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "    OK: $Message" -ForegroundColor Green
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-AwsCommand {
    $aws = Get-Command aws.exe -ErrorAction SilentlyContinue
    if (-not $aws) { $aws = Get-Command aws -ErrorAction SilentlyContinue }
    if (-not $aws) { throw 'AWS CLI was not found in PATH.' }
    return $aws.Source
}

function Get-AwsBaseArgs {
    return @(
        '--profile', $AwsProfile,
        '--endpoint-url', $EndpointUrl,
        '--region', 'auto',
        '--no-cli-pager'
    )
}

function Invoke-Aws {
    param(
        [Parameter(Mandatory = $true)][string]$Aws,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $Aws @Arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed with exit code ${LASTEXITCODE}."
    }
}

function Assert-R2Access([string]$Aws) {
    Write-Step 'Checking R2 write profile and bucket access'
    $args = @('s3api', 'list-objects-v2', '--bucket', $Bucket, '--max-keys', '1') + (Get-AwsBaseArgs)
    Invoke-Aws -Aws $aws -Arguments $args
    Write-Ok "AWS profile '$AwsProfile' can access bucket '$Bucket'"
}

function Test-R2ObjectExists([string]$Aws, [string]$Key) {
    $args = @('s3api', 'head-object', '--bucket', $Bucket, '--key', $Key) + (Get-AwsBaseArgs)
    & $Aws @args 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Put-R2Object {
    param(
        [Parameter(Mandatory = $true)][string]$Aws,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [Parameter(Mandatory = $true)][string]$CacheControl
    )

    Write-Step "Uploading $Key"
    $args = @(
        's3api', 'put-object',
        '--bucket', $Bucket,
        '--key', $Key,
        '--body', $File,
        '--content-type', $ContentType,
        '--cache-control', $CacheControl
    ) + (Get-AwsBaseArgs)
    Invoke-Aws -Aws $Aws -Arguments $args
    Write-Ok "Uploaded $Key"
}

function Get-ContentLength($Response) {
    $values = @($Response.Headers['Content-Length'])
    if ($values.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$values[0])) { return $null }
    return [long]([string]$values[0])
}

function Assert-PublicObject([string]$Url, [long]$ExpectedSize) {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $requestUrl = "${Url}?v=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
            $response = Invoke-WebRequest -Uri $requestUrl -Method Head -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                $actualLength = Get-ContentLength $response
                if ($null -eq $actualLength -or $actualLength -eq $ExpectedSize) {
                    Write-Ok "Public verification passed: $Url"
                    return
                }
            }
        }
        catch { }
        Start-Sleep -Seconds 1
    }
    throw "Uploaded object could not be verified through the public R2 URL: $Url"
}

function Get-LiveFeed([string]$FeedKey) {
    $url = "${PublicBaseUrl}/${FeedKey}?v=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    Write-Step "Loading current live feed $FeedKey"
    $raw = (Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }).Content
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    return @($parsed)
}

function Get-SourceRoot([string]$WorkRoot) {
    $sourceContainer = Join-Path $WorkRoot 'source'
    $root = Get-ChildItem -LiteralPath $sourceContainer -Directory | Select-Object -First 1
    if (-not $root) { throw "Could not locate downloaded source below $sourceContainer" }
    return $root.FullName
}

function Read-Manifest([string]$SourceRoot) {
    $path = Join-Path $SourceRoot '.github\release-manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release manifest not found: $path" }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-ReleaseNotes {
    param(
        [string]$SourceRoot,
        [string]$Version,
        [string]$ManifestNotesFile,
        [string]$Fallback
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($NotesFile) { $candidates.Add($NotesFile) }
    if ($ManifestNotesFile) { $candidates.Add((Join-Path $SourceRoot $ManifestNotesFile)) }
    $candidates.Add((Join-Path $SourceRoot 'RELEASE_NOTES.md'))
    $candidates.Add((Join-Path $SourceRoot "RELEASE_NOTES_$Version.md"))
    $candidates.Add((Join-Path $SourceRoot "RetreatUI.Launcher\RELEASE_NOTES_$Version.md"))

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Get-Content -LiteralPath $candidate -Raw).Trim()
        }
    }
    return $Fallback
}

function Invoke-Packager {
    $packager = Join-Path $PSScriptRoot 'Publish-R2.ps1'
    if (-not (Test-Path -LiteralPath $packager -PathType Leaf)) { throw "Packager not found: $packager" }

    $tempRoot = [IO.Path]::GetTempPath()
    $before = @{}
    Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'RetreatUI-R2-Release-*' -ErrorAction SilentlyContinue | ForEach-Object {
        $before[$_.FullName] = $true
    }

    Write-Step "Running validated $Product packager"
    $packagerParams = @{
        Product = $Product
        Ref = $Ref
        DryRun = $true
        KeepWork = $true
    }
    if ($NotesFile) { $packagerParams.NotesFile = $NotesFile }
    & $packager @packagerParams
    if (-not $?) { throw 'The validated package build failed.' }

    $newRoots = @(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'RetreatUI-R2-Release-*' -ErrorAction SilentlyContinue | Where-Object {
        -not $before.ContainsKey($_.FullName)
    } | Sort-Object LastWriteTimeUtc -Descending)

    if ($newRoots.Count -eq 0) { throw 'The packager completed but its work directory could not be identified.' }
    $script:WorkRoot = $newRoots[0].FullName
    Write-Ok "Validated package work directory: $Script:WorkRoot"
}

function Get-PreparedRelease {
    $source = Get-SourceRoot $Script:WorkRoot

    if ($Product -eq 'CoA') {
        $manifest = Read-Manifest $source
        $asset = Get-ChildItem -LiteralPath $Script:WorkRoot -File -Filter 'RetreatUI_v*.zip' | Select-Object -First 1
        if (-not $asset) { throw 'Validated CoA ZIP was not found.' }
        $version = $asset.Name.Substring('RetreatUI_v'.Length)
        $version = $version.Substring(0, $version.Length - 4)
        if ([string]$manifest.version -ne $version) { throw 'CoA package version no longer matches its release manifest.' }
        $manifestNotes = if ($manifest.PSObject.Properties.Name -contains 'notes_file') { [string]$manifest.notes_file } else { '' }
        $title = if ($manifest.PSObject.Properties.Name -contains 'title' -and $manifest.title) { [string]$manifest.title } else { "RetreatUI v$version" }
        $body = Get-ReleaseNotes -SourceRoot $source -Version $version -ManifestNotesFile $manifestNotes -Fallback $title
        return [pscustomobject]@{
            Product='CoA'; Version=$version; Tag="v$version"; Title=$title; Body=$body; Prerelease=[bool]$manifest.prerelease
            AssetName=$asset.Name; AssetPath=$asset.FullName; ChecksumName="$($asset.Name).sha256"; ChecksumPath="$($asset.FullName).sha256"
            AssetKey="addons/coa/$version/$($asset.Name)"; ChecksumKey="addons/coa/$version/$($asset.Name).sha256"; FeedKey='feed/addon-releases.json'
        }
    }

    if ($Product -eq 'TBC') {
        $manifest = Read-Manifest $source
        $asset = Get-ChildItem -LiteralPath $Script:WorkRoot -File -Filter 'RetreatUI_TBC_v*.zip' | Select-Object -First 1
        if (-not $asset) { throw 'Validated TBC ZIP was not found.' }
        $version = $asset.Name.Substring('RetreatUI_TBC_v'.Length)
        $version = $version.Substring(0, $version.Length - 4)
        if ([string]$manifest.version -ne $version) { throw 'TBC package version no longer matches its release manifest.' }
        $manifestNotes = if ($manifest.PSObject.Properties.Name -contains 'notes_file') { [string]$manifest.notes_file } else { '' }
        $title = if ($manifest.PSObject.Properties.Name -contains 'title' -and $manifest.title) { [string]$manifest.title } else { "RetreatUI TBC $version" }
        $body = Get-ReleaseNotes -SourceRoot $source -Version $version -ManifestNotesFile $manifestNotes -Fallback $title
        return [pscustomobject]@{
            Product='TBC'; Version=$version; Tag="v$version"; Title=$title; Body=$body; Prerelease=[bool]$manifest.prerelease
            AssetName=$asset.Name; AssetPath=$asset.FullName; ChecksumName="$($asset.Name).sha256"; ChecksumPath="$($asset.FullName).sha256"
            AssetKey="addons/tbc/$version/$($asset.Name)"; ChecksumKey="addons/tbc/$version/$($asset.Name).sha256"; FeedKey='feed/addon-releases.json'
        }
    }

    $assetPath = Join-Path $Script:WorkRoot 'RetreatUI_Launcher.exe'
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) { throw 'Validated launcher executable was not found.' }
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($assetPath).FileVersion
    $match = [regex]::Match([string]$fileVersion, '^(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) { throw "Could not determine launcher version from $fileVersion" }
    $version = "$($match.Groups[1].Value).$($match.Groups[2].Value).$($match.Groups[3].Value)"
    $title = "RetreatUI Launcher v$version"
    $body = Get-ReleaseNotes -SourceRoot $source -Version $version -ManifestNotesFile '' -Fallback $title
    return [pscustomobject]@{
        Product='Launcher'; Version=$version; Tag="launcher-v$version"; Title=$title; Body=$body; Prerelease=$false
        AssetName='RetreatUI_Launcher.exe'; AssetPath=$assetPath; ChecksumName='RetreatUI_Launcher.exe.sha256'; ChecksumPath="$assetPath.sha256"
        AssetKey="launcher/$version/RetreatUI_Launcher.exe"; ChecksumKey="launcher/$version/RetreatUI_Launcher.exe.sha256"; FeedKey='feed/launcher-releases.json'
    }
}

function New-FeedRelease($Release) {
    return [ordered]@{
        tag_name = $Release.Tag
        name = $Release.Title
        body = $Release.Body
        draft = $false
        prerelease = [bool]$Release.Prerelease
        published_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        assets = @(
            [ordered]@{
                name = $Release.AssetName
                browser_download_url = "$PublicBaseUrl/$($Release.AssetKey)"
                size = (Get-Item -LiteralPath $Release.AssetPath).Length
            },
            [ordered]@{
                name = $Release.ChecksumName
                browser_download_url = "$PublicBaseUrl/$($Release.ChecksumKey)"
                size = (Get-Item -LiteralPath $Release.ChecksumPath).Length
            }
        )
    }
}

function Merge-Feed($Existing, $NewRelease, [string]$AssetName) {
    $result = New-Object System.Collections.Generic.List[object]
    $result.Add($NewRelease)
    foreach ($item in @($Existing)) {
        $duplicate = $false
        foreach ($asset in @($item.assets)) {
            if ($asset -and [string]$asset.name -eq $AssetName) { $duplicate = $true; break }
        }
        if (-not $duplicate) { $result.Add($item) }
        if ($result.Count -ge 50) { break }
    }
    return @($result)
}

function Assert-LiveFeedContains([string]$FeedKey, [string]$AssetName, [string]$ExpectedUrl) {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $feed = Get-LiveFeed $FeedKey
            foreach ($release in @($feed)) {
                foreach ($asset in @($release.assets)) {
                    if ($asset -and [string]$asset.name -eq $AssetName -and [string]$asset.browser_download_url -eq $ExpectedUrl) {
                        Write-Ok "Live feed verification passed for $AssetName"
                        return
                    }
                }
            }
        }
        catch { }
        Start-Sleep -Seconds 1
    }
    throw "The live feed does not contain newly published asset $AssetName"
}

function Update-GitHubFeedMirror([string]$FeedKey, [string]$JsonText, $Release) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $relativeFeed = $FeedKey.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $mirrorPath = Join-Path $repoRoot $relativeFeed
    New-Item -ItemType Directory -Path (Split-Path -Parent $mirrorPath) -Force | Out-Null
    Write-Utf8NoBom -Path $mirrorPath -Text ($JsonText + "`n")
    Write-Ok "Updated local GitHub fallback mirror: $FeedKey"

    if (-not $PushGitHubMirror) { return }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { Write-Warning 'git was not found; R2 is live but the GitHub fallback mirror was not pushed.'; return }

    try {
        & $git.Source -C $repoRoot add -- $relativeFeed 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
        & $git.Source -C $repoRoot diff --cached --quiet -- $relativeFeed
        if ($LASTEXITCODE -eq 0) { Write-Ok 'GitHub fallback mirror already matched'; return }
        & $git.Source -C $repoRoot commit -m "Mirror $($Release.Product) $($Release.Version) R2 release feed" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
        & $git.Source -C $repoRoot push 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
        Write-Ok 'GitHub fallback feed pushed without GitHub Actions'
    }
    catch {
        Write-Warning "R2 publish succeeded, but optional GitHub mirror push failed: $($_.Exception.Message)"
    }
}

try {
    Invoke-Packager
    $release = Get-PreparedRelease

    if (-not (Test-Path -LiteralPath $release.ChecksumPath -PathType Leaf)) {
        throw "Checksum was not produced by validated packager: $($release.ChecksumPath)"
    }

    Write-Host "`nLIVE RELEASE PLAN" -ForegroundColor White
    Write-Host "  Product:     $($release.Product)"
    Write-Host "  Version:     $($release.Version)"
    Write-Host "  Asset:       $($release.AssetName)"
    Write-Host "  R2 key:      $($release.AssetKey)"
    Write-Host "  Feed:        $($release.FeedKey)"
    Write-Host "  AWS profile: $AwsProfile"
    Write-Host "  Bucket:      $Bucket"

    $aws = Get-AwsCommand
    Assert-R2Access $aws

    if (-not $Force -and (Test-R2ObjectExists -Aws $aws -Key $release.AssetKey)) {
        throw "Immutable release object already exists: $($release.AssetKey). Bump the version instead of republishing it."
    }
    if (-not $Force -and (Test-R2ObjectExists -Aws $aws -Key $release.ChecksumKey)) {
        throw "Immutable checksum object already exists: $($release.ChecksumKey). Bump the version instead of republishing it."
    }

    $existingFeed = Get-LiveFeed $release.FeedKey
    if (-not $Force) {
        foreach ($item in @($existingFeed)) {
            foreach ($asset in @($item.assets)) {
                if ($asset -and [string]$asset.name -eq $release.AssetName) {
                    throw "The live feed already contains $($release.AssetName). Bump the version instead of republishing it."
                }
            }
        }
    }

    $assetType = if ($Product -eq 'Launcher') { 'application/x-msdownload' } else { 'application/zip' }
    Put-R2Object -Aws $aws -Key $release.AssetKey -File $release.AssetPath -ContentType $assetType -CacheControl 'public, max-age=31536000, immutable'
    Put-R2Object -Aws $aws -Key $release.ChecksumKey -File $release.ChecksumPath -ContentType 'text/plain; charset=utf-8' -CacheControl 'public, max-age=31536000, immutable'

    $assetUrl = "$PublicBaseUrl/$($release.AssetKey)"
    $checksumUrl = "$PublicBaseUrl/$($release.ChecksumKey)"
    Assert-PublicObject -Url $assetUrl -ExpectedSize (Get-Item -LiteralPath $release.AssetPath).Length
    Assert-PublicObject -Url $checksumUrl -ExpectedSize (Get-Item -LiteralPath $release.ChecksumPath).Length

    $feedName = [IO.Path]::GetFileName($release.FeedKey)
    $backupFile = Join-Path $Script:WorkRoot ("backup-" + $feedName)
    $feedFile = Join-Path $Script:WorkRoot $feedName
    $backupJson = ConvertTo-Json -InputObject @($existingFeed) -Depth 20
    Write-Utf8NoBom -Path $backupFile -Text ($backupJson + "`n")
    $backupKey = "feed/backups/$([IO.Path]::GetFileNameWithoutExtension($feedName))-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')).json"
    Put-R2Object -Aws $aws -Key $backupKey -File $backupFile -ContentType 'application/json; charset=utf-8' -CacheControl 'private, max-age=0, no-store'

    $newEntry = New-FeedRelease $release
    $merged = Merge-Feed -Existing $existingFeed -NewRelease $newEntry -AssetName $release.AssetName
    $feedJson = ConvertTo-Json -InputObject @($merged) -Depth 20
    Write-Utf8NoBom -Path $feedFile -Text ($feedJson + "`n")

    # The live feed is uploaded last. A failure before this line cannot advertise a half-published release.
    Put-R2Object -Aws $aws -Key $release.FeedKey -File $feedFile -ContentType 'application/json; charset=utf-8' -CacheControl 'no-store, max-age=0'
    Assert-LiveFeedContains -FeedKey $release.FeedKey -AssetName $release.AssetName -ExpectedUrl $assetUrl
    Update-GitHubFeedMirror -FeedKey $release.FeedKey -JsonText $feedJson -Release $release

    Write-Host "`nR2 RELEASE PUBLISHED" -ForegroundColor Green
    Write-Host "$($release.Product) $($release.Version) is live and verified."
    Write-Host "Asset: $assetUrl"
    Write-Host "Feed:  $PublicBaseUrl/$($release.FeedKey)"
}
finally {
    if ($Script:WorkRoot -and (Test-Path -LiteralPath $Script:WorkRoot) -and -not $KeepWork) {
        Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
