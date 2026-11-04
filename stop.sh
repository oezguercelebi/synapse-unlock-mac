#!/usr/bin/env bash
# Quit Razer.app, stop the mirror server, and optionally relaunch stock Razer Synapse.
# A loaded login agent is unloaded first, or launchd (KeepAlive) would restart the mirror.
# Usage: ./stop.sh [--stock] [--disable-login]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

RELAUNCH=0
DISABLE_LOGIN=0
for a in "$@"; do
  case "$a" in
    --stock|--relaunch-stock) RELAUNCH=1 ;;
    --disable-login) DISABLE_LOGIN=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

if agent_loaded; then
  echo "Unloading the login agent ($AGENT_LABEL) so launchd does not restart the mirror..."
  agent_bootout
  echo "Login agent unloaded."
fi
quit_razer_app
stop_server

if [[ "$RELAUNCH" == 1 ]]; then
  echo "Relaunching stock Razer Synapse ($STOCK_LAUNCHER)..."
  open -a "$STOCK_LAUNCHER"
else
  echo "Stock Synapse not relaunched (use --stock, or open \"$STOCK_LAUNCHER\")."
fi

if [[ "$DISABLE_LOGIN" == 1 ]]; then
  if agent_enabled; then
    rm -f "$AGENT_PLIST"
    echo "Start at login disabled (removed $AGENT_PLIST)."
  else
    echo "Start at login was already off."
  fi
elif agent_enabled; then
  echo "Start at login is still enabled ($AGENT_PLIST): the mirror and Razer.app come back at the next login"
  echo "or with ./launch.sh. Turn it off with ./disable-login.sh (or ./stop.sh --disable-login)."
fi
