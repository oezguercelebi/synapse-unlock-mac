#!/usr/bin/env bash
# Report whether the mirror is up and whether Razer.app runs with the mirror switches.
# Exit 0 when both are true, 1 otherwise.
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
main_line="$(ps -axo pid=,args= | grep -F "$APP_PATTERN" | grep -v -e 'Helper' -e 'grep -F' | head -n1 || true)"
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
  helpers="$(ps -axo args= | grep -F "$APP_TREE_PATTERN" | grep -c -F -- 'host-rules' || true)"
  echo "  processes in the Razer.app tree carrying host-rules: $helpers"
fi

echo "== recent requests (logs/mirror.log)"
tail -n 8 "$LOG_DIR/mirror.log" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
exit "$rc"
