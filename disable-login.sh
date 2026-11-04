#!/usr/bin/env bash
# Turn start at login off: unload the LaunchAgent, remove its plist and the installed copy in
# ~/Library/Application Support/synapse-unlock-mac (with its certs/ and logs/). Idempotent.
# Razer.app is left alone. If the agent was running the mirror, a manual mirror from this repo takes over (as after
# launch.sh), so a running Razer.app keeps working; ./stop.sh stops both.
# Usage: ./disable-login.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for a in "$@"; do echo "unknown argument: $a" >&2; exit 2; done
if [[ "$ROOT" == "$INSTALL_DIR" ]]; then echo "Run disable-login.sh from the repo; $INSTALL_DIR is the installed copy." >&2; exit 2; fi

restart=0
if agent_loaded; then
  agent_server_pid >/dev/null && restart=1
  echo "Unloading the login agent ($AGENT_DOMAIN/$AGENT_LABEL); its mirror stops with it..."
  agent_bootout
  echo "Login agent unloaded."
else
  echo "Login agent is not loaded."
fi
if pid="$(agent_server_pid)"; then
  echo "Stopping a leftover mirror of the installed copy (pid $pid)."
  kill_server_pid "$pid"
  restart=1
fi
if agent_enabled; then
  rm -f "$AGENT_PLIST"
  echo "Removed $AGENT_PLIST; nothing starts at login any more."
else
  echo "No plist at $AGENT_PLIST; start at login was already off."
fi
if [[ -e "$INSTALL_DIR" ]]; then
  install_remove
  echo "Removed the installed copy $INSTALL_DIR."
fi

if [[ "$restart" == 1 ]]; then
  echo "Handing the mirror back to a manual mirror from this repo, so Razer Synapse stays served."
  start_server
  if ! wait_for_mirror "$SERVER_CHILD"; then
    echo "ERROR: the manual mirror did not come up ($(mirror_missing || true)). Last server output:" >&2
    tail -n 20 "$SERVER_OUT" >&2 || true
    exit 1
  fi
  echo "Manual mirror is up (pid $SERVER_CHILD, logs in $LOG_DIR); ./stop.sh stops it, ./stop.sh --stock reverts."
  warn_mirror_errors
fi
line="$(razer_main_line)"
if [[ -n "$line" ]]; then
  echo "Left alone: Razer.app (running, pid ${line%% *})."
else
  echo "Left alone: Razer.app (not running)."
fi
