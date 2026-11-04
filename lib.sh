# Shared helpers for launch.sh / stop.sh / status.sh. Sourced, not executed.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${MIRROR_PORT:-8443}"
LOG_DIR="$ROOT/logs"
PIDFILE="$LOG_DIR/server.pid"
SERVER_OUT="$LOG_DIR/server.out"
APP_ID="com.razer.appengine.app"
APP_PATH="$HOME/Library/Razer/RazerAppEngine/Razer.app"
APP_PATTERN="RazerAppEngine/Razer.app/Contents/MacOS/Razer"   # main process only
APP_TREE_PATTERN="RazerAppEngine/Razer.app/"                   # main + its helper processes
STOCK_LAUNCHER="/Applications/Razer/Razer Synapse.app"
HOST="apps-mac.razer.com"

mkdir -p "$LOG_DIR"

app_running() { pgrep -f "$APP_PATTERN" >/dev/null 2>&1; }

# Quit Razer.app (RazerAppEngine) only. Dexts, Elevation Service and GameManagerService are left alone.
quit_razer_app() {
  if ! app_running; then
    echo "Razer.app is not running."
    return 0
  fi
  echo "Quitting Razer.app ($APP_ID)..."
  # Guarded by app_running: 'tell application id' would launch the app if it were not running.
  osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 20); do
    app_running || { echo "Razer.app quit."; return 0; }
    sleep 0.5
  done
  echo "Razer.app did not quit within 10 s; sending SIGTERM."
  pkill -f "$APP_TREE_PATTERN" || true
  for i in $(seq 1 10); do
    app_running || { echo "Razer.app terminated."; return 0; }
    sleep 0.5
  done
  echo "Still running; sending SIGKILL."
  pkill -9 -f "$APP_TREE_PATTERN" || true
  sleep 1
  if app_running; then
    echo "ERROR: Razer.app is still running." >&2
    return 1
  fi
}

server_pid() {
  local pid=""
  if [[ -f "$PIDFILE" ]]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && ps -o args= -p "$pid" | grep -q "server.mjs"; then
      echo "$pid"; return 0
    fi
  fi
  # Fallback: whoever listens on the port, if it is our server.
  pid="$(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -n1 || true)"
  if [[ -n "$pid" ]] && ps -o args= -p "$pid" | grep -q "$ROOT/server.mjs"; then
    echo "$pid"; return 0
  fi
  return 1
}

mirror_check() {
  curl -sk --max-time 5 --resolve "$HOST:$PORT:127.0.0.1" \
    "https://$HOST:$PORT/synapse/dashboard/AvailableDevices.json?d=$(date +%s)" | grep -q '"productId":153'
}

stop_server() {
  local pid
  if ! pid="$(server_pid)"; then
    echo "Mirror server is not running."
    rm -f "$PIDFILE"
    return 0
  fi
  echo "Stopping mirror server (pid $pid)..."
  kill "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "Mirror server stopped."
}
