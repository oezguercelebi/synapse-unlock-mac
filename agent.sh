#!/usr/bin/env bash
# Run by the login agent (the launchd job that enable-login.sh installs); use launch.sh by hand instead.
#   1. Starts server.mjs as a child; its pid goes to logs/server.pid, so status.sh and stop.sh keep working.
#   2. Waits until the mirror serves productId 153.
#   3. Razer.app already running through the mirror: left alone (after a server restart it reconnects by itself).
#      Running without the mirror switches: quit and relaunched with them. Not running: launched.
#   4. Waits on the server, so the job lives exactly as long as the mirror and KeepAlive restarts it.
# SIGTERM (launchctl bootout, kickstart -k) stops the server. Razer.app is never quit on shutdown; stop.sh does that.
# Output goes to logs/agent.out.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') agent[$$]: $*"; }

SERVER_CHILD=""
on_exit() {
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

command -v node >/dev/null || { log "ERROR: node not found in PATH=$PATH; run enable-login.sh again."; exit 1; }
[[ -d "$APP_PATH" ]] || { log "ERROR: Razer.app not found at $APP_PATH"; exit 1; }

log "starting (node $(command -v node), port $PORT)"
stop_server >/dev/null   # a leftover server of ours would hold the port
start_server

until wait_for_mirror "$SERVER_CHILD" 120; do
  if ! kill -0 "$SERVER_CHILD" 2>/dev/null; then
    log "ERROR: the mirror server exited before serving productId 153. Last server output:"
    tail -n 20 "$SERVER_OUT" || true
    exit 1
  fi
  log "the mirror does not serve productId 153 yet (upstream unreachable?); still waiting."
done
log "mirror is up (server pid $SERVER_CHILD); AvailableDevices.json lists productId 153."

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
fi

rc=0
wait "$SERVER_CHILD" || rc=$?
log "the mirror server (pid $SERVER_CHILD) exited with status $rc; launchd restarts this job."
exit "$rc"
