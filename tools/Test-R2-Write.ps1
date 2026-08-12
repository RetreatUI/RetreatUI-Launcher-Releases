#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$AwsProfile = 'retreatui-r2',
    [string]$Bucket = 'retreatui-releases',
    [string]$EndpointUrl = 'https://f2f139a476f03851f203d52e399a8ffb.eu.r2.cloudflarestorage.com'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "    OK: $Message" -ForegroundColor Green
}

function Get-AwsCommand {
    $aws = Get-Command aws.exe -ErrorAction SilentlyContinue
    if (-not $aws) { $aws = Get-Command aws -ErrorAction SilentlyContinue }
    if (-not $aws) { throw 'AWS CLI was not found in PATH.' }
    return $aws.Source
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

$aws = Get-AwsCommand
$probeId = [Guid]::NewGuid().ToString('N')
$key = "_healthchecks/write-probe-$probeId.txt"
$tempFile = Join-Path ([IO.Path]::GetTempPath()) "RetreatUI-R2-write-probe-$probeId.txt"
$body = "RetreatUI R2 write probe $probeId`nCreated $([DateTime]::UtcNow.ToString('O'))`n"
[IO.File]::WriteAllText($tempFile, $body, (New-Object System.Text.UTF8Encoding($false)))

try {
    Write-Step "Writing isolated probe object $key"
    Invoke-Aws -Aws $aws -Arguments @(
        's3api', 'put-object',
        '--bucket', $Bucket,
        '--key', $key,
        '--body', $tempFile,
        '--content-type', 'text/plain; charset=utf-8',
        '--cache-control', 'no-store, max-age=0',
        '--profile', $AwsProfile,
        '--endpoint-url', $EndpointUrl,
        '--region', 'auto',
        '--no-cli-pager'
    )
    Write-Ok 'Probe upload succeeded'

    Write-Step 'Reading probe metadata back from R2'
    Invoke-Aws -Aws $aws -Arguments @(
        's3api', 'head-object',
        '--bucket', $Bucket,
        '--key', $key,
        '--profile', $AwsProfile,
        '--endpoint-url', $EndpointUrl,
        '--region', 'auto',
        '--no-cli-pager'
    )
    Write-Ok 'Probe read-back succeeded'

    Write-Step 'Deleting probe object again'
    Invoke-Aws -Aws $aws -Arguments @(
        's3api', 'delete-object',
        '--bucket', $Bucket,
        '--key', $key,
        '--profile', $AwsProfile,
        '--endpoint-url', $EndpointUrl,
        '--region', 'auto',
        '--no-cli-pager'
    )
    Write-Ok 'Probe deleted'

    Write-Host "`nR2 WRITE TEST PASSED" -ForegroundColor Green
    Write-Host 'Write, read and delete permissions are working. No release feed was touched.'
}
finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}
