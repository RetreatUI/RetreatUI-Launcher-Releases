#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('CoA', 'TBC', 'Launcher')]
    [string]$Product,

    [string]$Ref = 'main',
    [string]$Bucket,
    [string]$PublicBaseUrl = 'https://pub-1f3b72d79f1d4138945f7bd13e131def.r2.dev',
    [string]$ArtifactPath,
    [string]$NotesFile,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$KeepWork,
    [switch]$PushGitHubMirror
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$PublicBaseUrl = $PublicBaseUrl.TrimEnd('/')
$ConfigPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RetreatUI\release-config.json'
$Script:WorkRoot = $null

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "    OK: $Message" -ForegroundColor Green
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE: $FilePath $($Arguments -join ' ')"
    }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file was not found: $Path"
    }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-TocVersion([string]$Path) {
    $match = Select-String -LiteralPath $Path -Pattern '^## Version:\s*(.+?)\s*$' | Select-Object -First 1
    if (-not $match) { throw "No ## Version field found in $Path" }
    return $match.Matches[0].Groups[1].Value.Trim()
}

function Assert-Equal([string]$Name, [string]$Actual, [string]$Expected) {
    if ($Actual -ne $Expected) {
        throw "$Name is '$Actual', expected '$Expected'. Release aborted."
    }
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

function Download-RepositoryArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$GitRef,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $archive = Join-Path $DestinationRoot 'source.zip'
    $extract = Join-Path $DestinationRoot 'source'
    $url = "https://github.com/$Repository/archive/$GitRef.zip"

    Write-Step "Downloading $Repository @ $GitRef"
    Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $root = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $root) { throw "GitHub archive for $Repository did not contain a source directory." }
    Write-Ok "Source downloaded"
    return $root.FullName
}

function New-ZipFromFolders {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string[]]$Folders,
        [Parameter(Mandatory = $true)][string]$DestinationZip
    )

    $stage = Join-Path $Script:WorkRoot 'package'
    if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null

    foreach ($folder in $Folders) {
        $source = Join-Path $SourceRoot $folder
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            throw "Required package folder is missing: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $folder) -Recurse -Force
    }

    if (Test-Path $DestinationZip) { Remove-Item -LiteralPath $DestinationZip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $DestinationZip -CompressionLevel Optimal
    if (-not (Test-Path $DestinationZip -PathType Leaf) -or (Get-Item $DestinationZip).Length -le 0) {
        throw "Package ZIP was not created correctly: $DestinationZip"
    }
}

function Assert-ZipEntries {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string[]]$RequiredEntries
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\\', '/') })
        foreach ($entry in $RequiredEntries) {
            if ($names -notcontains $entry) {
                throw "Package validation failed. Missing ZIP entry: $entry"
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Write-ChecksumFile([string]$FilePath) {
    $hash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumPath = "$FilePath.sha256"
    "$hash  $([IO.Path]::GetFileName($FilePath))" | Set-Content -LiteralPath $checksumPath -Encoding ASCII
    return [pscustomobject]@{ Hash = $hash; Path = $checksumPath }
}

function Get-LauncherVersionFromProject([string]$ProjectPath) {
    $text = Get-Content -LiteralPath $ProjectPath -Raw
    $match = [regex]::Match($text, '<Version>\s*([^<]+?)\s*</Version>')
    if (-not $match.Success) { throw "Could not read launcher version from $ProjectPath" }
    return $match.Groups[1].Value.Trim()
}

function Normalize-ThreePartVersion([string]$Value) {
    $match = [regex]::Match($Value, '^(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) { return $Value.Trim() }
    return "$($match.Groups[1].Value).$($match.Groups[2].Value).$($match.Groups[3].Value)"
}

function Prepare-CoA {
    $source = Download-RepositoryArchive -Repository 'RetreatUI/RetreatUI-Addon' -GitRef $Ref -DestinationRoot $Script:WorkRoot
    $manifest = Read-JsonFile (Join-Path $source '.github\release-manifest.json')
    if (-not [bool]$manifest.publish -and -not $Force) { throw 'CoA release-manifest has publish=false. Use -Force only if this is intentional.' }

    $version = [string]$manifest.version
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'CoA release-manifest has no version.' }
    Assert-Equal 'RetreatUI.toc version' (Get-TocVersion (Join-Path $source 'RetreatUI\RetreatUI.toc')) $version
    Assert-Equal 'RetreatUI_Classes.toc version' (Get-TocVersion (Join-Path $source 'RetreatUI_Classes\RetreatUI_Classes.toc')) $version
    Assert-Equal 'RetreatUI_BuffManager.toc version' (Get-TocVersion (Join-Path $source 'RetreatUI_BuffManager\RetreatUI_BuffManager.toc')) $version

    $assetName = "RetreatUI_v$version.zip"
    $assetPath = Join-Path $Script:WorkRoot $assetName
    New-ZipFromFolders -SourceRoot $source -Folders @('RetreatUI', 'RetreatUI_Classes', 'RetreatUI_BuffManager') -DestinationZip $assetPath
    Assert-ZipEntries -ZipPath $assetPath -RequiredEntries @(
        'RetreatUI/RetreatUI.toc',
        'RetreatUI_Classes/RetreatUI_Classes.toc',
        'RetreatUI_BuffManager/RetreatUI_BuffManager.toc'
    )
    $checksum = Write-ChecksumFile $assetPath
    $manifestNotes = if ($manifest.PSObject.Properties.Name -contains 'notes_file') { [string]$manifest.notes_file } else { '' }
    $title = if ($manifest.PSObject.Properties.Name -contains 'title' -and $manifest.title) { [string]$manifest.title } else { "RetreatUI v$version" }
    $body = Get-ReleaseNotes -SourceRoot $source -Version $version -ManifestNotesFile $manifestNotes -Fallback $title

    return [pscustomobject]@{
        Product = 'CoA'; Version = $version; Tag = "v$version"; Title = $title; Body = $body
        Prerelease = [bool]$manifest.prerelease; AssetName = $assetName; AssetPath = $assetPath
        ChecksumName = "$assetName.sha256"; ChecksumPath = $checksum.Path; Sha256 = $checksum.Hash
        AssetKey = "addons/coa/$version/$assetName"; ChecksumKey = "addons/coa/$version/$assetName.sha256"
        FeedKey = 'feed/addon-releases.json'
    }
}

function Prepare-TBC {
    $source = Download-RepositoryArchive -Repository 'RetreatUI/RetreatUI-TBC' -GitRef $Ref -DestinationRoot $Script:WorkRoot
    $manifest = Read-JsonFile (Join-Path $source '.github\release-manifest.json')
    if (($manifest.PSObject.Properties.Name -contains 'publish') -and -not [bool]$manifest.publish -and -not $Force) {
        throw 'TBC release-manifest has publish=false. Use -Force only if this is intentional.'
    }

    $version = [string]$manifest.version
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'TBC release-manifest has no version.' }
    Assert-Equal 'TBC RetreatUI.toc version' (Get-TocVersion (Join-Path $source 'RetreatUI\RetreatUI.toc')) $version

    $coreText = Get-Content -LiteralPath (Join-Path $source 'RetreatUI\Core.lua') -Raw
    $coreMatch = [regex]::Match($coreText, 'RUI\.version\s*=\s*"([^"]+)"')
    if (-not $coreMatch.Success) { throw 'Could not read RUI.version from TBC RetreatUI/Core.lua.' }
    Assert-Equal 'TBC Core.lua version' $coreMatch.Groups[1].Value $version

    $assetName = "RetreatUI_TBC_v$version.zip"
    $assetPath = Join-Path $Script:WorkRoot $assetName
    New-ZipFromFolders -SourceRoot $source -Folders @('RetreatUI') -DestinationZip $assetPath
    Assert-ZipEntries -ZipPath $assetPath -RequiredEntries @('RetreatUI/RetreatUI.toc')
    $checksum = Write-ChecksumFile $assetPath
    $manifestNotes = if ($manifest.PSObject.Properties.Name -contains 'notes_file') { [string]$manifest.notes_file } else { '' }
    $title = if ($manifest.PSObject.Properties.Name -contains 'title' -and $manifest.title) { [string]$manifest.title } else { "RetreatUI TBC $version" }
    $body = Get-ReleaseNotes -SourceRoot $source -Version $version -ManifestNotesFile $manifestNotes -Fallback $title

    return [pscustomobject]@{
        Product = 'TBC'; Version = $version; Tag = "v$version"; Title = $title; Body = $body
        Prerelease = [bool]$manifest.prerelease; AssetName = $assetName; AssetPath = $assetPath
        ChecksumName = "$assetName.sha256"; ChecksumPath = $checksum.Path; Sha256 = $checksum.Hash
        AssetKey = "addons/tbc/$version/$assetName"; ChecksumKey = "addons/tbc/$version/$assetName.sha256"
        FeedKey = 'feed/addon-releases.json'
    }
}

function Prepare-Launcher {
    $source = Download-RepositoryArchive -Repository 'RetreatUI/RetreatUI-Launcher' -GitRef $Ref -DestinationRoot $Script:WorkRoot
    $project = Join-Path $source 'RetreatUI.Launcher\RetreatUI.Launcher.csproj'
    $version = Get-LauncherVersionFromProject $project
    $targetExe = Join-Path $Script:WorkRoot 'RetreatUI_Launcher.exe'

    if ($ArtifactPath) {
        $resolved = (Resolve-Path -LiteralPath $ArtifactPath).Path
        Copy-Item -LiteralPath $resolved -Destination $targetExe -Force
    }
    else {
        $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $dotnet) {
            throw 'dotnet was not found. Install the .NET 8 SDK or pass -ArtifactPath with an already built RetreatUI_Launcher.exe.'
        }
        $publishDir = Join-Path $Script:WorkRoot 'launcher-publish'
        Write-Step "Building RetreatUI Launcher $version"
        Invoke-External -FilePath $dotnet.Source -Arguments @(
            'publish', $project, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-o', $publishDir
        )
        $built = Join-Path $publishDir 'RetreatUI_Launcher.exe'
        if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { throw "Launcher build did not produce $built" }
        Copy-Item -LiteralPath $built -Destination $targetExe -Force
    }

    $fileVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($targetExe).FileVersion
    Assert-Equal 'Launcher executable version' (Normalize-ThreePartVersion $fileVersion) (Normalize-ThreePartVersion $version)
    $checksum = Write-ChecksumFile $targetExe
    $title = "RetreatUI Launcher v$version"
    $body = Get-ReleaseNotes -SourceRoot $source -Version $version -ManifestNotesFile '' -Fallback $title

    return [pscustomobject]@{
        Product = 'Launcher'; Version = $version; Tag = "launcher-v$version"; Title = $title; Body = $body
        Prerelease = $false; AssetName = 'RetreatUI_Launcher.exe'; AssetPath = $targetExe
        ChecksumName = 'RetreatUI_Launcher.exe.sha256'; ChecksumPath = $checksum.Path; Sha256 = $checksum.Hash
        AssetKey = "launcher/$version/RetreatUI_Launcher.exe"; ChecksumKey = "launcher/$version/RetreatUI_Launcher.exe.sha256"
        FeedKey = 'feed/launcher-releases.json'
    }
}

function Get-LocalConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $null }
    try { return Read-JsonFile $ConfigPath } catch { return $null }
}

function Save-LocalConfig([string]$BucketName, [string]$BaseUrl) {
    $dir = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $json = ConvertTo-Json -InputObject ([ordered]@{ bucket = $BucketName; publicBaseUrl = $BaseUrl })
    Write-Utf8NoBom -Path $ConfigPath -Text ($json + "`n")
}

function Resolve-R2Configuration {
    $config = Get-LocalConfig
    if (-not $Bucket -and $config -and $config.bucket) { $script:Bucket = [string]$config.bucket }
    if ($config -and $config.publicBaseUrl -and $PublicBaseUrl -eq 'https://pub-1f3b72d79f1d4138945f7bd13e131def.r2.dev') {
        $script:PublicBaseUrl = ([string]$config.publicBaseUrl).TrimEnd('/')
    }
    if (-not $Bucket) {
        $script:Bucket = Read-Host 'Cloudflare R2 bucket name (saved locally; this is not a secret)'
    }
    if ([string]::IsNullOrWhiteSpace($Bucket)) { throw 'An R2 bucket name is required.' }
    Save-LocalConfig -BucketName $Bucket -BaseUrl $PublicBaseUrl
}

function Get-NpxCommand {
    $command = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command npx -ErrorAction SilentlyContinue }
    if (-not $command) {
        throw 'npx was not found. Install Node.js LTS, then run this command again.'
    }
    return $command.Source
}

function Ensure-WranglerLogin([string]$Npx) {
    Write-Step 'Checking Cloudflare Wrangler login'
    & $Npx --yes wrangler@latest whoami *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Wrangler is not logged in. A browser login will open now.' -ForegroundColor Yellow
        Invoke-External -FilePath $Npx -Arguments @('--yes', 'wrangler@latest', 'login')
    }
    Write-Ok 'Cloudflare authentication ready'
}

function Put-R2Object {
    param(
        [string]$Npx,
        [string]$Key,
        [string]$File,
        [string]$ContentType,
        [string]$CacheControl
    )

    Write-Step "Uploading $Key"
    Invoke-External -FilePath $Npx -Arguments @(
        '--yes', 'wrangler@latest', 'r2', 'object', 'put', "$Bucket/$Key",
        '--file', $File, '--remote', '--content-type', $ContentType, '--cache-control', $CacheControl
    )
    Write-Ok "Uploaded $Key"
}

function Test-PublicObjectExists([string]$Url) {
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    }
    catch {
        return $false
    }
}

function Assert-PublicObject {
    param([string]$Url, [long]$ExpectedSize)

    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri "$Url?v=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -Method Head -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                $lengthHeader = $response.Headers['Content-Length']
                if (-not $lengthHeader -or [long]$lengthHeader -eq $ExpectedSize) {
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
    $url = "$PublicBaseUrl/$FeedKey?v=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    Write-Step "Loading current live feed $FeedKey"
    try {
        $raw = (Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }).Content
        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    }
    catch {
        if ($Force) {
            Write-Warning "Could not load the current feed. -Force allows starting from an empty feed: $($_.Exception.Message)"
            return @()
        }
        throw "Could not load the current live feed. Refusing to overwrite release history. $($_.Exception.Message)"
    }
}

function New-FeedRelease($Release) {
    $assetUrl = "$PublicBaseUrl/$($Release.AssetKey)"
    $checksumUrl = "$PublicBaseUrl/$($Release.ChecksumKey)"
    $assets = @(
        [ordered]@{
            name = $Release.AssetName
            browser_download_url = $assetUrl
            size = (Get-Item -LiteralPath $Release.AssetPath).Length
        },
        [ordered]@{
            name = $Release.ChecksumName
            browser_download_url = $checksumUrl
            size = (Get-Item -LiteralPath $Release.ChecksumPath).Length
        }
    )

    return [ordered]@{
        tag_name = $Release.Tag
        name = $Release.Title
        body = $Release.Body
        draft = $false
        prerelease = [bool]$Release.Prerelease
        published_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        assets = $assets
    }
}

function Merge-Feed {
    param($Existing, $NewRelease, [string]$AssetName)

    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Existing)) {
        $duplicate = $false
        foreach ($asset in @($item.assets)) {
            if ($asset -and [string]$asset.name -eq $AssetName) { $duplicate = $true; break }
        }
        if (-not $duplicate) { $filtered.Add($item) }
    }

    $result = New-Object System.Collections.Generic.List[object]
    $result.Add($NewRelease)
    foreach ($item in $filtered) {
        if ($result.Count -ge 50) { break }
        $result.Add($item)
    }
    return @($result)
}

function Assert-LiveFeedContains([string]$FeedKey, [string]$AssetName, [string]$ExpectedUrl) {
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            $live = Get-LiveFeed $FeedKey
            foreach ($release in @($live)) {
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
    throw "The live feed does not contain the newly published asset: $AssetName"
}

function Update-GitHubFeedMirror {
    param([string]$FeedKey, [string]$JsonText, $Release)

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $gitDir = Join-Path $repoRoot '.git'
    if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) {
        Write-Warning 'R2 publish succeeded, but this script is not running from a git clone. GitHub fallback feed was not mirrored locally.'
        return
    }

    $relativeFeed = $FeedKey.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $mirrorPath = Join-Path $repoRoot $relativeFeed
    $mirrorDir = Split-Path -Parent $mirrorPath
    New-Item -ItemType Directory -Path $mirrorDir -Force | Out-Null
    Write-Utf8NoBom -Path $mirrorPath -Text ($JsonText + "`n")
    Write-Ok "Updated local GitHub fallback feed: $FeedKey"

    if (-not $PushGitHubMirror) { return }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Warning 'R2 publish succeeded, but git was not found; GitHub fallback feed was not pushed.'
        return
    }

    try {
        Invoke-External -FilePath $git.Source -Arguments @('-C', $repoRoot, 'add', '--', $relativeFeed)
        & $git.Source -C $repoRoot diff --cached --quiet -- $relativeFeed
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'GitHub fallback feed already matched the live R2 feed'
            return
        }
        Invoke-External -FilePath $git.Source -Arguments @('-C', $repoRoot, 'commit', '-m', "Mirror $($Release.Product) $($Release.Version) R2 release feed")
        Invoke-External -FilePath $git.Source -Arguments @('-C', $repoRoot, 'push')
        Write-Ok 'GitHub fallback feed committed and pushed without GitHub Actions'
    }
    catch {
        Write-Warning "R2 publish is live, but the optional GitHub feed mirror push failed: $($_.Exception.Message)"
    }
}

try {
    $Script:WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ("RetreatUI-R2-Release-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Script:WorkRoot | Out-Null

    Write-Step "Preparing $Product release"
    $release = switch ($Product) {
        'CoA' { Prepare-CoA }
        'TBC' { Prepare-TBC }
        'Launcher' { Prepare-Launcher }
    }

    Write-Host "`nRelease summary" -ForegroundColor White
    Write-Host "  Product:    $($release.Product)"
    Write-Host "  Version:    $($release.Version)"
    Write-Host "  Asset:      $($release.AssetName)"
    Write-Host "  SHA-256:    $($release.Sha256)"
    Write-Host "  Source ref: $Ref"

    if ($DryRun) {
        Write-Host "`nDRY RUN: package validated; nothing was uploaded." -ForegroundColor Yellow
        Write-Host "Work directory: $Script:WorkRoot"
        $KeepWork = $true
        return
    }

    Resolve-R2Configuration
    $npx = Get-NpxCommand
    Ensure-WranglerLogin $npx

    $assetUrl = "$PublicBaseUrl/$($release.AssetKey)"
    $checksumUrl = "$PublicBaseUrl/$($release.ChecksumKey)"
    if (-not $Force -and (Test-PublicObjectExists $assetUrl)) {
        throw "The immutable release asset already exists: $assetUrl. Bump the version, or use -Force only for an intentional replacement."
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

    $assetContentType = if ($release.Product -eq 'Launcher') { 'application/x-msdownload' } else { 'application/zip' }
    Put-R2Object -Npx $npx -Key $release.AssetKey -File $release.AssetPath -ContentType $assetContentType -CacheControl 'public, max-age=31536000, immutable'
    Put-R2Object -Npx $npx -Key $release.ChecksumKey -File $release.ChecksumPath -ContentType 'text/plain; charset=utf-8' -CacheControl 'public, max-age=31536000, immutable'
    Assert-PublicObject -Url $assetUrl -ExpectedSize (Get-Item -LiteralPath $release.AssetPath).Length
    Assert-PublicObject -Url $checksumUrl -ExpectedSize (Get-Item -LiteralPath $release.ChecksumPath).Length

    $feedFileName = [IO.Path]::GetFileName($release.FeedKey)
    $feedLocal = Join-Path $Script:WorkRoot $feedFileName
    $backupLocal = Join-Path $Script:WorkRoot ("backup-" + $feedFileName)
    $backupJson = ConvertTo-Json -InputObject @($existingFeed) -Depth 20
    Write-Utf8NoBom -Path $backupLocal -Text ($backupJson + "`n")

    $backupKey = "feed/backups/$([IO.Path]::GetFileNameWithoutExtension($feedFileName))-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')).json"
    Put-R2Object -Npx $npx -Key $backupKey -File $backupLocal -ContentType 'application/json; charset=utf-8' -CacheControl 'private, max-age=0, no-store'

    $newFeedRelease = New-FeedRelease $release
    $merged = Merge-Feed -Existing $existingFeed -NewRelease $newFeedRelease -AssetName $release.AssetName
    $feedJson = ConvertTo-Json -InputObject @($merged) -Depth 20
    Write-Utf8NoBom -Path $feedLocal -Text ($feedJson + "`n")

    # Feed is intentionally uploaded last. If anything above fails, users never see a half-published release.
    Put-R2Object -Npx $npx -Key $release.FeedKey -File $feedLocal -ContentType 'application/json; charset=utf-8' -CacheControl 'no-store, max-age=0'
    Assert-LiveFeedContains -FeedKey $release.FeedKey -AssetName $release.AssetName -ExpectedUrl $assetUrl
    Update-GitHubFeedMirror -FeedKey $release.FeedKey -JsonText $feedJson -Release $release

    Write-Host "`nPUBLISHED: $($release.Product) $($release.Version)" -ForegroundColor Green
    Write-Host "Asset: $assetUrl"
    Write-Host "Feed:  $PublicBaseUrl/$($release.FeedKey)"
}
finally {
    if ($Script:WorkRoot -and (Test-Path -LiteralPath $Script:WorkRoot) -and -not $KeepWork) {
        Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
