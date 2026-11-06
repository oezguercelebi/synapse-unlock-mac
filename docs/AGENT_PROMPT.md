# Agent prompt: add an unsupported Razer device to Synapse for macOS

Paste everything below the line into a coding agent (Claude Code, Codex, …) running on the Mac
that has the device plugged in, Razer Synapse for macOS installed and this repository
(`synapse-unlock-mac`) cloned. It reproduces, for a new device, the process that produced the
Basilisk V3 support in this repository. Expect 1–2 hours of agent time; the agent needs shell
access, network access and permission to quit/relaunch Synapse.

Fill in the two placeholders first: `<DEVICE NAME>` and, if you already know it, `<PID>`.

---

## Goal

Make Razer Synapse for macOS accept my **<DEVICE NAME>** (USB vendor 0x1532, product id `<PID>`,
or find it), using the local mirror in this repository (`synapse-unlock-mac`). Deliver a new
`devices/<slug>.json` device file, a row in the README's "Supported devices" table, and a
live-tested result with log evidence. Modify nothing that Razer owns.

## What you are working with (established facts — verify, do not rediscover)

- **Synapse for macOS is a thin shell.** `/Applications/Razer/Razer Synapse.app` (Swift) only
  installs two DriverKit extensions and launches the real app,
  `~/Library/Razer/RazerAppEngine/Razer.app` (Electron, bundle id `com.razer.appengine.app`) as
  `open -a Razer.app --args --url-params=apps=synapse --application-host=apps-mac.razer.com`.
  Every screen, including the per-device "module" (`mw` = middleware that speaks HID,
  `ui` = the device page), is downloaded at runtime from `https://apps-mac.razer.com`.
- **The support gate is remote, not local.** `https://apps-mac.razer.com/synapse/dashboard/AvailableDevices.json`
  and `UnavailableDevices.json` (plus `Synapse2Devices`, `Windows10Devices`, `inDevelopmentDevices`,
  `XboxDevices`, `XboxHeadsets`) are plain unsigned JSON, re-fetched on every launch, cached
  stale-first by a service worker ("DeviceDataJson"). Entry schema:
  `{productId, dongleId?, bleId?, isNotChromaDevice?, commercialName, monitorPortIds?, psModeIds?, xBoxId?}`.
  `productId` is the USB PID **in decimal**.
- **Second gate:** the device module at `https://apps-mac.razer.com/synapse/products/<pid>/mw/manifest.json`
  (and `/ui/manifest.json`) returns **403** for devices Razer has not published for Mac. The Windows
  host `https://apps.razer.com/synapse/products/<pid>/mw/` usually serves a module for the same PID.
  Lighting layouts live separately at `/synapse/lighting-engine/manifest/DeviceManifest_<pid>_0.json`
  and often exist even for unpublished devices.
- **The driver is not the gate.** `com.razer.appengine.driver.dext` matches on vendor id only. Do not
  touch the dexts, the Elevation Service, `RazerGameManagerService`, `RzEngineMon`, or re-sign
  anything: the Elevation Service verifies the shell's code signature over XPC.
- **The shell honours Chromium switches** `--host-rules`, `--ignore-certificate-errors` and
  `--proxy-server` in production, but its own argv parser truncates values at whitespace unless the
  value is wrapped in **literal double quotes**: pass `"--host-rules=\"MAP apps-mac.razer.com 127.0.0.1:8443\""`.
  The main (Node) process never fetches from `apps-mac.razer.com`, so host-rules cover all traffic.
- **This repo's mirror** (`server.mjs`) is a dependency-free Node HTTPS reverse proxy for
  `apps-mac.razer.com` on `127.0.0.1:8443`. It passes everything through byte-identical except what
  the device files tell it: dashboard-list edits, path routing (`/synapse/products/<pid>/…` →
  another path or host) and literal/regex body rewrites with expected match counts. It loads every
  `devices/*.json` except `_*.json` and merges them, so your file sits next to
  `devices/basilisk-v3.json` (the worked example) and must only route its own
  `/synapse/products/<pid>/` paths. Read `README.md` ("Add your own device") and
  `devices/_template.json` (every key explained) before writing one.
- **Synapse's logs** are the oracle: `~/Library/Application Support/Razer/RazerAppEngine/User Data/Logs/`
  — `background-manager.log` (device classification: look for `unsuppted devices`, `_checkUSBDetail`,
  `Open MW`), `main.log` (`usb.getDevices vId:5426, PId:<pid>`, `hid.openDevice`),
  `products_<pid>_mw <container>.log` (every HID command with `SUCCESS` / `FAIL` /
  `command not supported`), `products_<pid>_ui …log`, `lighting-engine.log`, `dashboard.log`.

## Rules

1. Read-only against Razer: never modify, move or delete anything under `/Applications`, `/Library`,
   `~/Library/Razer` or `~/Library/Application Support/Razer`. Reading logs and caches is fine.
2. Copy anything you dissect into a scratch directory; work on the copies.
3. Never put the mouse into "driver mode" or send raw HID commands yourself; let the module do it.
4. When testing writes to the device (DPI, polling, lighting), record the original value first and
   restore it; never create, delete or overwrite on-board profiles or button mappings.
5. Mark every claim `confirmed` / `likely` / `speculative`. Do not assert a device works without a
   `SUCCESS` line from `products_<pid>_mw` and, where available, a hardware event from the device
   (`DPI_CHANGE`, `SCROLL_FREE_OR_NOTCH_MODE_CHANGE_EVENT`, …).

## Procedure

### 1. Identify the device and the gate (read-only, ~10 min)

- `ioreg -p IOUSB -l | grep -iE '"(USB Product Name|idProduct|idVendor)"'` → confirm vendor 5426
  (0x1532) and get `idProduct` (decimal = `<pid>`).
- `curl -s https://apps-mac.razer.com/synapse/dashboard/UnavailableDevices.json | python3 -c 'import json,sys; print([d for d in json.load(sys.stdin) if d["productId"]==<pid>])'`
  and the same for `AvailableDevices.json`. Record which list holds the PID and its entry
  (`dongleId`/`bleId` matter for wireless devices).
- `curl -sI https://apps-mac.razer.com/synapse/products/<pid>/mw/manifest.json` (expect 403),
  `curl -sI https://apps.razer.com/synapse/products/<pid>/mw/manifest.json` (Windows build, often 200),
  `curl -sI https://apps-mac.razer.com/synapse/lighting-engine/manifest/DeviceManifest_<pid>_0.json`.
- If Synapse is running, grep `background-manager.log` for `<pid>` to see its current classification.

### 2. Choose the clone source

Pick the **closest sibling with a published Mac module** (`/synapse/products/<sibling>/mw/manifest.json`
→ 200). Closest means, in order: same body and buttons; same connection type (wired vs wireless —
a wired device must not clone a wireless sibling, it would gain battery/dongle code paths and may
use a different HID control interface); same lighting zones; same command set. Use the
OpenRazer driver source (`driver/razermouse_driver.c` / `razerkbd_driver.c` on GitHub) as the
protocol reference: devices that share the same `case` groups there share the protocol. Candidates
for the Mac list: run `AvailableDevices.json` through the same product family name. Record the
sibling's PID, and the differences you expect (max DPI, LED count, polling rates, extra features).

If no sibling exists, plan to try the `153-win`-style backend: route `/synapse/products/<pid>/**`
to `apps.razer.com` (see README, "How it works", backend `153-win`); it is untested for any device
and needs the `osx` installer block injected and two shared scripts proxied.

### 3. Build the rewrite spec (the real work)

- Download the sibling's complete `mw` and `ui` trees from `apps-mac.razer.com` (manifest, index,
  `webpackManifest.json`, every chunk; decompress gzip/br; keep upstream headers). Source maps
  often return 404 **with a body** that contains `sourcesContent` — read them.
- Find every place the sibling's PID denotes the product: `productId:<sibling>`,
  `"productId":<sibling>`, webpack context keys like `./<sibling>_`, translation keys `<sibling>_0`,
  the product name in every language, the model number, `maxDPI`, the DPI slider table,
  master-guide and support-page ids, service-worker precache URLs under `/products/<sibling>/`.
  The HID gate is `connectHidDevice` filtering `hid.getDevices()` by `productId === DeviceInfo.productId`
  — this is why the rewrite is mandatory.
- Write `devices/<slug>.json` (start from a copy of `devices/_template.json`): a `device` block
  (`name`, `productId` in decimal, `cloneOf` the sibling, `backend`, `verified`, `notes`),
  dashboard edits (add to Available, remove from Unavailable), the route
  `/synapse/products/<pid>/(mw|ui)/` → `/synapse/products/<sibling>/$1/` with the rewrites and an
  `expect` count per file, path rewrites for any URL path that embeds the PID, and a
  lighting-manifest route if the device's own `DeviceManifest_<pid>_0.json` exists (prefer the
  genuine one). Mark the `productId` rewrite in the main bundle `required`.
- Verify offline: `node server.mjs --check` must report your file `ok`. Then start a second
  server on a spare port, which leaves Synapse and any running mirror alone: `node server.mjs --port 8444`
  (stop it with Ctrl-C when done). Do not use `./launch.sh` for this: it quits Synapse, and
  `MIRROR_DRY_RUN=1 ./launch.sh` quits it too without relaunching it (and is refused while start
  at login is enabled). `curl -k --resolve apps-mac.razer.com:8444:127.0.0.1 https://apps-mac.razer.com:8444/…`
  every rewritable file under `/synapse/products/<pid>/…`; zero remaining sibling PIDs/names;
  `node --check` on every rewritten JS; unrelated files byte-identical to upstream.
  `MIRROR_PORT=8444 ./status.sh` must show no `errors` and `AvailableDevices.json` listing your
  productId (its port owner and Razer.app lines do not apply to this test server).

### 4. Live test

- `./launch.sh` (quits Synapse, starts the mirror, relaunches with the switches). Wait ~45 s.
- The first run can still say "unavailable" for a few seconds (stale service-worker cache), then
  `clearUnSupportedDevice` → `_checkUSBDetail … type:"available"` → `Open MW`.
- Evidence to collect from `products_<pid>_mw …log`: `connectHidDevice(… result:true)`, serial and
  firmware read, profiles loaded, and the result of each command. Collect every
  `command not supported` line: those are features the clone source has and this device's firmware
  lacks. They are harmless but must be documented (and could be hidden with a UI rewrite).
- Exercise the device page control by control (DPI, polling, lighting, scroll, …), restoring each
  original value, and build a feature → works/fails table with the log line as evidence.

### 5. Deliver

- `devices/<slug>.json` with the verified date and, in `device.notes`, what fails and why and the
  sibling bundle hashes the rewrites were written against; a row in the README's "Supported
  devices" table (device, sibling, what works, what the firmware rejects); and the live evidence.
- State plainly what was not verified.

### 6. Make it permanent (start at login)

Once the live test passes, set it up so the user never has to think about it again:

- `./enable-login.sh` copies the runtime (`agent.sh`, `lib.sh`, `server.mjs`, `devices/`) to
  `~/Library/Application Support/synapse-unlock-mac` and installs a user LaunchAgent
  (`~/Library/LaunchAgents/com.synapse-unlock-mac.agent.plist`, no sudo) that runs that copy.
  launchd cannot run the repo itself when it lives under `~/Documents`, `~/Desktop`, `~/Downloads`
  or iCloud Drive (macOS TCC: "Operation not permitted", last exit code 126). The agent starts the
  mirror at login, launches Synapse through it once the mirror answers, and restarts the mirror if
  it ever dies (Synapse reconnects on its own). Synapse opened the stock way (Dock,
  `/Applications/Razer/Razer Synapse.app`) runs without the switches; the agent quits it and
  relaunches it through the mirror within ~10 s (at most once a minute; after three in ten minutes
  it gives up). The clean way to open Synapse by hand is `./launch.sh`; tell the user so. If a
  manual mirror from `launch.sh` is running, the script hands over without restarting Synapse. Your new device file only reaches the agent
  through the copy: run `./enable-login.sh` again after adding or editing it.
- `./status.sh` shows who owns port 8443 (manual mirror from the repo or the installed copy),
  whether the copy matches the repo, and whether the agent is loaded; the agent's output is in
  `~/Library/Application Support/synapse-unlock-mac/logs/agent.out`.
- `./stop.sh` unloads the agent for this session and stops everything (`--stock` relaunches stock
  Synapse); the agent comes back at next login unless `./disable-login.sh` is run, which removes
  the plist and the installed copy, leaves Razer.app alone and hands the mirror back to a manual
  mirror from the repo.
- To verify start at login on this Mac: kill the mirror's pid → launchd should restart it within
  ~15 s, with Synapse's pid unchanged; with Synapse quit, `launchctl bootout gui/$(id -u)/com.synapse-unlock-mac.agent`
  + `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.synapse-unlock-mac.agent.plist` →
  the mirror should start and Synapse should be launched with the `--host-rules` switch (`ps -o args=`).
  Quit Synapse and open `/Applications/Razer/Razer Synapse.app` → within ~15 s `agent.out` should log
  one `watchdog:` correction, and the new Synapse should carry `--host-rules`.
  `./status.sh` shows the agent's state, its node and its last exit code throughout.
- Nothing Razer-owned is touched by any of this; Razer's own daemons (Elevation Service,
  GameManagerService) are unaffected. See README, "Start at login".

## If you are a user, not an agent

`git clone` this repo (`synapse-unlock-mac`), `./launch.sh` to try it, `./enable-login.sh` to keep
it. `./stop.sh --stock --disable-login` returns you to stock Synapse; after that the folder can be
deleted (README, "Revert").
