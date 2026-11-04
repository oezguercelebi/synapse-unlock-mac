# Shared helpers for the scripts in this folder. Sourced, not executed.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${MIRROR_PORT:-8443}"
LOG_DIR="$ROOT/logs"
PIDFILE="$LOG_DIR/server.pid"
SERVER_OUT="$LOG_DIR/server.out"
APP_ID="com.razer.appengine.app"
APP_PATH="$HOME/Library/Razer/RazerAppEngine/Razer.app"
# pgrep/pkill -f regexes anchored at the start of the command line (the executable path). A shell or editor whose
# arguments merely mention Razer.app never matches, and neither does RzEngineMon (Contents/CommonDylib).
APP_RE="^${APP_PATH//./\\.}/Contents"
APP_PATTERN="$APP_RE/MacOS/Razer( |\$)"                     # main process only
APP_TREE_PATTERN="$APP_RE/(MacOS/Razer( |\$)|Frameworks/)"  # main + its helpers and crash handler
STOCK_LAUNCHER="/Applications/Razer/Razer Synapse.app"
HOST="apps-mac.razer.com"
# Start at login (enable-login.sh): a user LaunchAgent that runs agent.sh.
AGENT_LABEL="com.example.synapse-basilisk-v3-mirror"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
AGENT_DOMAIN="gui/$(id -u)"
AGENT_OUT="$LOG_DIR/agent.out"

mkdir -p "$LOG_DIR"

app_running() { pgrep -f "$APP_PATTERN" >/dev/null 2>&1; }

# "pid args" of the main Razer.app process, or nothing.
razer_main_line() {
  local pid
  pid="$(pgrep -f "$APP_PATTERN" | head -n1 || true)"
  if [[ -n "$pid" ]]; then echo "$pid $(ps -o args= -p "$pid")"; fi
}

# True when a Razer.app command line ($1) maps $HOST to this mirror.
uses_mirror() { [[ "$1" == *"--host-rules="* && "$1" == *"MAP $HOST 127.0.0.1:$PORT"* ]]; }

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

# Launch Razer.app with the same switches the stock launcher uses, plus host-rules.
# RazerAppEngine's main process removes --host-rules from Chromium's command line and re-adds it
# from its own parser (parseCmdParams), which splits on whitespace unless the value is wrapped in
# literal quotes. The double quotes inside the argument are therefore deliberate.
launch_razer_app() {
  local host_rules_arg="--host-rules=\"MAP $HOST 127.0.0.1:$PORT\""
  local open_cmd=(open -a "$APP_PATH" --args
    --url-params=apps=synapse
    --application-host="$HOST"
    "$host_rules_arg"
    --ignore-certificate-errors)
  if [[ "${MIRROR_DRY_RUN:-0}" == 1 ]]; then
    echo "DRY RUN, not launching. Would run (one argv element per line):"
    printf '  [%s]\n' "${open_cmd[@]}"
  else
    echo "Launching Razer.app..."
    "${open_cmd[@]}"
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

# Start server.mjs in the background (backend $BACKEND when set) and record its pid in $PIDFILE and
# $SERVER_CHILD. Fails when another process listens on the port.
start_server() {
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port $PORT is in use by another process:" >&2
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
    return 1
  fi
  local args=(--port "$PORT")
  [[ -n "${BACKEND:-}" ]] && args+=(--backend "$BACKEND")
  echo "Starting mirror on https://127.0.0.1:$PORT ${BACKEND:+(backend $BACKEND)}..."
  nohup node "$ROOT/server.mjs" "${args[@]}" >>"$SERVER_OUT" 2>&1 &
  SERVER_CHILD=$!
  echo "$SERVER_CHILD" >"$PIDFILE"
}

# Wait until the server (pid $1) serves productId 153: $2 attempts 0.25 s apart (default 40, about 10 s).
# Returns 1 on timeout or when the server exits.
wait_for_mirror() {
  local i
  for i in $(seq 1 "${2:-40}"); do
    mirror_check && return 0
    kill -0 "$1" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
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

# ---- start at login

agent_enabled() { [[ -f "$AGENT_PLIST" ]]; }
agent_loaded() { launchctl print "$AGENT_DOMAIN/$AGENT_LABEL" >/dev/null 2>&1; }

# One top-level field of 'launchctl print' for the agent: state, pid, runs, "last exit code".
agent_field() {
  local tab=$'\t'
  launchctl print "$AGENT_DOMAIN/$AGENT_LABEL" 2>/dev/null | sed -n "s/^${tab}$1 = //p" | head -n1 || true
}

# Unload the agent. launchd sends agent.sh SIGTERM, which stops its server child; Razer.app is not touched.
agent_bootout() {
  agent_loaded || return 0
  # bootout can report an error while the job is still exiting; the loop checks the outcome.
  launchctl bootout "$AGENT_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
  local i
  for i in $(seq 1 40); do
    agent_loaded || return 0
    sleep 0.25
  done
  echo "ERROR: launchd still lists $AGENT_LABEL after bootout." >&2
  return 1
}

# After a bootstrap or kickstart: wait up to 30 s until a server other than pid $1 serves productId 153 and
# print its pid. $2 is the size of agent.out before the (re)start. Returns 1 on timeout, 2 when agent.out shows
# that macOS privacy protection keeps launchd jobs out of this folder (see tcc_hint).
wait_for_agent_server() {
  local old="$1" offset="$2" pid i
  for i in $(seq 1 120); do
    if pid="$(server_pid)" && [[ "$pid" != "$old" ]] && mirror_check; then
      echo "$pid"; return 0
    fi
    if tail -c +$((offset + 1)) "$AGENT_OUT" 2>/dev/null | grep -q 'Operation not permitted'; then return 2; fi
    sleep 0.25
  done
  return 1
}

tcc_hint() {
  cat >&2 <<EOF
macOS privacy protection (TCC) does not let launchd jobs read $ROOT:
folders under ~/Documents, ~/Desktop, ~/Downloads and iCloud Drive are protected. Either move this folder
somewhere else and run ./enable-login.sh from there, or add /bin/bash under System Settings > Privacy &
Security > Full Disk Access and run ./enable-login.sh again (that gives every launchd job that runs
/bin/bash full disk access).
EOF
}
