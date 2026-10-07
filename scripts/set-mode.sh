#!/usr/bin/env bash
# =======================================================================================
# Switches the lab application between Baseline (defect) and Optimized (remediated).
#
# Usage:
#   ./scripts/set-mode.sh -g rg-perflab-demo -m Optimized
# =======================================================================================
set -euo pipefail

RESOURCE_GROUP=""
MODE=""
WEBAPP_NAME=""

usage() {
  cat <<'EOF'
Usage: ./scripts/set-mode.sh -g <resource-group> -m <Baseline|Optimized> [-n <web-app-name>]
EOF
}

while getopts "g:m:n:h" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    n) WEBAPP_NAME="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$MODE" ]]; then usage; exit 2; fi
if [[ "$MODE" != "Baseline" && "$MODE" != "Optimized" ]]; then
  echo "Mode must be Baseline or Optimized." >&2
  exit 2
fi

if [[ -z "$WEBAPP_NAME" ]]; then
  WEBAPP_NAME=$(az webapp list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
fi
if [[ -z "$WEBAPP_NAME" ]]; then
  echo "No web app found in resource group $RESOURCE_GROUP." >&2
  exit 1
fi

URL="https://$(az webapp show --resource-group "$RESOURCE_GROUP" --name "$WEBAPP_NAME" --query defaultHostName -o tsv)"

echo "-> Setting Lab__Mode=$MODE on $WEBAPP_NAME"
az webapp config appsettings set --resource-group "$RESOURCE_GROUP" --name "$WEBAPP_NAME" --settings "Lab__Mode=$MODE" -o none

echo "-> Waiting for the app to restart and report the new mode"
REPORTED=""
for _ in $(seq 1 30); do
  sleep 5
  REPORTED=$(curl -fsS --max-time 20 "$URL/api/lab/config" 2>/dev/null | sed -n 's/.*"mode":"\([^"]*\)".*/\1/p' || true)
  if [[ "$REPORTED" == "$MODE" ]]; then
    break
  fi
done

if [[ "$REPORTED" != "$MODE" ]]; then
  echo "The app did not report mode $MODE in time (last value: '${REPORTED:-none}'). Check $URL/api/lab/config." >&2
  exit 1
fi

echo "== Mode is now $MODE =="
echo "Site URL: $URL"
echo "Allow 30-60 seconds of warm-up before the measurement run so cold start is not included."
