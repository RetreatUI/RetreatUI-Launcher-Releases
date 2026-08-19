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
    Ref = 'refs/heads/agent/beta23-tracker-builder-layout'
}
if ($KeepWork) { $params.KeepWork = $true }

Write-Host "Publishing RetreatUI CoA Tracker Builder beta.23 test..." -ForegroundColor Cyan
& $publisher @params
if (-not $?) { throw 'beta.23 Tracker Builder publish failed.' }
