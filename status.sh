#!/usr/bin/env bash
# Report whether the mirror is up, whether Razer.app runs with the mirror switches, and the login agent's state.
# Exit 0 when the mirror is up and Razer.app carries the switches, 1 otherwise (the login agent does not count).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

rc=0
echo "== mirror"
if pid="$(server_pid)"; then
  echo "server pid      : $pid"
else
  echo "server pid      : not running"; rc=1
fi
status_json="$(curl -sk --max-time 5 --resolve "$HOST:$PORT:127.0.0.1" "https://$HOST:$PORT/__mirror/status" || true)"
if [[ -n "$status_json" ]]; then
  echo "$status_json" | sed 's/^/  /'
else
  echo "status endpoint : no answer on 127.0.0.1:$PORT"; rc=1
fi
if mirror_check; then
  echo "dashboard check : AvailableDevices.json lists productId 153"
else
  echo "dashboard check : FAILED"; rc=1
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
else
  echo "plist           : none (start at login is off; ./enable-login.sh turns it on)"
fi
agent_pid=""
if agent_loaded; then
  agent_pid="$(agent_field pid)"
  exit_code="$(agent_field 'last exit code')"
  echo "loaded          : yes, state $(agent_field state), pid ${agent_pid:--}, runs $(agent_field runs), last exit code $exit_code"
  if [[ "$exit_code" == 126 ]]; then
    echo "  126: launchd could not read agent.sh (macOS privacy protection; see README, Start at login)"
  fi
else
  echo "loaded          : no"
fi
if pid="$(server_pid)"; then
  if [[ -n "$agent_pid" && "$(ps -o ppid= -p "$pid" | tr -d ' ')" == "$agent_pid" ]]; then
    echo "mirror owner    : login agent (server pid $pid is a child of agent pid $agent_pid)"
  else
    echo "mirror owner    : manual (server pid $pid was not started by the login agent)"
  fi
fi

echo "== recent requests (logs/mirror.log)"
tail -n 8 "$LOG_DIR/mirror.log" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
exit "$rc"
