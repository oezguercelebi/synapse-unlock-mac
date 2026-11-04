#!/usr/bin/env bash
# Start the local apps-mac.razer.com mirror and launch Razer.app (RazerAppEngine) pointed at it.
# Usage: ./launch.sh [--backend 203-mac|153-win]
# Env:   MIRROR_PORT (8443), MIRROR_BACKEND, MIRROR_DRY_RUN=1 (start the mirror, print the open command, do not launch)
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

# 1. Quit a running Razer.app so it restarts with our switches (it is single-instance).
quit_razer_app

# 2. (Re)start the mirror server.
stop_server >/dev/null
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: port $PORT is in use by another process:" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
  exit 1
fi
SERVER_ARGS=(--port "$PORT")
[[ -n "$BACKEND" ]] && SERVER_ARGS+=(--backend "$BACKEND")
echo "Starting mirror on https://127.0.0.1:$PORT ${BACKEND:+(backend $BACKEND)}..."
nohup node "$ROOT/server.mjs" "${SERVER_ARGS[@]}" >>"$SERVER_OUT" 2>&1 &
echo $! >"$PIDFILE"

ok=0
for _ in $(seq 1 40); do
  if mirror_check; then ok=1; break; fi
  if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then break; fi
  sleep 0.25
done
if [[ "$ok" != 1 ]]; then
  echo "ERROR: mirror did not come up (or AvailableDevices.json lacks productId 153). Last server output:" >&2
  tail -n 20 "$SERVER_OUT" >&2 || true
  stop_server >/dev/null || true
  exit 1
fi
echo "Mirror is up (pid $(cat "$PIDFILE")); AvailableDevices.json lists productId 153."

# 3. Launch Razer.app with the same switches the stock launcher uses, plus host-rules.
# RazerAppEngine's main process removes --host-rules from Chromium's command line and re-adds it
# from its own parser (parseCmdParams), which splits on whitespace unless the value is wrapped in
# literal quotes. The double quotes inside the single-quoted argument are therefore deliberate.
HOST_RULES_ARG="--host-rules=\"MAP $HOST 127.0.0.1:$PORT\""
OPEN_CMD=(open -a "$APP_PATH" --args
  --url-params=apps=synapse
  --application-host="$HOST"
  "$HOST_RULES_ARG"
  --ignore-certificate-errors)
if [[ "${MIRROR_DRY_RUN:-0}" == 1 ]]; then
  echo "DRY RUN, not launching. Would run (one argv element per line):"
  printf '  [%s]\n' "${OPEN_CMD[@]}"
else
  echo "Launching Razer.app..."
  "${OPEN_CMD[@]}"
fi

# 4. How to stop.
cat <<EOF

Razer Synapse is starting against the local mirror.
  Request log : $LOG_DIR/mirror.log   (tail -f "$LOG_DIR/mirror.log")
  Server out  : $SERVER_OUT
  Status      : $ROOT/status.sh
  Stop        : $ROOT/stop.sh            (quit Razer.app + stop the mirror)
  Revert      : $ROOT/stop.sh --stock    (same, then relaunch stock Razer Synapse)
EOF
