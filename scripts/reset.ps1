#Requires -Version 7.0

<#
.SYNOPSIS
    Resets the lab to its starting state without redeploying infrastructure.

.DESCRIPTION
    Returns the app to Baseline mode, restarts it so in-memory caches are cleared, and
    optionally deletes local load-test result files. Use this between two deliveries of
    the session on the same day.

.EXAMPLE
    ./scripts/reset.ps1 -ResourceGroup rg-perflab-demo
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [string]$WebAppName,
    [switch]$KeepResults
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $WebAppName) {
    $WebAppName = az webapp list --resource-group $ResourceGroup --query "[0].name" -o tsv
    if (-not $WebAppName) { throw "No web app was found in resource group '$ResourceGroup'." }
}

Write-Host '-> Returning the app to Baseline mode' -ForegroundColor Yellow
& (Join-Path $PSScriptRoot 'set-mode.ps1') -ResourceGroup $ResourceGroup -Mode Baseline -WebAppName $WebAppName

Write-Host '-> Restarting the app to clear in-memory state' -ForegroundColor Yellow
az webapp restart --resource-group $ResourceGroup --name $WebAppName -o none

if (-not $KeepResults) {
    $results = Join-Path $repoRoot 'results'
    if (Test-Path $results) {
        Remove-Item $results -Recurse -Force
        Write-Host '-> Removed local results folder'
    }
}

Write-Host ''
Write-Host '== Lab reset ==' -ForegroundColor Green
Write-Host 'Telemetry already ingested into Application Insights is not deleted. When you'
Write-Host 'repeat the session, scope the portal views to the new time range instead.'
