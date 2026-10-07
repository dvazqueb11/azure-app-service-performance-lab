#!/usr/bin/env bash
# =======================================================================================
# Resets the lab to its starting state without redeploying infrastructure.
#
# Usage:
#   ./scripts/reset.sh -g rg-perflab-demo [-k]      (-k keeps local result files)
# =======================================================================================
set -euo pipefail

RESOURCE_GROUP=""
WEBAPP_NAME=""
KEEP_RESULTS=0

usage() {
  cat <<'EOF'
Usage: ./scripts/reset.sh -g <resource-group> [-n <web-app-name>] [-k]
  -k  Keep the local results/ folder
EOF
}

while getopts "g:n:kh" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    n) WEBAPP_NAME="$OPTARG" ;;
    k) KEEP_RESULTS=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" ]]; then usage; exit 2; fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "$WEBAPP_NAME" ]]; then
  WEBAPP_NAME=$(az webapp list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
fi
if [[ -z "$WEBAPP_NAME" ]]; then
  echo "No web app found in resource group $RESOURCE_GROUP." >&2
  exit 1
fi

echo "-> Returning the app to Baseline mode"
"$REPO_ROOT/scripts/set-mode.sh" -g "$RESOURCE_GROUP" -m Baseline -n "$WEBAPP_NAME"

echo "-> Restarting the app to clear in-memory state"
az webapp restart --resource-group "$RESOURCE_GROUP" --name "$WEBAPP_NAME" -o none

if [[ "$KEEP_RESULTS" -ne 1 && -d "$REPO_ROOT/results" ]]; then
  rm -rf "$REPO_ROOT/results"
  echo "-> Removed local results folder"
fi

echo
echo "== Lab reset =="
echo "Telemetry already ingested into Application Insights is not deleted. When you repeat"
echo "the session, scope the portal views to the new time range instead."
