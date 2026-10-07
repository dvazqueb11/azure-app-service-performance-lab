// =======================================================================================
// Session 8 - Diagnose and Remediate Azure App Service Performance Issues
//
// Deploys the smallest set of resources that supports the lab:
//   1. Log Analytics workspace   (required by workspace-based Application Insights)
//   2. Application Insights      (request, dependency, trace and exception correlation)
//   3. Linux App Service Plan    (one instance, no autoscale)
//   4. Linux App Service         (the lab application)
//
// Everything is created inside one disposable resource group so the entire lab is
// removed by deleting that single resource group.
// =======================================================================================

targetScope = 'resourceGroup'

@description('Azure region for all lab resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Short lowercase prefix used in resource names. Letters and digits only.')
@minLength(3)
@maxLength(11)
param namePrefix string = 'perflab'

@description('''App Service Plan SKU.
B1  - lowest-cost tier that still supports Always On, health check and a dedicated (non-shared) CPU. Default.
B2  - more headroom if the room runs the load generator from many laptops at once.
S1  - instructor option: dedicated tier with deployment slots, useful for a smoother live demo.
P0v3 - instructor option: most consistent response times, highest cost. Use only for a recorded or high-stakes delivery.''')
@allowed([
  'B1'
  'B2'
  'S1'
  'P0v3'
])
param appServicePlanSku string = 'B1'

@description('Lab mode the app starts in. The lab begins in Baseline and is remediated to Optimized.')
@allowed([
  'Baseline'
  'Optimized'
])
param labMode string = 'Baseline'

@description('Default number of orders returned by /api/orders.')
@minValue(1)
@maxValue(50)
param labOrderCount int = 25

@description('Simulated latency of one catalog lookup, in milliseconds.')
@minValue(0)
@maxValue(500)
param labSimulatedLatencyMs int = 60

@description('OpenTelemetry sampling ratio sent to Azure Monitor, between 0.0 and 1.0. 1.0 keeps every trace, which is what makes the lab easy to read. Lower it to reduce ingestion cost on longer runs.')
@allowed([
  '1.0'
  '0.5'
  '0.25'
  '0.1'
])
param telemetrySamplingRatio string = '1.0'

@description('Log Analytics retention in days. 30 days is the minimum billed-free retention period.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@description('Daily ingestion cap for the Log Analytics workspace in GB. Acts as a hard cost guardrail for a short-lived lab.')
@minValue(1)
param logDailyQuotaGb int = 1

@description('Tags applied to every resource so lab resources are easy to identify and clean up.')
param tags object = {
  workload: 'appservice-performance-lab'
  purpose: 'training'
  lifecycle: 'temporary'
}

var suffix = uniqueString(resourceGroup().id)
var workspaceName = 'log-${namePrefix}-${suffix}'
var appInsightsName = 'appi-${namePrefix}-${suffix}'
var planName = 'plan-${namePrefix}-${suffix}'
var webAppName = 'app-${namePrefix}-${suffix}'

// ---------------------------------------------------------------------------------------
// Log Analytics workspace
// ---------------------------------------------------------------------------------------
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
    workspaceCapping: {
      dailyQuotaGb: logDailyQuotaGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------------------
// Application Insights (workspace-based, the only supported model for new resources)
// ---------------------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    DisableLocalAuth: false
  }
}

// ---------------------------------------------------------------------------------------
// Linux App Service Plan - a single instance, no autoscale rules.
// Autoscale is deliberately omitted: the lesson must not depend on a scale event
// happening inside the session window.
// ---------------------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: appServicePlanSku
  }
  kind: 'linux'
  properties: {
    reserved: true
    targetWorkerCount: 1
    zoneRedundant: false
  }
}

// ---------------------------------------------------------------------------------------
// Linux App Service
// ---------------------------------------------------------------------------------------
resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      alwaysOn: true
      http20Enabled: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      numberOfWorkers: 1
      healthCheckPath: '/health'
      httpLoggingEnabled: true
      detailedErrorLoggingEnabled: false
      use32BitWorkerProcess: false
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'Telemetry__SamplingRatio'
          value: telemetrySamplingRatio
        }
        {
          name: 'Lab__Mode'
          value: labMode
        }
        {
          name: 'Lab__OrderCount'
          value: string(labOrderCount)
        }
        {
          name: 'Lab__SimulatedLatencyMs'
          value: string(labSimulatedLatencyMs)
        }
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Production'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'false'
        }
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
      ]
    }
  }
}

// Platform logs for the web app, sent to the same workspace so platform and application
// evidence can be correlated in one place during the investigation.
resource webAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-workspace'
  scope: webApp
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServicePlatformLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output webAppName string = webApp.name
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output appServicePlanName string = plan.name
output appServicePlanSku string = appServicePlanSku
output appInsightsName string = appInsights.name
output logAnalyticsWorkspaceName string = workspace.name
output resourceGroupName string = resourceGroup().name
