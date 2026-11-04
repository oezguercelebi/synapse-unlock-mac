#!/usr/bin/env bash
# Turn start at login off: unload the LaunchAgent and remove its plist. Idempotent.
# Razer.app is left alone. The mirror the agent ran stops with it and is started again as a manual mirror
# (as after launch.sh), so a running Razer.app keeps working; ./stop.sh stops both.
# Usage: ./disable-login.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for a in "$@"; do echo "unknown argument: $a" >&2; exit 2; done

restart=0
if agent_loaded; then
  server_pid >/dev/null && restart=1
  echo "Unloading the login agent ($AGENT_DOMAIN/$AGENT_LABEL)..."
  agent_bootout
  echo "Login agent unloaded."
else
  echo "Login agent is not loaded."
fi
if agent_enabled; then
  rm -f "$AGENT_PLIST"
  echo "Removed $AGENT_PLIST; nothing starts at login any more."
else
  echo "No plist at $AGENT_PLIST; start at login was already off."
fi

if [[ "$restart" == 1 ]]; then
  echo "The agent's mirror stopped with it; starting it again as a manual mirror."
  start_server
  if ! wait_for_mirror "$SERVER_CHILD"; then
    echo "ERROR: the manual mirror did not come up. Last server output:" >&2
    tail -n 20 "$SERVER_OUT" >&2 || true
    exit 1
  fi
  echo "Manual mirror is up (pid $SERVER_CHILD); ./stop.sh stops it."
fi
line="$(razer_main_line)"
if [[ -n "$line" ]]; then
  echo "Left alone: Razer.app (running, pid ${line%% *})."
else
  echo "Left alone: Razer.app (not running)."
fi
