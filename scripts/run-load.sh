#!/usr/bin/env bash
# =======================================================================================
# Runs the local load generator against the lab site and saves a JSON result file.
#
# Usage:
#   ./scripts/run-load.sh -u https://app-perflab-abc123.azurewebsites.net -l before
# =======================================================================================
set -euo pipefail

URL=""
PATH_ARG="/api/orders"
CONCURRENCY=5
DURATION=60
WARMUP=10
LABEL="run"
OUT=""

usage() {
  cat <<'EOF'
Usage: ./scripts/run-load.sh -u <site-url> [options]
  -u  Site URL                                   [required]
  -p  Path to call            (default /api/orders)
  -c  Concurrency 1-20        (default 5)
  -d  Duration seconds 5-600  (default 60)
  -w  Warm-up seconds 0-120   (default 10)
  -l  Label, e.g. before|after|control (default run)
  -o  Output JSON path        (default results/<label>.json)
EOF
}

while getopts "u:p:c:d:w:l:o:h" opt; do
  case "$opt" in
    u) URL="$OPTARG" ;;
    p) PATH_ARG="$OPTARG" ;;
    c) CONCURRENCY="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    w) WARMUP="$OPTARG" ;;
    l) LABEL="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$URL" ]]; then usage; exit 2; fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "$OUT" ]]; then
  OUT="$REPO_ROOT/results/$LABEL.json"
fi

dotnet run --project "$REPO_ROOT/loadgen/PerfLab.LoadGen/PerfLab.LoadGen.csproj" -c Release -- \
  --url "$URL" \
  --path "$PATH_ARG" \
  --concurrency "$CONCURRENCY" \
  --duration "$DURATION" \
  --warmup "$WARMUP" \
  --label "$LABEL" \
  --out "$OUT"
