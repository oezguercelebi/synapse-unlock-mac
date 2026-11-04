#!/usr/bin/env bash
# Quit Razer.app, stop the mirror, and optionally relaunch stock Razer Synapse.
# A loaded login agent is unloaded first (launchctl bootout stops its mirror), or launchd (KeepAlive) would restart
# the mirror. Then the manual mirror from this repo, if any, is stopped.
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
  echo "Login agent unloaded; its mirror stopped with it."
fi
if pid="$(agent_server_pid)"; then
  echo "Stopping a leftover mirror of the installed copy (pid $pid)."
  kill_server_pid "$pid"
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
  if [[ -e "$INSTALL_DIR" ]]; then
    install_remove
    echo "Removed the installed copy $INSTALL_DIR."
  fi
elif agent_enabled; then
  echo "Start at login is still enabled ($AGENT_PLIST): the mirror and Razer.app come back at the next login"
  echo "or with ./launch.sh. Turn it off with ./disable-login.sh (or ./stop.sh --disable-login)."
fi
