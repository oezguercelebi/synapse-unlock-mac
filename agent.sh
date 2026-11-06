#!/usr/bin/env bash
# Run by the login agent (the launchd job that enable-login.sh installs); use launch.sh by hand instead.
# launchd runs the installed copy, "$HOME/Library/Application Support/synapse-unlock-mac/agent.sh", which
# enable-login.sh syncs from the repo (macOS TCC keeps launchd jobs out of ~/Documents). Every path below is
# relative to the folder this script is in, so the copy uses its own server.mjs, devices/, certs/ and logs/.
#   1. Starts server.mjs as a child; its pid goes to logs/server.pid, so status.sh and stop.sh keep working.
#   2. Waits until the mirror passes mirror_check: AvailableDevices.json lists every device file the server loaded.
#      A file the server could not load is not waited for; its error is logged here.
#   3. Razer.app already running through the mirror: left alone (after a server restart it reconnects by itself).
#      Running without the mirror switches: quit and relaunched with them. Not running: launched.
#   4. Watchdog, every WATCH_INTERVAL s until the server exits, so the job lives exactly as long as the mirror and
#      KeepAlive restarts it: a Razer.app that runs without the mirror switches (opened from the Dock or from
#      /Applications/Razer/Razer Synapse.app, which pass only the stock switches) is quit and relaunched with them,
#      rate-limited (watch_razer). A Razer.app that is not running is left alone: launching happens only in step 3.
# SIGTERM (launchctl bootout, kickstart -k) stops the server. Razer.app is never quit on shutdown; stop.sh does that.
# Output goes to logs/agent.out (StandardOutPath in the plist); the server's to logs/server.out and logs/mirror.log.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') agent[$$]: $*"; }

WATCH_INTERVAL=5   # seconds between watchdog rounds (server alive? Razer.app with the switches?)
WATCH_MIN_AGE=8    # a Razer.app younger than this is left alone: its own startup and single-instance handoff
WATCH_SPACING=60   # at most one correction per WATCH_SPACING s,
WATCH_WINDOW=600   # and at most WATCH_MAX per WATCH_WINDOW s; when one more is needed, the watchdog gives up
WATCH_MAX=3
CORRECTIONS=""     # epoch seconds of the corrections (step 3's included), oldest first
WATCH_GAVE_UP=0

SERVER_CHILD=""
SLEEP_PID=""
on_exit() {
  if [[ -n "$SLEEP_PID" ]]; then kill "$SLEEP_PID" 2>/dev/null || true; fi
  if [[ -n "$SERVER_CHILD" ]] && kill -0 "$SERVER_CHILD" 2>/dev/null; then
    kill -TERM "$SERVER_CHILD" 2>/dev/null || true
    wait "$SERVER_CHILD" 2>/dev/null || true
  fi
  if [[ -n "$SERVER_CHILD" && "$(cat "$PIDFILE" 2>/dev/null || true)" == "$SERVER_CHILD" ]]; then
    rm -f "$PIDFILE"
  fi
}
trap on_exit EXIT
trap 'log "SIGTERM: stopping the mirror server${SERVER_CHILD:+ (pid $SERVER_CHILD)}; Razer.app is left alone."; exit 0' TERM INT

# Seconds since process $1 started (ps etime is [[dd-]hh:]mm:ss); fails when the process is gone.
proc_age() {
  local e d=0 h=0 m=0 s
  e="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ' || true)"
  [[ -n "$e" ]] || return 1
  if [[ "$e" == *-* ]]; then d="${e%%-*}"; e="${e#*-}"; fi
  s="${e##*:}"; e="${e%:*}"
  if [[ "$e" == *:* ]]; then h="${e%%:*}"; m="${e#*:}"; else m="$e"; fi
  echo $((10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s))
}

# One watchdog round for Razer.app. Not running, or running through the mirror: nothing to do. Running without the
# switches and at least WATCH_MIN_AGE s old: quit and relaunched through the mirror, one line in agent.out. At most one
# correction per WATCH_SPACING s; when a correction is due after WATCH_MAX in WATCH_WINDOW s, the watchdog logs an
# ERROR and stops correcting until the agent restarts, so a changed Razer launcher cannot cause a quit/relaunch loop.
watch_razer() {
  [[ "$WATCH_GAVE_UP" == 0 ]] || return 0
  local line old age now t kept="" n=0 last=0 new="" i
  line="$(razer_main_line)"
  [[ -n "$line" ]] || return 0
  if uses_mirror "$line"; then return 0; fi
  old="${line%% *}"
  age="$(proc_age "$old")" || return 0
  [[ "$age" -ge "$WATCH_MIN_AGE" ]] || return 0
  now="$(date +%s)"
  for t in $CORRECTIONS; do
    if [[ $((now - t)) -lt "$WATCH_WINDOW" ]]; then kept="$kept $t"; n=$((n + 1)); last="$t"; fi
  done
  CORRECTIONS="$kept"
  [[ $((now - last)) -ge "$WATCH_SPACING" ]] || return 0
  if [[ "$n" -ge "$WATCH_MAX" ]]; then
    WATCH_GAVE_UP=1
    log "ERROR: watchdog gave up: Razer.app (pid $old) runs without the mirror switches again after $n corrections in $((WATCH_WINDOW / 60)) minutes. Not correcting it any more until this agent restarts; something keeps starting Razer.app without the switches (a changed Razer launcher or update?). Run ./launch.sh from the repo and check ./status.sh."
    return 0
  fi
  CORRECTIONS="$CORRECTIONS $now"
  n=$((n + 1))
  if ! quit_razer_app >/dev/null; then
    log "ERROR: watchdog: Razer.app (pid $old) runs without the mirror switches and could not be quit (correction $n of at most $WATCH_MAX in $((WATCH_WINDOW / 60)) minutes)."
    return 0
  fi
  if ! launch_razer_app >/dev/null; then
    log "ERROR: watchdog: quit Razer.app (pid $old), which ran without the mirror switches, but could not relaunch it (correction $n of at most $WATCH_MAX in $((WATCH_WINDOW / 60)) minutes)."
    return 0
  fi
  for i in $(seq 1 20); do
    line="$(razer_main_line)"
    if [[ -n "$line" && "${line%% *}" != "$old" ]] && uses_mirror "$line"; then new="${line%% *}"; break; fi
    sleep 0.5
  done
  log "watchdog: Razer.app (pid $old) ran without the mirror switches (opened from the Dock or /Applications?); quit it and relaunched it through the mirror as pid ${new:-unknown, not seen within 10 s} (correction $n of at most $WATCH_MAX in $((WATCH_WINDOW / 60)) minutes)."
}

if ! command -v node >/dev/null; then
  # The plist's PATH starts with the directory of the node enable-login.sh chose (see status.sh, "node").
  log "ERROR: node not found: ${PATH%%:*}/node, the node enable-login.sh wrote into the plist, is gone (node upgraded, removed, or a version manager's link expired). PATH=$PATH"
  log "ERROR: run ./enable-login.sh again from the repo to record the current node; until then launchd retries this job every 10 s."
  exit 1
fi
[[ -d "$APP_PATH" ]] || { log "ERROR: Razer.app not found at $APP_PATH"; exit 1; }

log "starting (node $(command -v node), port $PORT)"
stop_server >/dev/null   # a leftover server of ours would hold the port
start_server

until wait_for_mirror "$SERVER_CHILD" 120; do
  if ! kill -0 "$SERVER_CHILD" 2>/dev/null; then
    log "ERROR: the mirror server exited before it was ready. Last server output:"
    tail -n 20 "$SERVER_OUT" || true
    exit 1
  fi
  log "mirror not ready yet ($(mirror_missing || true)); still waiting."
done
log "mirror is up (server pid $SERVER_CHILD); AvailableDevices.json lists $(served_label)."
warn_mirror_errors 2>&1 | while IFS= read -r line; do log "$line"; done

line="$(razer_main_line)"
if [[ -z "$line" ]]; then
  log "Razer.app is not running; launching it through the mirror."
  launch_razer_app
elif uses_mirror "$line"; then
  log "Razer.app (pid ${line%% *}) already runs through the mirror; left alone."
else
  log "Razer.app (pid ${line%% *}) runs without the mirror switches; restarting it through the mirror."
  quit_razer_app
  launch_razer_app
  CORRECTIONS="$(date +%s)"   # counts towards the watchdog's limits
fi

# 4. Watchdog until the server exits. The sleep runs in the background and is waited for, so SIGTERM interrupts the
#    wait at once (bash runs a trap only after a foreground command finishes).
while kill -0 "$SERVER_CHILD" 2>/dev/null; do
  watch_razer
  sleep "$WATCH_INTERVAL" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=""
done
rc=0
wait "$SERVER_CHILD" || rc=$?
log "the mirror server (pid $SERVER_CHILD) exited with status $rc; launchd restarts this job."
exit "$rc"
