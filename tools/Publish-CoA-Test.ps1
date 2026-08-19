#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Ref = 'refs/heads/agent/beta21-naowh-coa-test',
    [switch]$PushGitHubMirror,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([string]::IsNullOrWhiteSpace($Ref)) {
    throw 'A GitHub branch/ref is required.'
}

if ($Ref -eq 'main' -or $Ref -eq 'refs/heads/main') {
    throw 'Publish-CoA-Test.ps1 is for prerelease branches only. Use Publish-R2-Live.ps1 for main/stable releases.'
}

$publisher = Join-Path $PSScriptRoot 'Publish-R2-Live.ps1'
if (-not (Test-Path -LiteralPath $publisher -PathType Leaf)) {
    throw "R2 publisher not found: $publisher"
}

Write-Host "Publishing CoA TEST build from ref '$Ref'" -ForegroundColor Cyan
Write-Host 'The source release manifest must remain publish=true and prerelease=true.' -ForegroundColor Yellow

$publishParams = @{
    Product = 'CoA'
    Ref = $Ref
}
if ($PushGitHubMirror) { $publishParams.PushGitHubMirror = $true }
if ($KeepWork) { $publishParams.KeepWork = $true }

& $publisher @publishParams
if (-not $?) {
    throw 'CoA test publish failed.'
}

Write-Host "CoA test publish completed for '$Ref'. Enable Beta in RetreatUI Launcher to select the prerelease." -ForegroundColor Green
