#!/usr/bin/env bash
# Start the local apps-mac.razer.com mirror and launch Razer.app (RazerAppEngine) pointed at it.
# Usage: ./launch.sh [--backend NAME]   (a backend of a device file, e.g. 153-win for devices/basilisk-v3.json)
# Env:   MIRROR_PORT (8443), MIRROR_BACKEND, MIRROR_DRY_RUN=1 (still quits Razer.app; starts the mirror, prints the
#        open command and does not relaunch)
# With start at login enabled (enable-login.sh) launchd owns the mirror: this restarts the login agent instead of
# starting a second server, and the agent launches Razer.app unless it already runs through the mirror. The agent
# runs the installed copy in ~/Library/Application Support/synapse-unlock-mac; ./enable-login.sh re-syncs it.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MIRROR_LOGS="$LOG_DIR"

BACKEND="${MIRROR_BACKEND:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend) BACKEND="$2"; shift 2 ;;
    --backend=*) BACKEND="${1#*=}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null || { echo "node not found in PATH" >&2; exit 1; }
[[ -d "$APP_PATH" ]] || { echo "Razer.app not found at $APP_PATH" >&2; exit 1; }

if agent_enabled; then
  if [[ -n "$BACKEND" || "${MIRROR_DRY_RUN:-0}" == 1 ]]; then
    echo "ERROR: start at login is enabled; --backend, MIRROR_BACKEND and MIRROR_DRY_RUN apply to a manual mirror only." >&2
    echo "The login agent uses the backends set in the device files (devices/*.json). Run ./disable-login.sh first to use them." >&2
    exit 2
  fi
  if ! install_present; then
    echo "ERROR: start at login is enabled but the installed copy in $INSTALL_DIR is missing." >&2
    echo "Run ./enable-login.sh to install it again (or ./disable-login.sh to turn start at login off)." >&2
    exit 1
  fi
  MIRROR_LOGS="$INSTALL_DIR/logs"
  old="$(agent_server_pid || true)"
  offset="$(stat -f %z "$AGENT_OUT" 2>/dev/null || echo 0)"
  if agent_loaded; then
    echo "Start at login is enabled: restarting the login agent (launchctl kickstart -k) instead of starting a second server."
    launchctl kickstart -k "$AGENT_DOMAIN/$AGENT_LABEL"
  else
    echo "Start at login is enabled but the login agent is not loaded (stop.sh unloads it): loading it (launchctl bootstrap)."
    launchctl bootstrap "$AGENT_DOMAIN" "$AGENT_PLIST"
  fi
  if ! pid="$(wait_for_agent_server "$old" "$offset")"; then
    echo "ERROR: the login agent did not bring the mirror up within 30 s. Last agent output:" >&2
    tail -n 20 "$AGENT_OUT" >&2 || true
    exit 1
  fi
  echo "Mirror is up under the login agent (pid $pid); AvailableDevices.json lists $(declared_label "$INSTALL_DIR/devices")."
  echo "The agent launches Razer.app unless it already runs through the mirror (log: $AGENT_OUT)."
  if ! install_current; then
    echo "Note: the installed copy differs from this repo (a git pull or a change under devices/?);"
    echo "      run ./enable-login.sh to re-sync it and reload the agent."
  fi
else
  # A loaded agent without its plist would still hold the port: unload it.
  if agent_loaded; then
    echo "The login agent is loaded but has no plist; unloading it."
    agent_bootout
  fi
  if pid="$(agent_server_pid)"; then
    echo "Stopping a leftover mirror of the installed copy (pid $pid)."
    kill_server_pid "$pid"
  fi

  # 1. Quit a running Razer.app so it restarts with our switches (it is single-instance).
  quit_razer_app

  # 2. (Re)start the mirror server.
  stop_server >/dev/null
  start_server
  if ! wait_for_mirror "$SERVER_CHILD"; then
    echo "ERROR: mirror did not come up ($(mirror_missing || true)). Last server output:" >&2
    tail -n 20 "$SERVER_OUT" >&2 || true
    stop_server >/dev/null || true
    exit 1
  fi
  echo "Mirror is up (pid $SERVER_CHILD); AvailableDevices.json lists $(declared_label)."

  # 3. Launch Razer.app with the stock launcher's switches plus host-rules (launch_razer_app in lib.sh).
  launch_razer_app
fi

# 4. How to stop.
cat <<EOF

Razer Synapse is starting against the local mirror.
  Request log : $MIRROR_LOGS/mirror.log   (tail -f "$MIRROR_LOGS/mirror.log")
  Server out  : $MIRROR_LOGS/server.out
  Status      : $ROOT/status.sh
  Stop        : $ROOT/stop.sh            (quit Razer.app + stop the mirror)
  Revert      : $ROOT/stop.sh --stock    (same, then relaunch stock Razer Synapse)
  Login start : $ROOT/enable-login.sh / disable-login.sh
EOF
