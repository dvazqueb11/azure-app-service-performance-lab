#!/usr/bin/env bash
# =======================================================================================
# Deletes the entire lab by deleting its resource group.
#
# Usage:
#   ./scripts/cleanup.sh -g rg-perflab-demo [-f] [-w]
#     -f  Skip the confirmation prompt
#     -w  Do not wait for deletion to finish
# =======================================================================================
set -euo pipefail

RESOURCE_GROUP=""
FORCE=0
NO_WAIT=0

usage() {
  cat <<'EOF'
Usage: ./scripts/cleanup.sh -g <resource-group> [-f] [-w]
EOF
}

while getopts "g:fwh" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    f) FORCE=1 ;;
    w) NO_WAIT=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" ]]; then usage; exit 2; fi

if [[ "$(az group exists --name "$RESOURCE_GROUP" -o tsv)" != "true" ]]; then
  echo "Resource group '$RESOURCE_GROUP' does not exist. Nothing to clean up."
  exit 0
fi

az account show --query "{subscription:name, id:id}" -o tsv
echo "Resource group: $RESOURCE_GROUP"
echo "Resources that will be deleted:"
az resource list --resource-group "$RESOURCE_GROUP" --query "[].{name:name, type:type}" -o table

if [[ "$FORCE" -ne 1 ]]; then
  read -r -p "Type the resource group name to confirm deletion: " ANSWER
  if [[ "$ANSWER" != "$RESOURCE_GROUP" ]]; then
    echo "Confirmation did not match. Nothing was deleted."
    exit 1
  fi
fi

echo "-> Deleting resource group"
if [[ "$NO_WAIT" -eq 1 ]]; then
  az group delete --name "$RESOURCE_GROUP" --yes --no-wait -o none
  echo "== Deletion started in the background =="
  echo "Check progress with: az group exists --name $RESOURCE_GROUP"
else
  az group delete --name "$RESOURCE_GROUP" --yes -o none
  echo "== Lab removed =="
fi
