#!/usr/bin/env bash
# Start the mirror and Razer.app at every login: write a user LaunchAgent that runs agent.sh, and load it now.
# Idempotent. A mirror started by launch.sh is handed over to the agent; Razer.app keeps running and reconnects.
# Usage: ./enable-login.sh
# Env:   MIRROR_NODE (node for the agent; default: the node in PATH, resolved to its real path), MIRROR_PORT (8443)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for a in "$@"; do echo "unknown argument: $a" >&2; exit 2; done

node_cmd="${MIRROR_NODE:-$(command -v node || true)}"
[[ -n "$node_cmd" ]] || { echo "node not found in PATH (or set MIRROR_NODE)" >&2; exit 1; }
# launchd's PATH is /usr/bin:/bin:/usr/sbin:/sbin. Resolve the real binary now: version-manager shims
# (fnm's per-shell links, for example) do not exist in launchd's environment.
NODE_BIN="$("$node_cmd" -p process.execPath)" || { echo "cannot run $node_cmd" >&2; exit 1; }
[[ -d "$APP_PATH" ]] || { echo "Razer.app not found at $APP_PATH" >&2; exit 1; }

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# 1. Write and check the plist before anything is stopped.
tmp="$LOG_DIR/agent.plist.tmp"
cat >"$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(xml "$AGENT_LABEL")</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$(xml "$ROOT/agent.sh")</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$(xml "$ROOT")</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(xml "$(dirname "$NODE_BIN")"):/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>MIRROR_PORT</key>
		<string>$(xml "$PORT")</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>$(xml "$AGENT_OUT")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$AGENT_OUT")</string>
</dict>
</plist>
EOF
plutil -lint -s "$tmp" || { rm -f "$tmp"; exit 1; }

# 2. Free the port: reload a loaded agent, or hand a manual mirror over. Razer.app is not touched.
was_running=0
server_pid >/dev/null && was_running=1
if agent_loaded; then
  echo "Login agent is loaded; unloading it to load the new plist."
  agent_bootout
fi
if pid="$(server_pid)"; then
  echo "Handing the manual mirror (pid $pid) over to the login agent; Razer.app keeps running and reconnects."
  stop_server
fi

# 3. Install and load. RunAtLoad starts agent.sh now and at every login.
mkdir -p "$(dirname "$AGENT_PLIST")"
mv "$tmp" "$AGENT_PLIST"
echo "Wrote $AGENT_PLIST (node $NODE_BIN)."
offset="$(stat -f %z "$AGENT_OUT" 2>/dev/null || echo 0)"
launchctl bootstrap "$AGENT_DOMAIN" "$AGENT_PLIST"
echo "Loaded $AGENT_LABEL into $AGENT_DOMAIN."

rc=0
pid="$(wait_for_agent_server "" "$offset")" || rc=$?
if [[ "$rc" == 2 ]]; then
  echo "ERROR: the login agent cannot read this folder:" >&2
  tail -c +$((offset + 1)) "$AGENT_OUT" | grep -m1 'Operation not permitted' >&2 || true
  tcc_hint
  agent_bootout
  rm -f "$AGENT_PLIST"
  echo "Start at login was NOT enabled: the agent is unloaded and $AGENT_PLIST removed." >&2
  if [[ "$was_running" == 1 ]]; then
    echo "Starting the manual mirror again; Razer.app was not touched."
    start_server
    if wait_for_mirror "$SERVER_CHILD"; then
      echo "Manual mirror is up again (pid $SERVER_CHILD)."
    else
      echo "ERROR: the manual mirror did not come up. Last server output:" >&2
      tail -n 20 "$SERVER_OUT" >&2 || true
    fi
  fi
  exit 1
elif [[ "$rc" != 0 ]]; then
  echo "WARNING: the agent's mirror does not serve productId 153 after 30 s; the agent keeps waiting. Last agent output:" >&2
  tail -n 20 "$AGENT_OUT" >&2 || true
else
  echo "Mirror is up under the login agent (server pid $pid)."
fi

echo
"$ROOT/status.sh" || true
exit "$rc"
