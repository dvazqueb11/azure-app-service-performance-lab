#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys the Session 8 App Service performance lab.

.DESCRIPTION
    Creates one disposable resource group, deploys the Bicep template, publishes the
    ASP.NET Core application and pushes it to Azure App Service as a zip package.
    The app starts in Baseline mode, which is the state the lab investigation begins in.

.EXAMPLE
    ./scripts/deploy.ps1 -ResourceGroup rg-perflab-demo -Location eastus

.EXAMPLE
    ./scripts/deploy.ps1 -ResourceGroup rg-perflab-demo -Location westeurope -Sku S1

.EXAMPLE
    # Validate the template against Azure without creating any billable resource.
    # Only an (unbilled) resource group is created, so this is safe to run any time.
    ./scripts/deploy.ps1 -ResourceGroup rg-perflab-demo -Location eastus -ValidateOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$Location,
    [ValidateSet('B1', 'B2', 'S1', 'P0v3')][string]$Sku = 'B1',
    [ValidateSet('Baseline', 'Optimized')][string]$Mode = 'Baseline',
    [string]$NamePrefix = 'perflab',
    [string]$SubscriptionId,

    # Runs template validation and a what-if preview, then stops before deploying.
    # Resource groups are not billed, so this costs nothing.
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $repoRoot 'artifacts'

Write-Host '== Session 8 lab deployment ==' -ForegroundColor Cyan

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) was not found on PATH.' }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET SDK (dotnet) was not found on PATH.' }

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
}

$account = az account show -o json | ConvertFrom-Json
Write-Host ("Subscription : {0} ({1})" -f $account.name, $account.id)
Write-Host ("Resource group: {0}" -f $ResourceGroup)
Write-Host ("Location      : {0}" -f $Location)
Write-Host ("Plan SKU      : {0}" -f $Sku)
Write-Host ("Starting mode : {0}" -f $Mode)
Write-Host ''

Write-Host '-> Creating resource group' -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --tags workload=appservice-performance-lab purpose=training lifecycle=temporary -o none

$templateFile = Join-Path $repoRoot 'infra/main.bicep'
$parametersFile = Join-Path $repoRoot 'infra/main.parameters.json'

if ($ValidateOnly) {
    Write-Host '-> Validating template against Azure (no billable resource is created)' -ForegroundColor Yellow
    az deployment group validate `
        --resource-group $ResourceGroup `
        --template-file $templateFile `
        --parameters $parametersFile `
        --parameters namePrefix=$NamePrefix appServicePlanSku=$Sku labMode=$Mode `
        -o none
    if ($LASTEXITCODE -ne 0) { throw 'Template validation failed.' }
    Write-Host '   Template is valid.' -ForegroundColor Green

    Write-Host '-> What-if preview of the resources that would be created' -ForegroundColor Yellow
    az deployment group what-if `
        --resource-group $ResourceGroup `
        --template-file $templateFile `
        --parameters $parametersFile `
        --parameters namePrefix=$NamePrefix appServicePlanSku=$Sku labMode=$Mode

    Write-Host ''
    Write-Host '== Validation complete. Nothing billable was created. ==' -ForegroundColor Green
    Write-Host ("Remove the empty resource group with: az group delete --name {0} --yes" -f $ResourceGroup)
    return
}

Write-Host '-> Deploying infrastructure (Bicep)' -ForegroundColor Yellow
$deploymentName = "perflab-$(Get-Date -Format 'yyyyMMddHHmmss')"
az deployment group create `
    --resource-group $ResourceGroup `
    --name $deploymentName `
    --template-file $templateFile `
    --parameters $parametersFile `
    --parameters namePrefix=$NamePrefix appServicePlanSku=$Sku labMode=$Mode `
    -o none
if ($LASTEXITCODE -ne 0) { throw 'Infrastructure deployment failed.' }

$outputs = az deployment group show --resource-group $ResourceGroup --name $deploymentName --query properties.outputs -o json | ConvertFrom-Json
$webAppName = $outputs.webAppName.value
$webAppUrl = $outputs.webAppUrl.value

Write-Host "-> Publishing application" -ForegroundColor Yellow
if (Test-Path $artifacts) { Remove-Item $artifacts -Recurse -Force }
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
$publishDir = Join-Path $artifacts 'publish'
dotnet publish (Join-Path $repoRoot 'src/PerfLab.Api/PerfLab.Api.csproj') -c Release -o $publishDir --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }

$zipPath = Join-Path $artifacts 'app.zip'
Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zipPath -Force

Write-Host "-> Deploying package to $webAppName" -ForegroundColor Yellow
az webapp deploy --resource-group $ResourceGroup --name $webAppName --src-path $zipPath --type zip -o none

Write-Host '-> Waiting for the site to respond on /health' -ForegroundColor Yellow
$healthy = $false
for ($i = 1; $i -le 30; $i++) {
    try {
        $response = Invoke-WebRequest -Uri "$webAppUrl/health" -UseBasicParsing -TimeoutSec 20
        if ($response.StatusCode -eq 200) { $healthy = $true; break }
    }
    catch {
        Start-Sleep -Seconds 10
    }
}

Write-Host ''
if (-not $healthy) {
    Write-Warning "The site did not return a healthy response yet. Cold start can take a couple of minutes; retry $webAppUrl/health manually."
}
else {
    $config = Invoke-RestMethod -Uri "$webAppUrl/api/lab/config" -TimeoutSec 30
    Write-Host '== Deployment complete ==' -ForegroundColor Green
    Write-Host ("Site URL   : {0}" -f $webAppUrl)
    Write-Host ("Lab mode   : {0}" -f $config.mode)
    Write-Host ("Telemetry  : {0}" -f $(if ($config.telemetryEnabled) { 'Application Insights connected' } else { 'NOT connected' }))
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host ("  1. Baseline run : ./scripts/run-load.ps1 -Url {0} -Label before" -f $webAppUrl)
Write-Host '  2. Investigate  : docs/participant-lab.md'
Write-Host ("  3. Remediate    : ./scripts/set-mode.ps1 -ResourceGroup {0} -Mode Optimized" -f $ResourceGroup)
Write-Host ("  4. Proof run    : ./scripts/run-load.ps1 -Url {0} -Label after" -f $webAppUrl)
Write-Host ("  5. Clean up     : ./scripts/cleanup.ps1 -ResourceGroup {0}" -f $ResourceGroup)
