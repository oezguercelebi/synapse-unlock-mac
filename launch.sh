#!/usr/bin/env bash
# Start the local apps-mac.razer.com mirror and launch Razer.app (RazerAppEngine) pointed at it.
# Usage: ./launch.sh [--backend 203-mac|153-win]
# Env:   MIRROR_PORT (8443), MIRROR_BACKEND, MIRROR_DRY_RUN=1 (start the mirror, print the open command, do not launch)
# With start at login enabled (enable-login.sh) launchd owns the mirror: this restarts the login agent instead of
# starting a second server, and the agent launches Razer.app unless it already runs through the mirror.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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
    echo "The login agent uses the backend in rules.json. Run ./disable-login.sh first to use them." >&2
    exit 2
  fi
  old="$(server_pid || true)"
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
  echo "Mirror is up under the login agent (pid $pid); AvailableDevices.json lists productId 153."
  echo "The agent launches Razer.app unless it already runs through the mirror (log: $AGENT_OUT)."
else
  # 1. Quit a running Razer.app so it restarts with our switches (it is single-instance).
  quit_razer_app

  # 2. (Re)start the mirror server.
  stop_server >/dev/null
  start_server
  if ! wait_for_mirror "$SERVER_CHILD"; then
    echo "ERROR: mirror did not come up (or AvailableDevices.json lacks productId 153). Last server output:" >&2
    tail -n 20 "$SERVER_OUT" >&2 || true
    stop_server >/dev/null || true
    exit 1
  fi
  echo "Mirror is up (pid $SERVER_CHILD); AvailableDevices.json lists productId 153."

  # 3. Launch Razer.app with the stock launcher's switches plus host-rules (launch_razer_app in lib.sh).
  launch_razer_app
fi

# 4. How to stop.
cat <<EOF

Razer Synapse is starting against the local mirror.
  Request log : $LOG_DIR/mirror.log   (tail -f "$LOG_DIR/mirror.log")
  Server out  : $SERVER_OUT
  Status      : $ROOT/status.sh
  Stop        : $ROOT/stop.sh            (quit Razer.app + stop the mirror)
  Revert      : $ROOT/stop.sh --stock    (same, then relaunch stock Razer Synapse)
  Login start : $ROOT/enable-login.sh / disable-login.sh
EOF
