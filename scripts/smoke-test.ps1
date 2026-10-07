#Requires -Version 7.0

<#
.SYNOPSIS
    Validates the lab application locally, with no Azure resources.

.DESCRIPTION
    Starts the API twice - once in Baseline mode and once in Optimized mode - and asserts
    the behaviour the lab depends on:

      * /health responds quickly and reveals nothing about configuration
      * /api/products stays fast in both modes (the healthy control endpoint)
      * Baseline  /api/orders is slow and makes one catalog call per order
      * Optimized /api/orders is materially faster and makes at most one catalog call
      * Both modes return identical order data

    This script runs in GitHub Actions and is also the fastest way for an instructor to
    confirm the lab still behaves correctly before a delivery.

.EXAMPLE
    pwsh ./scripts/smoke-test.ps1
#>
[CmdletBinding()]
param(
    [int]$BaselinePort = 5241,
    [int]$OptimizedPort = 5242,
    [int]$OrderCount = 25,
    [int]$SimulatedLatencyMs = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repoRoot 'src/PerfLab.Api/PerfLab.Api.csproj'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "  PASS  $Message" -ForegroundColor Green
    }
    else {
        Write-Host "  FAIL  $Message" -ForegroundColor Red
        $script:failures.Add($Message)
    }
}

function Open-LabApi {
    param([string]$Mode, [int]$Port)

    $env:Lab__Mode = $Mode
    $env:Lab__OrderCount = "$OrderCount"
    $env:Lab__SimulatedLatencyMs = "$SimulatedLatencyMs"
    $env:ASPNETCORE_URLS = "http://127.0.0.1:$Port"
    $env:APPLICATIONINSIGHTS_CONNECTION_STRING = ''

    $process = Start-Process -FilePath 'dotnet' `
        -ArgumentList @('run', '--project', "`"$project`"", '-c', 'Release', '--no-build', '--nologo') `
        -PassThru -NoNewWindow

    for ($i = 1; $i -le 40; $i++) {
        Start-Sleep -Milliseconds 750
        try {
            $null = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 5
            return $process
        }
        catch {
            if ($process.HasExited) { throw "The API exited while starting in $Mode mode." }
        }
    }

    throw "The API did not become healthy in $Mode mode."
}

function Close-LabApi {
    param($Process)
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
        $Process.WaitForExit(10000) | Out-Null
    }
}

function Measure-Endpoint {
    param([int]$Port, [string]$Path)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-WebRequest "http://127.0.0.1:$Port$Path" -UseBasicParsing -TimeoutSec 60
    $sw.Stop()
    return [pscustomobject]@{
        ElapsedMs    = $sw.Elapsed.TotalMilliseconds
        Content      = $response.Content
        Mode         = if ($response.Headers.ContainsKey('x-lab-mode')) { [string]@($response.Headers['x-lab-mode'])[0] } else { $null }
        CatalogCalls = if ($response.Headers.ContainsKey('x-lab-catalog-calls')) { [int]@($response.Headers['x-lab-catalog-calls'])[0] } else { -1 }
    }
}

Write-Host '== Building ==' -ForegroundColor Cyan
dotnet build (Join-Path $repoRoot 'PerfLab.slnx') -c Release --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

$baselineProcess = $null
$optimizedProcess = $null
$expectedMinimumBaselineMs = $OrderCount * $SimulatedLatencyMs * 0.7

try {
    Write-Host ''
    Write-Host '== Baseline mode ==' -ForegroundColor Cyan
    $baselineProcess = Open-LabApi -Mode 'Baseline' -Port $BaselinePort

    $health = Measure-Endpoint -Port $BaselinePort -Path '/health'
    Assert-Condition ($health.Content -match '"status"\s*:\s*"Healthy"') '/health reports Healthy'
    Assert-Condition ($health.ElapsedMs -lt 1000) ('/health responds quickly ({0} ms)' -f [int]$health.ElapsedMs)
    Assert-Condition ($health.Content -notmatch 'mode|connection|Lab') '/health does not disclose configuration'

    $products = Measure-Endpoint -Port $BaselinePort -Path '/api/products'
    Assert-Condition ($products.ElapsedMs -lt 1000) ('/api/products is fast in Baseline ({0} ms)' -f [int]$products.ElapsedMs)

    $baselineOrders = Measure-Endpoint -Port $BaselinePort -Path '/api/orders'
    Assert-Condition ($baselineOrders.Mode -eq 'Baseline') '/api/orders reports Baseline mode'
    Assert-Condition ($baselineOrders.CatalogCalls -eq $OrderCount) ('Baseline makes one catalog call per order ({0})' -f $baselineOrders.CatalogCalls)
    Assert-Condition ($baselineOrders.ElapsedMs -ge $expectedMinimumBaselineMs) ('Baseline /api/orders is slow ({0} ms)' -f [int]$baselineOrders.ElapsedMs)

    $badRequest = $null
    try {
        Invoke-WebRequest "http://127.0.0.1:$BaselinePort/api/orders?count=9999" -UseBasicParsing -TimeoutSec 30 | Out-Null
    }
    catch {
        $badRequest = $_.Exception.Response.StatusCode.value__
    }
    Assert-Condition ($badRequest -eq 400) 'An out-of-range count is rejected with HTTP 400'

    Close-LabApi -Process $baselineProcess
    $baselineProcess = $null

    Write-Host ''
    Write-Host '== Optimized mode ==' -ForegroundColor Cyan
    $optimizedProcess = Open-LabApi -Mode 'Optimized' -Port $OptimizedPort

    $firstOptimized = Measure-Endpoint -Port $OptimizedPort -Path '/api/orders'
    $secondOptimized = Measure-Endpoint -Port $OptimizedPort -Path '/api/orders'

    Assert-Condition ($firstOptimized.Mode -eq 'Optimized') '/api/orders reports Optimized mode'
    Assert-Condition ($firstOptimized.CatalogCalls -le 1) ('Optimized makes at most one catalog call ({0})' -f $firstOptimized.CatalogCalls)
    Assert-Condition ($secondOptimized.CatalogCalls -eq 0) 'A cached Optimized request makes no catalog call'
    Assert-Condition ($secondOptimized.ElapsedMs -lt ($baselineOrders.ElapsedMs / 5)) (
        'Optimized is at least 5x faster than Baseline ({0} ms vs {1} ms)' -f [int]$secondOptimized.ElapsedMs, [int]$baselineOrders.ElapsedMs)

    $baselineOrderIds = ([regex]::Matches($baselineOrders.Content, '"orderId":(\d+)') | ForEach-Object { $_.Groups[1].Value }) -join ','
    $optimizedOrderIds = ([regex]::Matches($secondOptimized.Content, '"orderId":(\d+)') | ForEach-Object { $_.Groups[1].Value }) -join ','
    Assert-Condition ($baselineOrderIds -eq $optimizedOrderIds -and $baselineOrderIds.Length -gt 0) 'Both modes return the same orders'

    $optimizedProducts = Measure-Endpoint -Port $OptimizedPort -Path '/api/products'
    Assert-Condition ($optimizedProducts.ElapsedMs -lt 1000) ('/api/products is fast in Optimized ({0} ms)' -f [int]$optimizedProducts.ElapsedMs)
}
finally {
    Close-LabApi -Process $baselineProcess
    Close-LabApi -Process $optimizedProcess
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("== {0} check(s) failed ==" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host '== All lab behaviour checks passed ==' -ForegroundColor Green
