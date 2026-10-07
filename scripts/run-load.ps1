#Requires -Version 7.0

<#
.SYNOPSIS
    Runs the local load generator against the lab site and saves a JSON result file.

.DESCRIPTION
    The load is generated from this machine only. No Azure load-testing resource is
    created, so the lab adds no extra cost and nothing extra to clean up.

    The defaults (5 callers, 60 seconds, 10 second warm-up) are chosen to be heavy enough
    to make the problem obvious and light enough to stay safe on a B1 plan.

.EXAMPLE
    ./scripts/run-load.ps1 -Url https://app-perflab-abc123.azurewebsites.net -Label before

.EXAMPLE
    ./scripts/run-load.ps1 -Url https://app-perflab-abc123.azurewebsites.net -Path /api/products -Label control
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Path = '/api/orders',
    [ValidateRange(1, 20)][int]$Concurrency = 5,
    [ValidateRange(5, 600)][int]$DurationSeconds = 60,
    [ValidateRange(0, 120)][int]$WarmupSeconds = 10,
    [string]$Label = 'run',
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot "results/$Label.json"
}

dotnet run --project (Join-Path $repoRoot 'loadgen/PerfLab.LoadGen/PerfLab.LoadGen.csproj') -c Release -- `
    --url $Url `
    --path $Path `
    --concurrency $Concurrency `
    --duration $DurationSeconds `
    --warmup $WarmupSeconds `
    --label $Label `
    --out $OutputPath

if ($LASTEXITCODE -ne 0) {
    Write-Warning 'The run reported failed requests. Check the status code breakdown above.'
}

$before = Join-Path $repoRoot 'results/before.json'
$after = Join-Path $repoRoot 'results/after.json'
if ((Test-Path $before) -and (Test-Path $after)) {
    $b = Get-Content $before -Raw | ConvertFrom-Json
    $a = Get-Content $after -Raw | ConvertFrom-Json
    Write-Host ''
    Write-Host '==================== BEFORE / AFTER ====================' -ForegroundColor Cyan
    Write-Host ("  Mode        : {0,12}  ->  {1}" -f $b.Mode, $a.Mode)
    Write-Host ("  P50 (ms)    : {0,12}  ->  {1}" -f $b.P50Ms, $a.P50Ms)
    Write-Host ("  P95 (ms)    : {0,12}  ->  {1}" -f $b.P95Ms, $a.P95Ms)
    Write-Host ("  Throughput  : {0,12}  ->  {1}  req/s" -f $b.RequestsPerSecond, $a.RequestsPerSecond)
    Write-Host ("  Catalog/req : {0,12}  ->  {1}" -f $b.CatalogCallsPerRequest, $a.CatalogCallsPerRequest)
    Write-Host '========================================================' -ForegroundColor Cyan
}
