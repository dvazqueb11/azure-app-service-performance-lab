#Requires -Version 7.0

<#
.SYNOPSIS
    Switches the lab application between Baseline (defect) and Optimized (remediated).

.DESCRIPTION
    Updates the Lab__Mode app setting on the lab web app. App Service restarts the app
    when app settings change, then the script waits until the running app reports the
    requested mode on /api/lab/config.

.EXAMPLE
    ./scripts/set-mode.ps1 -ResourceGroup rg-perflab-demo -Mode Optimized
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][ValidateSet('Baseline', 'Optimized')][string]$Mode,
    [string]$WebAppName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $WebAppName) {
    $WebAppName = az webapp list --resource-group $ResourceGroup --query "[0].name" -o tsv
    if (-not $WebAppName) { throw "No web app was found in resource group '$ResourceGroup'." }
}

$url = "https://$(az webapp show --resource-group $ResourceGroup --name $WebAppName --query defaultHostName -o tsv)"

Write-Host ("-> Setting Lab__Mode={0} on {1}" -f $Mode, $WebAppName) -ForegroundColor Yellow
az webapp config appsettings set --resource-group $ResourceGroup --name $WebAppName --settings "Lab__Mode=$Mode" -o none

Write-Host '-> Waiting for the app to restart and report the new mode' -ForegroundColor Yellow
$reported = $null
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 5
    try {
        $config = Invoke-RestMethod -Uri "$url/api/lab/config" -TimeoutSec 20
        $reported = $config.mode
        if ($reported -eq $Mode) { break }
    }
    catch {
        Write-Verbose "Waiting for the app to come back: $($_.Exception.Message)"
    }
}

if ($reported -ne $Mode) {
    throw "The app did not report mode '$Mode' in time. Last reported value: '$reported'. Check $url/api/lab/config."
}

Write-Host ("== Mode is now {0} ==" -f $Mode) -ForegroundColor Green
Write-Host ("Site URL: {0}" -f $url)
Write-Host 'Allow 30-60 seconds of warm-up before the measurement run so cold start is not included.'
