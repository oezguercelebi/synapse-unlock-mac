#!/usr/bin/env bash
# Report who serves the mirror on the port (a manual mirror from this repo, or the login agent running the installed
# copy in ~/Library/Application Support/synapse-unlock-mac), whether it lists every device, whether Razer.app runs
# with the mirror switches, and the login agent's state.
# Exit 0 when one of our mirrors is up, lists every device it loaded, has no device-file errors, and Razer.app carries
# the switches; 1 otherwise. The login agent's own state does not count.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

rc=0
owner="$(port_owner)"
kind="${owner%% *}"
serving_root=""
echo "== mirror (port $PORT)"
case "$kind" in
  agent)  echo "port owner      : login agent's mirror, installed copy (pid ${owner#* })"; serving_root="$INSTALL_DIR" ;;
  manual) echo "port owner      : manual mirror from this repo (pid ${owner#* })"; serving_root="$ROOT" ;;
  other)  echo "port owner      : another process (pid ${owner#* }): $(ps -o args= -p "${owner#* }" 2>/dev/null || true)"; rc=1 ;;
  *)      echo "port owner      : nobody (no mirror running)"; rc=1 ;;
esac
if pid="$(server_pid)"; then echo "manual (repo)   : running, pid $pid (logs in $LOG_DIR)"; else echo "manual (repo)   : not running"; fi
if pid="$(agent_server_pid)"; then echo "agent (install) : running, pid $pid (logs in $INSTALL_DIR/logs)"; else echo "agent (install) : not running"; fi
status_json="$(mirror_get /__mirror/status 2>/dev/null || true)"
if [[ -n "$status_json" ]]; then
  echo "$status_json" | sed 's/^/  /'
  if [[ "$status_json" != *'"errors": []'* ]]; then
    echo "device files    : ERRORS. A file marked '(not loaded)' is NOT served: its device stays unavailable."
    printf '%s' "$status_json" | status_field errors | sed 's/^/  !! /' || true
    rc=1
  fi
else
  echo "status endpoint : no answer on 127.0.0.1:$PORT"; rc=1
fi
if mirror_check; then
  echo "dashboard check : AvailableDevices.json lists $(served_label)"
else
  echo "dashboard check : FAILED ($(mirror_missing || true))"; rc=1
fi

echo "== Razer.app"
main_line="$(razer_main_line)"
if [[ -z "$main_line" ]]; then
  echo "Razer.app       : not running"; rc=1
else
  echo "Razer.app       : running (pid $(echo "$main_line" | awk '{print $1}'))"
  args="$(echo "$main_line" | sed 's/^ *[0-9]* //')"
  check() { if [[ "$args" == *"$1"* ]]; then echo "  [x] $2"; else echo "  [ ] $2"; rc=1; fi; }
  check "--host-rules=" "--host-rules present"
  check "MAP $HOST 127.0.0.1:$PORT" "maps $HOST to 127.0.0.1:$PORT"
  check "--ignore-certificate-errors" "--ignore-certificate-errors present"
  check "--application-host=$HOST" "--application-host=$HOST"
  helpers="$(ps -axo args= | grep -E "$APP_TREE_PATTERN" | grep -c -F -- 'host-rules' || true)"
  echo "  processes in the Razer.app tree carrying host-rules: $helpers"
fi

echo "== login agent ($AGENT_LABEL)"
if agent_enabled; then
  echo "plist           : $AGENT_PLIST"
  # enable-login.sh puts the directory of the agent's node first in the plist's PATH.
  plist_path="$(plutil -extract EnvironmentVariables.PATH raw -o - "$AGENT_PLIST" 2>/dev/null || true)"
  plist_node="${plist_path%%:*}/node"
  if [[ -z "$plist_path" ]]; then
    echo "node            : unknown (the plist has no PATH); run ./enable-login.sh again"
  elif [[ -x "$plist_node" ]]; then
    echo "node            : $plist_node (v$("$plist_node" -p process.versions.node 2>/dev/null || echo '?'))"
  else
    echo "node            : MISSING, $plist_node no longer exists: the agent cannot start. Run ./enable-login.sh again."
  fi
else
  echo "plist           : none (start at login is off; ./enable-login.sh turns it on)"
fi
if install_present; then
  echo "installed copy  : $INSTALL_DIR"
  sed -n -E 's/^(commit|synced)=/                  \1 /p' "$INSTALL_DIR/.install-info" 2>/dev/null || true
  if [[ "$ROOT" != "$INSTALL_DIR" ]]; then
    if install_current; then
      echo "                  same files as this repo"
    else
      echo "                  DIFFERS from this repo: run ./enable-login.sh to re-sync it and reload the agent"
    fi
  fi
elif [[ -e "$INSTALL_DIR" ]]; then
  echo "installed copy  : INCOMPLETE ($INSTALL_DIR); run ./enable-login.sh"
else
  echo "installed copy  : none"
  if agent_enabled; then echo "                  the plist exists but its copy is missing: run ./enable-login.sh"; fi
fi
agent_pid=""
if agent_loaded; then
  agent_pid="$(agent_field pid)"
  exit_code="$(agent_field 'last exit code')"
  echo "loaded          : yes, state $(agent_field state), pid ${agent_pid:--}, runs $(agent_field runs), last exit code $exit_code"
  if [[ "$exit_code" == 126 ]]; then
    echo "  126: launchd could not run the installed agent.sh (macOS privacy protection, TCC; see README, Start at login)"
  fi
else
  echo "loaded          : no"
fi
if pid="$(agent_server_pid)"; then
  if [[ -n "$agent_pid" && "$(ps -o ppid= -p "$pid" | tr -d ' ')" == "$agent_pid" ]]; then
    echo "agent mirror    : server pid $pid is a child of agent pid $agent_pid"
  else
    echo "agent mirror    : server pid $pid runs from the installed copy but is not a child of the agent"
  fi
fi
echo "agent log       : $AGENT_OUT"

log_dir="${serving_root:-$ROOT}/logs"
echo "== recent requests ($log_dir/mirror.log)"
tail -n 8 "$log_dir/mirror.log" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
exit "$rc"
