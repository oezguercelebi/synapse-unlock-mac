# Shared helpers for the scripts in this folder. Sourced, not executed.
# shellcheck shell=bash
#
# Two copies of the runtime can exist, and each one only ever touches its own pidfile and logs:
#   - the repo (wherever you cloned it): launch.sh runs a manual mirror from here, logs in <repo>/logs/;
#   - the installed copy in $INSTALL_DIR, which enable-login.sh syncs from the repo and launchd runs (agent.sh),
#     logs in $INSTALL_DIR/logs/.
# ROOT is the folder of the lib.sh being sourced, so LOG_DIR, PIDFILE and DEVICES_DIR follow the running copy.
# The repo's scripts stop the agent's mirror with launchctl bootout, never through its pidfile.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${MIRROR_PORT:-8443}"
LOG_DIR="$ROOT/logs"
PIDFILE="$LOG_DIR/server.pid"
DEVICES_DIR="$ROOT/devices"
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
# Start at login (enable-login.sh): a user LaunchAgent that runs the installed copy's agent.sh.
AGENT_LABEL="com.synapse-unlock-mac.agent"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
AGENT_DOMAIN="gui/$(id -u)"
# launchd runs the installed copy, not the repo: macOS privacy protection (TCC) keeps launchd jobs out of
# ~/Documents, ~/Desktop, ~/Downloads and iCloud Drive, and ~/Library/Application Support is outside them.
INSTALL_DIR="$HOME/Library/Application Support/synapse-unlock-mac"
INSTALL_FILES="agent.sh lib.sh server.mjs"   # plus devices/
AGENT_OUT="$INSTALL_DIR/logs/agent.out"
if [[ "$ROOT" == "$INSTALL_DIR" ]]; then MIRROR_KIND="login agent's mirror"; else MIRROR_KIND="manual mirror"; fi

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

# ---- mirror server

# Pid of whatever listens on $PORT, or nothing.
port_pid() { lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -n1 || true; }

# Pid of the server.mjs that the copy in folder $1 started: its pidfile, else the port's listener, and in both cases
# only when the process runs $1/server.mjs. The repo and the installed copy therefore never see each other's server.
server_pid_in() {
  local root="$1" pid
  pid="$(cat "$root/logs/server.pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ "$(ps -o args= -p "$pid" 2>/dev/null)" == *"$root/server.mjs"* ]]; then
    echo "$pid"; return 0
  fi
  pid="$(port_pid)"
  if [[ -n "$pid" && "$(ps -o args= -p "$pid" 2>/dev/null)" == *"$root/server.mjs"* ]]; then
    echo "$pid"; return 0
  fi
  return 1
}
server_pid() { server_pid_in "$ROOT"; }               # this copy's server (from the repo: the manual mirror)
agent_server_pid() { server_pid_in "$INSTALL_DIR"; }  # the installed copy's server (the login agent's mirror)

# Who listens on $PORT: "agent <pid>" (the installed copy), "manual <pid>" (a manual mirror from this folder),
# "other <pid>" or "none".
port_owner() {
  local pid args
  pid="$(port_pid)"
  if [[ -z "$pid" ]]; then echo "none"; return 0; fi
  args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  if [[ "$args" == *"$INSTALL_DIR/server.mjs"* ]]; then echo "agent $pid"
  elif [[ "$args" == *"$ROOT/server.mjs"* ]]; then echo "manual $pid"
  else echo "other $pid"; fi
}

# GET a path from the mirror on $PORT (Host and SNI $HOST, certificate not checked).
mirror_get() { curl -sk --fail --max-time 5 --resolve "$HOST:$PORT:127.0.0.1" "https://$HOST:$PORT$1"; }

# Field $1 of the /__mirror/status JSON on stdin, one value per line (an array gives one line per element; a missing
# field, or input that is not JSON, gives nothing). Fails only when node does not run.
status_field() {
  node -e '
    let s = "";
    process.stdin.setEncoding("utf8").on("data", (c) => (s += c)).on("end", () => {
      let v;
      try { v = JSON.parse(s)[process.argv[1]]; } catch { return; }
      for (const x of Array.isArray(v) ? v : v === undefined || v === null ? [] : [v]) console.log(String(x));
    });
  ' "$1"
}

# "productId 153" / "productIds 153, 900": the productIds the mirror on $PORT has loaded, for messages.
served_label() {
  local p
  p="$(mirror_get /__mirror/status 2>/dev/null | status_field productIds | paste -sd ' ' - || true)"
  case "$p" in
    "") echo "no device (the mirror loaded no device file)" ;;
    *" "*) echo "productIds ${p// /, }" ;;
    *) echo "productId $p" ;;
  esac
}

# The device-file errors the mirror on $PORT reports ("errors" of /__mirror/status), one per line, or nothing.
mirror_errors() {
  local status
  status="$(mirror_get /__mirror/status 2>/dev/null)" || return 0
  printf '%s' "$status" | status_field errors || true
}

# Prints the mirror's device-file errors loudly on stderr, or nothing. The scripts do not wait for a device whose file
# the server could not load (mirror_missing), so this is where such a file shows up.
warn_mirror_errors() {
  local errs
  errs="$(mirror_errors)"
  [[ -n "$errs" ]] || return 0
  {
    echo "!! The mirror reports device-file errors. A file marked '(not loaded)' is NOT served: its device stays unavailable."
    printf '%s\n' "$errs" | sed 's/^/!!   /'
    echo "!! Fix it in the repo's devices/ and check with: node server.mjs --check (a manual mirror reloads it by itself;"
    echo "!! the login agent's copy after ./enable-login.sh)."
  } >&2
}

# Prints what keeps the mirror on $PORT from being ready, or nothing; returns 1 when not ready. Ready: /__mirror/status
# answers, the server loaded at least one device file, and AvailableDevices.json lists the productId of every device
# file the server loaded ("productIds" of /__mirror/status). A file the server could not load (bad JSON, a bad regex)
# is not waited for: it is listed under "errors", which the scripts print (warn_mirror_errors, status.sh).
mirror_missing() {
  local status pids errs="" e list pid re missing=""
  status="$(mirror_get /__mirror/status 2>/dev/null)" || status=""
  if [[ "$status" != *'"ok": true'* ]]; then echo "no answer on /__mirror/status"; return 1; fi
  if ! pids="$(printf '%s' "$status" | status_field productIds)"; then echo "cannot read /__mirror/status (node not found in PATH?)"; return 1; fi
  if [[ -z "$pids" ]]; then
    while IFS= read -r e; do errs="${errs:+$errs; }$e"; done < <(printf '%s' "$status" | status_field errors || true)
    echo "the mirror loaded no device file${errs:+ (errors: $errs)}"; return 1
  fi
  if ! list="$(mirror_get "/synapse/dashboard/AvailableDevices.json?d=$(date +%s)" 2>/dev/null)"; then
    echo "AvailableDevices.json did not load (upstream unreachable?)"; return 1
  fi
  for pid in $pids; do
    re="\"productId\":[[:space:]]*${pid}[^0-9]"
    [[ "$list" =~ $re ]] || missing="${missing:+$missing }$pid"
  done
  if [[ -n "$missing" ]]; then echo "AvailableDevices.json lacks productId $missing"; return 1; fi
}

# True when the mirror on $PORT is ready (see mirror_missing).
mirror_check() { mirror_missing >/dev/null; }

# Start this copy's server.mjs in the background (backend $BACKEND when set) and record its pid in $PIDFILE and
# $SERVER_CHILD. Fails when another process listens on the port.
start_server() {
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port $PORT is in use by another process:" >&2
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
    return 1
  fi
  local args=(--port "$PORT")
  [[ -n "${BACKEND:-}" ]] && args+=(--backend "$BACKEND")
  echo "Starting the $MIRROR_KIND on https://127.0.0.1:$PORT ${BACKEND:+(backend $BACKEND)}..."
  nohup node "$ROOT/server.mjs" "${args[@]}" >>"$SERVER_OUT" 2>&1 &
  SERVER_CHILD=$!
  echo "$SERVER_CHILD" >"$PIDFILE"
}

# Wait until the server (pid $1) passes mirror_check: $2 attempts 0.25 s apart (default 40, about 10 s).
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

# SIGTERM server pid $1, SIGKILL after 3 s.
kill_server_pid() {
  local i
  kill "$1" 2>/dev/null || true
  for i in $(seq 1 10); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.3
  done
  kill -9 "$1" 2>/dev/null || true
}

# Stop this copy's server (found through this copy's pidfile or its server.mjs path; never another copy's).
stop_server() {
  local pid
  if ! pid="$(server_pid)"; then
    echo "The $MIRROR_KIND is not running."
    rm -f "$PIDFILE"
    return 0
  fi
  echo "Stopping the $MIRROR_KIND (pid $pid)..."
  kill_server_pid "$pid"
  rm -f "$PIDFILE"
  echo "Stopped the $MIRROR_KIND."
}

# ---- installed copy (what launchd runs)

install_present() { [[ -f "$INSTALL_DIR/agent.sh" && -f "$INSTALL_DIR/lib.sh" && -f "$INSTALL_DIR/server.mjs" && -d "$INSTALL_DIR/devices" ]]; }

# Copy the runtime files from this folder (the repo) to $INSTALL_DIR: $INSTALL_FILES and devices/ (files removed from
# devices/ are removed there too). The copy's certs/ and logs/ are its own and are kept. rsync replaces each file
# through a new inode, so a bash that is still reading the old agent.sh is not disturbed.
install_sync() {
  if [[ "$ROOT" == "$INSTALL_DIR" ]]; then echo "ERROR: run this from the repo, not from the installed copy." >&2; return 1; fi
  local f files=()
  for f in $INSTALL_FILES; do files+=("$ROOT/$f"); done
  mkdir -p "$INSTALL_DIR/logs" "$INSTALL_DIR/devices"
  rsync -a "${files[@]}" "$INSTALL_DIR/"
  rsync -a --delete "$ROOT/devices/" "$INSTALL_DIR/devices/"
  local commit dirty=""
  commit="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  # shellcheck disable=SC2086
  git -C "$ROOT" diff --quiet HEAD -- $INSTALL_FILES devices 2>/dev/null || dirty=" plus uncommitted changes"
  printf 'source=%s\ncommit=%s%s\nsynced=%s\n' "$ROOT" "$commit" "$dirty" "$(date '+%Y-%m-%d %H:%M:%S')" >"$INSTALL_DIR/.install-info"
}

# True when $INSTALL_DIR holds the same runtime files as this folder.
install_current() {
  local f
  install_present || return 1
  for f in $INSTALL_FILES; do cmp -s "$ROOT/$f" "$INSTALL_DIR/$f" || return 1; done
  diff -rq "$ROOT/devices" "$INSTALL_DIR/devices" >/dev/null 2>&1
}

# Remove $INSTALL_DIR (runtime files, certs, logs). Only from the repo.
install_remove() {
  [[ -n "${HOME:-}" && "$ROOT" != "$INSTALL_DIR" ]] || { echo "ERROR: refusing to remove $INSTALL_DIR from here." >&2; return 1; }
  [[ -e "$INSTALL_DIR" ]] || return 0
  rm -rf "$INSTALL_DIR"
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

# After a bootstrap or kickstart: wait up to 30 s until an installed-copy server other than pid $1 passes
# mirror_check, and print its pid. $2 is the size of agent.out before the (re)start.
# Returns 1 on timeout, 2 when agent.out shows that launchd may not read the installed copy (see tcc_hint).
wait_for_agent_server() {
  local old="$1" offset="$2" pid i
  for i in $(seq 1 120); do
    if pid="$(agent_server_pid)" && [[ "$pid" != "$old" ]] && mirror_check; then
      echo "$pid"; return 0
    fi
    if tail -c +$((offset + 1)) "$AGENT_OUT" 2>/dev/null | grep -q 'Operation not permitted'; then return 2; fi
    sleep 0.25
  done
  return 1
}

# Fallback explanation for "Operation not permitted" / last exit code 126. The installed copy lives outside the
# folders TCC protects, so this should not happen; it did when launchd ran agent.sh straight from ~/Documents.
tcc_hint() {
  cat >&2 <<EOF
macOS privacy protection (TCC) did not let launchd read $INSTALL_DIR.
TCC keeps launchd jobs out of ~/Documents, ~/Desktop, ~/Downloads and iCloud Drive, which is why the login agent
runs this installed copy instead of the repo. If ~/Library/Application Support is blocked too on this Mac, add
/bin/bash under System Settings > Privacy & Security > Full Disk Access and run ./enable-login.sh again (that gives
every launchd job that runs /bin/bash full disk access), or keep using ./launch.sh by hand.
EOF
}
