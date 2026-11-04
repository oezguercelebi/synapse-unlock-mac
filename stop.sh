#!/usr/bin/env bash
# Quit Razer.app, stop the mirror server, and optionally relaunch stock Razer Synapse.
# Usage: ./stop.sh [--stock]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

RELAUNCH=0
for a in "$@"; do
  case "$a" in
    --stock|--relaunch-stock) RELAUNCH=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

quit_razer_app
stop_server

if [[ "$RELAUNCH" == 1 ]]; then
  echo "Relaunching stock Razer Synapse ($STOCK_LAUNCHER)..."
  open -a "$STOCK_LAUNCHER"
else
  echo "Stock Synapse not relaunched (use --stock, or open \"$STOCK_LAUNCHER\")."
fi
