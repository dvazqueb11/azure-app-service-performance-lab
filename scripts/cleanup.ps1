#Requires -Version 7.0

<#
.SYNOPSIS
    Deletes the entire lab by deleting its resource group.

.DESCRIPTION
    Every lab resource lives in one disposable resource group, so deleting that group
    removes all billable resources. The script shows what will be deleted and asks for
    confirmation unless -Force is supplied.

.EXAMPLE
    ./scripts/cleanup.ps1 -ResourceGroup rg-perflab-demo

.EXAMPLE
    ./scripts/cleanup.ps1 -ResourceGroup rg-perflab-demo -Force -NoWait
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [switch]$Force,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$exists = az group exists --name $ResourceGroup -o tsv
if ($exists -ne 'true') {
    Write-Host "Resource group '$ResourceGroup' does not exist. Nothing to clean up." -ForegroundColor Green
    return
}

$account = az account show -o json | ConvertFrom-Json
Write-Host ("Subscription  : {0} ({1})" -f $account.name, $account.id)
Write-Host ("Resource group: {0}" -f $ResourceGroup)
Write-Host 'Resources that will be deleted:' -ForegroundColor Yellow
az resource list --resource-group $ResourceGroup --query "[].{name:name, type:type}" -o table

if (-not $Force) {
    $answer = Read-Host "Type the resource group name to confirm deletion"
    if ($answer -ne $ResourceGroup) {
        Write-Host 'Confirmation did not match. Nothing was deleted.' -ForegroundColor Red
        return
    }
}

Write-Host '-> Deleting resource group' -ForegroundColor Yellow
if ($NoWait) {
    az group delete --name $ResourceGroup --yes --no-wait -o none
    Write-Host '== Deletion started in the background ==' -ForegroundColor Green
    Write-Host ("Check progress with: az group exists --name {0}" -f $ResourceGroup)
}
else {
    az group delete --name $ResourceGroup --yes -o none
    Write-Host '== Lab removed ==' -ForegroundColor Green
}
