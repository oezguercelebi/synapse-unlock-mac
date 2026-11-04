#!/usr/bin/env bash
# Start the mirror and Razer.app at every login.
#   1. Copies the runtime (agent.sh, lib.sh, server.mjs, devices/) to ~/Library/Application Support/synapse-unlock-mac.
#   2. Writes a user LaunchAgent (~/Library/LaunchAgents/com.synapse-unlock-mac.agent.plist) that runs that copy.
#   3. Loads it now.
# launchd runs the copy, not this folder: macOS privacy protection (TCC) keeps launchd jobs out of ~/Documents,
# ~/Desktop, ~/Downloads and iCloud Drive. The copy makes its own certificate and keeps its own logs/.
# Idempotent: after a git pull or a change under devices/, run it again to re-sync the copy and reload the agent.
# A mirror started by launch.sh is handed over to the agent; Razer.app keeps running and reconnects.
# Usage: ./enable-login.sh
# Env:   MIRROR_NODE (absolute path of the node for the agent; default: see below), MIRROR_PORT (8443)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for a in "$@"; do echo "unknown argument: $a" >&2; exit 2; done
if [[ "$ROOT" == "$INSTALL_DIR" ]]; then echo "Run enable-login.sh from the repo; $INSTALL_DIR is the installed copy." >&2; exit 2; fi

# The node the agent runs. launchd's PATH is /usr/bin:/bin:/usr/sbin:/sbin, so the plist puts this node's directory
# first. Never a resolved, versioned path: Homebrew's Cellar/node/<version> is deleted by the next 'brew upgrade'.
# In order: MIRROR_NODE; a stable link (Homebrew's /opt/homebrew/bin/node or /usr/local/bin/node); the node in this
# shell's PATH, as found (a version manager's per-shell link may be gone by the next login: set MIRROR_NODE then).
node_from=""
NODE_BIN=""
if [[ -n "${MIRROR_NODE:-}" ]]; then
  NODE_BIN="$MIRROR_NODE"; node_from="MIRROR_NODE"
else
  for n in /opt/homebrew/bin/node /usr/local/bin/node; do
    if [[ -x "$n" ]]; then NODE_BIN="$n"; node_from="stable link"; break; fi
  done
  if [[ -z "$NODE_BIN" ]]; then NODE_BIN="$(command -v node || true)"; node_from="this shell's PATH"; fi
fi
[[ -n "$NODE_BIN" ]] || { echo "node not found: not in PATH, /opt/homebrew/bin or /usr/local/bin (or set MIRROR_NODE)" >&2; exit 1; }
if [[ "$NODE_BIN" != /* || "${NODE_BIN##*/}" != node ]]; then
  echo "The agent's node must be an absolute path to a file named node (the agent finds it through PATH): $NODE_BIN" >&2
  exit 1
fi
node_version="$("$NODE_BIN" -p process.versions.node 2>/dev/null)" || { echo "cannot run $NODE_BIN" >&2; exit 1; }
[[ "${node_version%%.*}" -ge 20 ]] || { echo "$NODE_BIN is node $node_version; the mirror needs node 20 or newer (set MIRROR_NODE)" >&2; exit 1; }
# Everything this script runs with node (server.mjs --check, lib.sh helpers, a restored manual mirror) uses that node.
PATH="$(dirname "$NODE_BIN"):$PATH"
echo "Node for the login agent: $NODE_BIN (v$node_version, from $node_from)."
if [[ "$node_from" == "this shell's PATH" ]]; then
  echo "  If that is a version manager's per-shell link (fnm, nvm), it may be gone by the next login: set MIRROR_NODE to"
  echo "  a node path that stays put and run ./enable-login.sh again. ./status.sh shows whether the plist's node exists."
fi
[[ -d "$APP_PATH" ]] || { echo "Razer.app not found at $APP_PATH" >&2; exit 1; }
command -v rsync >/dev/null || { echo "rsync not found in PATH" >&2; exit 1; }

# 0. Check the device files before anything is stopped or copied.
echo "Checking the device files:"
if ! "$NODE_BIN" "$ROOT/server.mjs" --check; then
  echo "ERROR: fix the device files first. Nothing was stopped, copied or loaded." >&2
  exit 1
fi

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# 1. Write and check the plist before anything is stopped. It points at the installed copy.
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
		<string>$(xml "$INSTALL_DIR/agent.sh")</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$(xml "$INSTALL_DIR")</string>
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

# 2. Free the port: unload a loaded agent (its mirror stops with it), hand a manual mirror from this repo over.
#    Razer.app is not touched.
had_manual=0
if agent_loaded; then
  echo "The login agent is loaded; unloading it to re-sync the installed copy and reload it."
  agent_bootout
fi
if pid="$(agent_server_pid)"; then
  echo "Stopping a leftover mirror of the installed copy (pid $pid)."
  kill_server_pid "$pid"
fi
if pid="$(server_pid)"; then
  echo "Handing the manual mirror (pid $pid) over to the login agent; Razer.app keeps running and reconnects."
  had_manual=1
  stop_server
fi

# Undo for the failure paths below: the manual mirror comes back so a running Razer.app stays served.
restore_manual() {
  [[ "$had_manual" == 1 ]] || return 0
  echo "Starting the manual mirror from this repo again; Razer.app was not touched."
  start_server
  if wait_for_mirror "$SERVER_CHILD"; then
    echo "Manual mirror is up again (pid $SERVER_CHILD)."
  else
    echo "ERROR: the manual mirror did not come up. Last server output:" >&2
    tail -n 20 "$SERVER_OUT" >&2 || true
  fi
}

# 3. Sync the installed copy.
if ! install_sync; then
  echo "ERROR: could not copy the runtime to $INSTALL_DIR." >&2
  rm -f "$tmp"
  restore_manual
  exit 1
fi
echo "Synced the installed copy: $INSTALL_DIR (agent.sh, lib.sh, server.mjs, devices/; its certs/ and logs/ are its own)."

# 4. Install the plist and load it. RunAtLoad starts agent.sh now and at every login.
mkdir -p "$(dirname "$AGENT_PLIST")"
mv "$tmp" "$AGENT_PLIST"
echo "Wrote $AGENT_PLIST (node $NODE_BIN)."
offset="$(stat -f %z "$AGENT_OUT" 2>/dev/null || echo 0)"
if ! launchctl bootstrap "$AGENT_DOMAIN" "$AGENT_PLIST"; then
  echo "ERROR: launchctl bootstrap failed; start at login was NOT enabled (plist removed)." >&2
  rm -f "$AGENT_PLIST"
  restore_manual
  exit 1
fi
echo "Loaded $AGENT_LABEL into $AGENT_DOMAIN."

rc=0
pid="$(wait_for_agent_server "" "$offset")" || rc=$?
if [[ "$rc" == 2 ]]; then
  echo "ERROR: launchd may not read the installed copy:" >&2
  tail -c +$((offset + 1)) "$AGENT_OUT" | grep -m1 'Operation not permitted' >&2 || true
  tcc_hint
  agent_bootout
  rm -f "$AGENT_PLIST"
  echo "Start at login was NOT enabled: the agent is unloaded and $AGENT_PLIST removed." >&2
  restore_manual
  exit 1
elif [[ "$rc" != 0 ]]; then
  echo "WARNING: the agent's mirror is not ready after 30 s ($(mirror_missing || true)); the agent keeps waiting. Last agent output:" >&2
  tail -n 20 "$AGENT_OUT" >&2 || true
  warn_mirror_errors
else
  echo "Mirror is up under the login agent (server pid $pid)."
  warn_mirror_errors
fi

echo
"$ROOT/status.sh" || true
exit "$rc"
