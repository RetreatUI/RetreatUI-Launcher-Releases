#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$publisher = Join-Path $PSScriptRoot 'Publish-CoA-Test.ps1'
if (-not (Test-Path -LiteralPath $publisher -PathType Leaf)) {
    throw "CoA test publisher not found: $publisher"
}

$params = @{
    Ref = 'refs/heads/agent/beta41-authoritative-destinations'
}
if ($KeepWork) { $params.KeepWork = $true }

Write-Host "Publishing RetreatUI CoA beta.41 authoritative destination test..." -ForegroundColor Cyan
& $publisher @params
if (-not $?) { throw 'beta.41 authoritative destination test publish failed.' }
