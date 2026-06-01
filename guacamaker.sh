#!/usr/bin/env bash
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_CONF="$SCRIPT_DIR/env.conf"
MAPPING_LIST="$SCRIPT_DIR/mapping.list"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required command not found: $cmd" >&2
    exit 1
  fi
done

if [[ ! -f "$ENV_CONF" ]]; then
  echo "[ERROR] env.conf not found at: $ENV_CONF" >&2
  exit 1
fi
if [[ ! -f "$MAPPING_LIST" ]]; then
  echo "[ERROR] mapping.list not found at: $MAPPING_LIST" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_CONF"

GUAC_DATA_SOURCE="${GUAC_DATA_SOURCE:-mysql}"

for var in GUAC_API_URL GUAC_ADMIN_USER GUAC_ADMIN_PASS; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] $var is not set in env.conf" >&2
    exit 1
  fi
done

TOKEN=""
DATA_SOURCE=""
