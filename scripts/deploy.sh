#!/usr/bin/env bash
# =======================================================================================
# Deploys the Session 8 App Service performance lab.
#
# Usage:
#   ./scripts/deploy.sh -g rg-perflab-demo -l eastus [-s B1] [-m Baseline] [-p perflab]
# =======================================================================================
set -euo pipefail

RESOURCE_GROUP=""
LOCATION=""
SKU="B1"
MODE="Baseline"
NAME_PREFIX="perflab"
SUBSCRIPTION=""
VALIDATE_ONLY=0

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy.sh -g <resource-group> -l <location> [options]

  -g  Resource group name (created if missing)   [required]
  -l  Azure region, for example eastus           [required]
  -s  App Service Plan SKU: B1 | B2 | S1 | P0v3  (default B1)
  -m  Starting lab mode: Baseline | Optimized    (default Baseline)
  -p  Resource name prefix                       (default perflab)
  -u  Subscription id to use
  -v  Validate only: run template validation and a what-if preview, then stop.
      Resource groups are not billed, so this costs nothing.
EOF
}

while getopts "g:l:s:m:p:u:vh" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    s) SKU="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    p) NAME_PREFIX="$OPTARG" ;;
    u) SUBSCRIPTION="$OPTARG" ;;
    v) VALIDATE_ONLY=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$LOCATION" ]]; then
  usage
  exit 2
fi

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) not found on PATH." >&2; exit 1; }
command -v dotnet >/dev/null 2>&1 || { echo ".NET SDK (dotnet) not found on PATH." >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$REPO_ROOT/artifacts"

if [[ -n "$SUBSCRIPTION" ]]; then
  az account set --subscription "$SUBSCRIPTION"
fi

echo "== Session 8 lab deployment =="
az account show --query "{subscription:name, id:id}" -o tsv
echo "Resource group: $RESOURCE_GROUP"
echo "Location      : $LOCATION"
echo "Plan SKU      : $SKU"
echo "Starting mode : $MODE"
echo

echo "-> Creating resource group"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" \
  --tags workload=appservice-performance-lab purpose=training lifecycle=temporary -o none

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
  echo "-> Validating template against Azure (no billable resource is created)"
  az deployment group validate \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$REPO_ROOT/infra/main.bicep" \
    --parameters "$REPO_ROOT/infra/main.parameters.json" \
    --parameters namePrefix="$NAME_PREFIX" appServicePlanSku="$SKU" labMode="$MODE" \
    -o none
  echo "   Template is valid."

  echo "-> What-if preview of the resources that would be created"
  az deployment group what-if \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$REPO_ROOT/infra/main.bicep" \
    --parameters "$REPO_ROOT/infra/main.parameters.json" \
    --parameters namePrefix="$NAME_PREFIX" appServicePlanSku="$SKU" labMode="$MODE"

  echo
  echo "== Validation complete. Nothing billable was created. =="
  echo "Remove the empty resource group with: az group delete --name $RESOURCE_GROUP --yes"
  exit 0
fi

echo "-> Deploying infrastructure (Bicep)"
DEPLOYMENT_NAME="perflab-$(date +%Y%m%d%H%M%S)"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --template-file "$REPO_ROOT/infra/main.bicep" \
  --parameters "$REPO_ROOT/infra/main.parameters.json" \
  --parameters namePrefix="$NAME_PREFIX" appServicePlanSku="$SKU" labMode="$MODE" \
  -o none

WEBAPP_NAME=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query properties.outputs.webAppName.value -o tsv)
WEBAPP_URL=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query properties.outputs.webAppUrl.value -o tsv)

echo "-> Publishing application"
rm -rf "$ARTIFACTS"
mkdir -p "$ARTIFACTS/publish"
dotnet publish "$REPO_ROOT/src/PerfLab.Api/PerfLab.Api.csproj" -c Release -o "$ARTIFACTS/publish" --nologo >/dev/null

echo "-> Creating zip package"
(cd "$ARTIFACTS/publish" && zip -q -r "$ARTIFACTS/app.zip" .)

echo "-> Deploying package to $WEBAPP_NAME"
az webapp deploy --resource-group "$RESOURCE_GROUP" --name "$WEBAPP_NAME" --src-path "$ARTIFACTS/app.zip" --type zip -o none

echo "-> Waiting for the site to respond on /health"
HEALTHY=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 20 "$WEBAPP_URL/health" >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 10
done

echo
if [[ "$HEALTHY" -ne 1 ]]; then
  echo "WARNING: the site has not returned a healthy response yet. Cold start can take a couple of minutes."
else
  echo "== Deployment complete =="
  echo "Site URL : $WEBAPP_URL"
  echo "Lab config:"
  curl -fsS "$WEBAPP_URL/api/lab/config"
  echo
fi

cat <<EOF

Next steps:
  1. Baseline run : ./scripts/run-load.sh -u $WEBAPP_URL -l before
  2. Investigate  : docs/participant-lab.md
  3. Remediate    : ./scripts/set-mode.sh -g $RESOURCE_GROUP -m Optimized
  4. Proof run    : ./scripts/run-load.sh -u $WEBAPP_URL -l after
  5. Clean up     : ./scripts/cleanup.sh -g $RESOURCE_GROUP
EOF
