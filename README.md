# synapse-unlock-mac 🐍🔓
### Razer Synapse for Mac said *"unavailable"*. Your mouse disagrees.

**Corporate needs you to find the difference between the Basilisk V3 and the Basilisk V3 35K.**
*They're the same mouse.* (Razer's own codenames: `Daria` and `DariaRefresh`. We rest our case.)

Synapse for macOS downloads its entire brain from Razer's servers — including a one-line JSON list that decides whether your mouse is "supported". The Basilisk V3 wired sits on the *naughty list*, and Razer never uploaded its Mac module. The 35K's module? Right there, fully published, same body, same buttons, same protocol.

So this repo is a tiny, zero-dependency local mirror that sits between Synapse and Razer and politely does two things:
1. 📋 moves your mouse from `UnavailableDevices.json` to `AvailableDevices.json`
2. 🎭 hands Synapse the sibling's module wearing your mouse's name tag (13 small edits)

Result: Synapse on Mac drives the mouse — DPI stages, polling, Chroma lighting, Smart-Reel — **tested on real hardware, with the DPI and scroll-mode changes confirmed by the mouse itself.** 🎉
Button remaps, on-board profiles and Hypershift render but were not exercised, and the V3's firmware rejects the two
scroll level sliders (see [Supported devices](#supported-devices)).

**What we don't touch:** a single Razer file. No re-signing, no driver hacks, no sudo. Run `./stop.sh --stock --disable-login`,
delete the folder, and you're back to stock (see [Revert](#revert)). Razer: no hard feelings, please just publish the module. 💚

✅ Works today · 🧩 add your own device with one JSON file · 🤖 or hand [`docs/AGENT_PROMPT.md`](docs/AGENT_PROMPT.md) to an AI agent and let it do the whole thing · 🚀 starts at login

## Quick start

You need macOS with Razer Synapse for macOS installed, Node 20 or newer (tested with 24) and nothing else: no npm install.

```bash
git clone https://github.com/oezguercelebi/synapse-unlock-mac.git && cd synapse-unlock-mac
./launch.sh          # try it: quits Synapse, starts the mirror, relaunches Synapse through it
./enable-login.sh    # keep it: the mirror and Synapse start at every login (see Start at login)
./stop.sh --stock    # back to stock Synapse (with start at login on: ./stop.sh --stock --disable-login)
```

`./status.sh` tells you whether the mirror is up, who runs it and whether Synapse uses it (exit 0 when all is well).
The first launch through the mirror can still show the mouse as unavailable for a few seconds, because a service
worker serves the old device list first; it corrects itself, at the latest on the next launch.

## Supported devices

| Device | Clone of | Device file | Verified | Works | Rejected by the firmware |
|---|---|---|---|---|---|
| Razer Basilisk V3, wired (USB `1532:0099`, productId 153) | Razer Basilisk V3 35K (productId 203), Mac module | [`devices/basilisk-v3.json`](devices/basilisk-v3.json), backend `203-mac` | 2026-11-04, live on real hardware | DPI stages (max 26000) and Tactile/Free-Spin, both confirmed by the mouse's own hardware events; polling 125/500/1000; lighting effects and brightness; Smart-Reel and Scroll Acceleration on/off. Button map, Hypershift, on-board memory, profiles and calibration render but were not exercised. | The two scroll level sliders: Smart-Reel threshold `[2,2,35]` and Scroll Acceleration level `[2,2,34]` answer "command not supported". The 35K has them, the wired V3 does not. The toggles work at the firmware's built-in level. |

Your device is not here? See [Add your own device](#add-your-own-device).

## How it works

### The pieces

| File | Purpose |
|---|---|
| `server.mjs` | HTTPS mirror of `apps-mac.razer.com` on `127.0.0.1:8443`. Node built-ins only. Generic: all product knowledge lives in `devices/*.json`. |
| `devices/basilisk-v3.json` | The Basilisk V3 device file: dashboard edits, the 203→153 module route with its rewrites, the lighting route and the `153-win` routes. |
| `devices/_template.json` | Every key of a device file, explained next to the key. Not loaded (files starting with `_` are skipped). |
| `launch.sh` | Quits Razer.app, starts a manual mirror from this folder, waits until it lists every device it loaded (and prints any device file it could not load), launches Razer.app pointed at it. With start at login enabled it restarts the login agent instead. |
| `stop.sh` | Unloads the login agent if it is loaded, quits Razer.app, stops the mirror. `--stock` relaunches stock Synapse; `--disable-login` also turns start at login off. |
| `status.sh` | Who owns port 8443, the mirror's status and rewrite warnings, whether Razer.app carries the switches, the login agent, the last requests. |
| `enable-login.sh`, `disable-login.sh`, `agent.sh` | Start at login: install, remove, and the script launchd runs. See [Start at login](#start-at-login). |
| `lib.sh` | Shell helpers shared by the scripts. |
| `certs/`, `logs/` | Created on first start: a self-signed certificate for `apps-mac.razer.com` (openssl), `mirror.log` (one line per request), `server.out`, `server.pid`. These are the manual mirror's; with start at login on, the login agent keeps its own in `~/Library/Application Support/synapse-unlock-mac/` (`logs/` there also has `agent.out`). `status.sh` names the log in use. |

### Two gates, both on Razer's server

Synapse on macOS is two parts. `/Applications/Razer/Razer Synapse.app` is a launcher: it starts the Electron shell
`~/Library/Razer/RazerAppEngine/Razer.app` with `--url-params=apps=synapse --application-host=apps-mac.razer.com`.
The shell loads all of its UI from `https://apps-mac.razer.com`: the background manager, the dashboard, the lighting
engine and the per-product modules under `/synapse/products/<pid>/{mw,ui}` (`mw` speaks HID, `ui` is the device page).

Two things on that server block the Basilisk V3. Neither is signed:

1. **The device lists.** `/synapse/dashboard/UnavailableDevices.json` lists `{"productId":153,"commercialName":"Basilisk V3"}`,
   and `AvailableDevices.json` does not list 153, so the background manager marks the mouse "unavailable".
2. **The product module.** `/synapse/products/153/**` returns HTTP 403 on the Mac host. The Mac host does publish
   `/synapse/products/203/**`, the **Basilisk V3 35K** (codename DariaRefresh): the same mouse body, with the same
   control interface (3), transaction id (0x1f), polling, scroll and DPI-stage commands. The Windows host
   `apps.razer.com` does publish `/synapse/products/153/**`.

The driver is not a gate: Razer's DriverKit extension matches on the vendor id only.

### The launch switches

`launch.sh` (and the login agent) run:

```bash
open -a ~/Library/Razer/RazerAppEngine/Razer.app --args \
  --url-params=apps=synapse --application-host=apps-mac.razer.com \
  '--host-rules="MAP apps-mac.razer.com 127.0.0.1:8443"' --ignore-certificate-errors
```

**The literal double quotes in the `--host-rules` argument are required.** In production builds the RazerAppEngine
main process removes `host-rules` (and `host-resolver-rules`) from Chromium's command line. It then adds `host-rules`
back from its own parser, `lib/parseCmdParams.js`. That parser joins argv with spaces and cuts each value at the
first space unless the value is wrapped in quotes. Without the literal quotes, Chromium would receive
`--host-rules=MAP`, which does nothing.

`--host-rules` changes only where Chromium connects. The `Host` header and TLS SNI stay `apps-mac.razer.com`, and the
origin stays `https://apps-mac.razer.com`, so existing Synapse state (login, other devices) is reused.
`--ignore-certificate-errors` makes Chromium accept the mirror's self-signed certificate (see [Caveats](#caveats)).
The main (Node) process never fetches from `apps-mac.razer.com`, so the switch covers all of that traffic.

### What `devices/basilisk-v3.json` changes

**Dashboard lists (every backend).** `AvailableDevices.json` gets `{"productId":153,"commercialName":"Basilisk V3"}`
appended. There is no `repId`: the background manager would then report and open the module under the repId pid, and
the 203 module never reads `realProductId`. `UnavailableDevices.json`, `inDevelopmentDevices.json`,
`Synapse2Devices.json` and `Windows10Devices.json` lose their 153 entries (today only `UnavailableDevices` has one). A
list with nothing to change is served byte-identical. Matching is by path, so `?d=` / `?_=` cache-busters do not matter.

**Lighting manifest (every backend).** `/synapse/products/153/mw/lighting-manifests/DeviceManifest_153_<ed>.json` is
answered with Razer's genuine `/synapse/lighting-engine/manifest/DeviceManifest_153_<ed>.json`, unmodified. Razer's
`DeviceManifest_203_0` and `DeviceManifest_153_0` have the same `ledConfig` (1x11 device matrix, 7x5 chroma matrix,
regions 1/4/10 with 1/1/9 LEDs).

**Backend `203-mac` (the default): the module from the 35K.** `/synapse/products/153/(mw|ui)/X` is fetched from
`/synapse/products/203/$1/X`, and every path segment that starts with `153_<n>` becomes `203_<n>`
(`.../153/ui/153_0/PluginImages/153_0_0_dashboard3x.avif` → `.../203/ui/203_0/PluginImages/203_0_0_dashboard3x.avif`).
Body rewrites run only on 2xx responses with `Content-Type` `text/javascript`, `application/javascript`,
`application/json` or `text/html`, never on `/installer-manifest.json`, `/manifests/**`, `*.map` or
svg/png/avif/ico/css/woff files: those are served byte-identical, so the installer manifests' `jws` hashes stay valid.
These are the 13 edits:

| Rewrite (`name`) | From → to | Expected matches (2026-11-04 build) | Why |
|---|---|---|---|
| `productId` (**required**) | `productId:203,` → `productId:153,` | mw main 3, ui main 1 | The real gate. `connectCurrentDevice` keeps devices whose productId is in `[DeviceInfo.productId, bleId, dongleId]`; `connectHidDevice` filters `hid.getDevices()` by the same productId. |
| `webpack-context-keys` | `"./203_` → `"./153_` | mw main 3, ui 4555 chunk 22 | Context keys built from the pid at runtime (mw translations, ui `img_prods/*.png`; the ui one is a synchronous `require()` that throws without the key). |
| `manifest-productTranslations-keys` | `"203_N":` → `"153_N":` in `*/manifest.json` | mw 2, ui 3 | The background manager reads `productTranslations["<pid>_0"]`. |
| `sw-precache-dirs`, `sw-precache-image-names` | `/synapse/products/203/(mw\|ui)/203_N/` and `/PluginImages/203_N_M_` → 153 in `service-worker.js` | ui 3 and 2 | Absolute precache URLs of the ui service worker. |
| `name`, `name-upper`, `name-zh-CN` | `Basilisk V3 35K` / `BASILISK V3 35K` / `巴塞利斯蛇 V3 35K` → without ` 35K` | see the device file | Product name in bundles, translations, manifests and `dashboardNames.json`. |
| `webapp-manifest-name` | `"DariaRefresh_` → `"Daria_` in `*/manifest.json` | mw 2, ui 2 | Cosmetic; Razer's own 153 module is `Daria_MW`. |
| `maxDPI` | `maxDPI:35e3,` → `maxDPI:26e3,` | mw main 1, ui main 1 | Focus+ 26K sensor. Every clamp and percentage reads this field. |
| `dpi-slider-top-segment` | `toValue:35e3,step:30*G.dpiStep/2e4` → `toValue:26e3,step:30*G.dpiStep/11e3` | ui main 1 | The top segment of the DPI slider (70–100 %) becomes 15000..26000. |
| `master-guide` | `BASILISKV3-00000203-` → `BASILISKV3-00000153-` | mw main 1, ui main 1 | Master guide PDF (the 153 PDF exists). |
| `support-page` | `a_id/14663` → `a_id/5620` | ui main 1 | Help link; cosmetic. |

**Kept on purpose** (still in the served files): `case 203:return 92` (HID keycode table), `KEY_ID_ENC:203`,
`WIFI_REASON_ASSOC_FAIL:203`, mw `d=35e3` next to `VPower` (calibration constant), ui 4967 `maxDPI||35e3` (fallback
only when maxDPI is falsy), the lower DPI slider segments and tick arrays, DPI stage defaults 400/800/1600/3200/6400
and clutch 400, the PAW3399 sensor table (the same in both modules), `claimInterface:3`, `vendorId:5426`, `OBMSlots:4`,
the button list, polling 125/500/1000, image names `daria-profile-*`/`prd-*`, the webpack chunk global
`webpackChunkproject_anne_basilisk_v3_35k`, and the installer manifests. The 35K's SKU (RZ01-0523) does not appear.

**Optional rewrites that are not applied** (add them if a live test shows the need): `dpiStep:1` → `dpiStep:50`
(Razer's 153 module uses 50; the firmware accepts arbitrary 16-bit DPI), `WAVE_DIRECTION:"UpDown"` → `"CWCCW"` (labels
only), OBMSpecs `pollingRate:!1` → `!0` plus `scrollWheel:!0` (Razer's 153 module stores these in on-board profiles;
untested), and the extra Windows `profileNavigationGroup` entries.

**Backend `153-win` (fallback, untested at runtime): Razer's Windows 153 module.** `/synapse/products/153/{mw,ui}/**`
is proxied to `apps.razer.com` with no text rewrites: a genuine 153 build (`Daria_MW`, `maxDPI:26e3`, `dpiStep:50`,
the same PAW3399 table and `claimInterface:3`). Three fixes make it loadable on the Mac shell: the installer manifests
get the 203 Mac `osx` block (`setIfMissing`), the osx resource manifest that block points at is answered with the
203 Mac one (`resources: []`), and `razer-config@latest/index.global.js` and `keyboard-nav/rz-accessibility.min.js`
(403 on apps-mac) come from apps.razer.com. The module calls shell actions the Mac shell 4.4.25 has no handler for
(`getAppFeature`, keep-alive, big-data events, `ble.getSupportedProtocols`, `ConfigureFFI_APIToCallWhenExit`); they are
guarded, so they probably fail quietly, but that is not verified. Try it with `./launch.sh --backend 153-win`.

### The server

Every request is forwarded to the real `apps-mac.razer.com`. The server resolves it with `dns.promises.lookup` and
refuses a loopback answer; if the system resolver returns only loopback (an `/etc/hosts` entry, say), it asks the DNS
servers directly. Method, path, query and headers are kept (minus hop-by-hop headers), with SNI and `Host`
`apps-mac.razer.com` or the route's `host`. A request no rule matches is streamed back untouched: status, headers and
body, compressed or binary.

A request a rule matches is **managed**. The server asks upstream for `Accept-Encoding: identity`, drops conditional
and `Range` headers so it always gets a full 200, and decodes gzip, br, deflate or zstd if upstream compresses anyway.
It edits 2xx textual bodies only (UTF-8 as UTF-8, anything else as latin1 so every byte round-trips) and sends them
with a correct `Content-Length`, no `ETag` and `Cache-Control: no-store`. Routed responses carry `X-Mirror-Route` and
`X-Mirror-Upstream`; a redirect's `Location` is put back on `apps-mac.razer.com` and rewritten.

Each rewrite's match count is compared with its `expect` entry: a different count is logged as `warn="..."` and listed
under `recentWarnings` in `/__mirror/status`, and therefore by `status.sh`. When a `required` rewrite matches 0 times,
the mirror answers **502** instead of serving an unpatched file, so a Razer rebuild that changes the `productId`
literal fails loudly, and an installed service worker keeps its last good copy.

```
2026-11-04T20:28:05.661Z GET /synapse/products/153/ui/static/js/main.38358e33.js -> apps-mac.razer.com/synapse/products/203/ui/static/js/main.38358e33.js 200 rewritten=yes bytes=698986 ms=529 route:module-153-from-203 rewrites=7
```

`GET https://apps-mac.razer.com:8443/__mirror/status` (curl `-k --resolve apps-mac.razer.com:8443:127.0.0.1`) returns the
loaded device files and their productIds and active backends, errors, active and inactive routes and jsonEdits, and
the recent warnings. The server never forwards this path. `node server.mjs --check` validates the device files
without starting anything.

<details>
<summary>Passthrough notes (what else Synapse fetches, and what is left alone)</summary>

- Shared assets referenced by both module `index.html` files are product-agnostic and pass through unmodified
  (`@sentry/browser@6.19.7`, `xstate@4.38.3`, `buffer@6.0.3`, `pkijs@3.0.15`, `react/18.2.0`, `react-dom/18.2.0`,
  `react-redux/8.0.5`, `jszip/3.10.1`, `xml-js@1.6.11`, `/synapse/assets/imgs/favicon/MOUSE.svg`, ...).
- `index.html` has `<script nonce="...">` but no CSP header and no SRI `integrity`, so it needs no rewrite.
- Source maps (`*.map`) come back as HTTP 404 with a full body; every 200 has ETag/Last-Modified and no Cache-Control.
- Hosts the module contacts directly (they bypass the mirror; none is product-gated): Sentry, `pubsub-api.razerapi.com`,
  `razer-alexa.razer.com`, `app-assets.razer.com`, `gors.razerapi.com`, `apps.razer.com/synapse` (region selector),
  the support and download sites, `razerid-assets.razerzone.com` (login).
- Paths that embed the pid and arrive as 153: `ui/index.html?containerId=...`, `mw/manifest.json`,
  `ui/153_<ed>/PluginImages/...`, `ui/153_<ed>/dashboardNames.json`, `{mw,ui}/installer-manifest.json?d=<ts>` (whose
  `baseURL` still says 203, so the osx manifest is fetched from the real 203 path), the lighting manifest.
- The 153-scoped service workers precache relative URLs that come back through the mirror and get rewritten.
  153 profiles live under `synapse_153_*` localStorage keys, separate from any 203 data.

</details>

## Add your own device

One JSON file per device in `devices/`. `server.mjs` loads every `devices/*.json` except `_*.json` and merges them:
dashboard edits and routes are concatenated in file-name order, each file is hot-reloaded on its own, and a broken
file keeps its previous version and shows up under `errors` in `status.sh`. A file that has never loaded (bad JSON, a
bad regex) is not served, so its device stays unavailable while the others keep working; `launch.sh`, the login agent
and `status.sh` print its error instead of waiting for its device. A device's routes only match its own
`/synapse/products/<pid>/` paths, so loading every device file is harmless even if you own only one of the devices.
[`devices/_template.json`](devices/_template.json) explains every key; the shape is:

```jsonc
{
  "device": {                               // who this file is for
    "name": "Razer Basilisk V3",
    "productId": 153,                       // USB product id in decimal; the scripts wait until AvailableDevices.json lists it
    "cloneOf": { "productId": 203, "name": "Razer Basilisk V3 35K" },
    "backend": "203-mac",                   // this file's active backend; ./launch.sh --backend NAME switches files that have NAME
    "verified": "2026-11-04",
    "notes": ["what works, what the firmware rejects"]
  },
  "jsonEdits": [{                           // structural edits of JSON responses
    "name": "dashboard-available-add-153",  // the gate: no "backend", so it applies whatever backend is active
    "match": "^/synapse/dashboard/AvailableDevices\\.json$",  // regex on the path, query string ignored
    "ensure": [{ "productId": 153, "commercialName": "Basilisk V3" }],  // appended if missing (array roots)
    "remove": []                             // entries dropped by key (array roots); set / setIfMissing for objects
  }],
  "routes": [{                              // first active match wins, across all device files
    "name": "module-153-from-203",
    "backend": "203-mac",                   // optional: only while this backend is active; omit for every backend
    "match": "^/synapse/products/153/(mw|ui)/(.*)$",
    "path": "/synapse/products/203/$1/$2",  // String.replace template; "host" picks another upstream host
    "pathRewrite": [{ "pattern": "(?<pre>^|/)153_(?<ed>\\d+)", "replace": "$<pre>203_$<ed>" }],
    "noRewrite": "(/installer-manifest\\.json$|/manifests/|\\.map$)",  // served byte-identical
    "rewrite": [
      { "name": "productId", "literal": "productId:203,", "replace": "productId:153,",
        "required": "/main\\.[0-9a-f]+\\.js$",             // 0 matches there -> 502 instead of an unpatched file
        "expect": { "mw/main.7350e9b0198f982a848a.js": 3 } }  // count of today's build; a mismatch is a warning
    ]
  }]
}
```

Keys starting with `_` are ignored. `upstreamHost` and `resolve` (an IP pin) are optional and global. For development,
`node server.mjs --rules some-file.json` loads only that file, and `node server.mjs --check` validates them all.

**The recipe, in short** (the full, agent-ready version is [`docs/AGENT_PROMPT.md`](docs/AGENT_PROMPT.md)):

1. Find the USB product id (`ioreg -p IOUSB -l`, decimal) and confirm the gate: the pid is in
   `UnavailableDevices.json`, and `/synapse/products/<pid>/mw/manifest.json` is 403 on apps-mac.
2. Pick the sibling: the closest device whose Mac module is published (200). Closest means, in this order: the same
   body and buttons; **the same connection type** (a wired device must not clone a wireless sibling: it would gain
   battery and dongle code paths and may use another HID control interface, and a wireless device needs its
   `dongleId`/`bleId` in the dashboard entry); the same lighting zones; the same command set (devices in the same
   OpenRazer `case` groups share the protocol).
3. Download the sibling's `mw` and `ui` trees and find every place its pid names the product (`productId:<sibling>`,
   webpack context keys, translation keys, names in every language, maxDPI and the DPI slider, guide and support ids,
   service-worker URLs). Write `devices/<slug>.json` with an `expect` count per file and the `productId` rewrite `required`.
4. Check offline with curl against the mirror (no sibling pid or name left, `node --check` on every rewritten JS,
   everything else byte-identical), then live: `./launch.sh`, exercise the device page control by control,
   and read `products_<pid>_mw <container>.log` in Synapse's log folder for `SUCCESS` / `command not supported`.
5. Add a row to [Supported devices](#supported-devices) with what works and what the firmware rejects.

## Start at login

```bash
./enable-login.sh    # install and load the login agent; a running manual mirror is handed over
./status.sh          # who owns port 8443, the installed copy, the agent's node, whether it is loaded, its last exit code
./disable-login.sh   # unload it, remove the plist and the installed copy; a manual mirror takes over
```

**launchd runs an installed copy, not this folder.** macOS privacy protection (TCC) keeps launchd jobs out of
`~/Documents`, `~/Desktop`, `~/Downloads` and iCloud Drive, which is where a clone usually lives: run from there,
`agent.sh` fails with "Operation not permitted" and launchd shows last exit code 126. So `enable-login.sh` copies the
runtime (`agent.sh`, `lib.sh`, `server.mjs`, `devices/`) to `~/Library/Application Support/synapse-unlock-mac`, which
launchd can read, and the agent runs that copy. The copy creates its own certificate and keeps its own
`logs/agent.out`, `logs/mirror.log` and `logs/server.pid`. **This folder stays the source:** after a `git pull` or an
edit under `devices/`, run `./enable-login.sh` again to re-sync the copy and reload the agent (`status.sh` and
`launch.sh` tell you when the copy differs from the repo).

`enable-login.sh` first checks the device files (`server.mjs --check`), then writes
`~/Library/LaunchAgents/com.synapse-unlock-mac.agent.plist` and loads it into `gui/<uid>` with `launchctl bootstrap`.
The job runs `/bin/bash <installed copy>/agent.sh` with `RunAtLoad`, `KeepAlive` and `ThrottleInterval` 10. launchd's
`PATH` is only `/usr/bin:/bin:/usr/sbin:/sbin`, so the plist puts the directory of one node (20 or newer) first, chosen
in this order: `MIRROR_NODE` (an absolute path to a `node`); Homebrew's stable link `/opt/homebrew/bin/node` or
`/usr/local/bin/node`, which survives `brew upgrade`; else the `node` in your shell's `PATH`, as found. It is never
resolved to a versioned path such as Homebrew's `Cellar/node/<version>`, which the next upgrade deletes. If your node
comes only from a version manager's per-shell link (fnm, nvm), that link may be gone by the next login: set
`MIRROR_NODE` to a node that stays put. `status.sh` shows the plist's node and whether it still exists; if it is gone,
`agent.sh` says so in its `agent.out`, and running `enable-login.sh` again records the current one.
`MIRROR_PORT` goes into the plist too.

If the copy, the bootstrap or the TCC check (kept as a fallback) fails, or the agent's mirror is not running 30 s
after the bootstrap, `enable-login.sh` unloads the agent and removes the plist, so start at login is off rather than
half on, also when it was on before this run. If a mirror served the port before (a manual one, or the agent's on a
re-run) or Razer.app runs through the mirror, it then starts a manual mirror from this folder, so Razer.app never
points at a dead port. The installed copy and its logs stay for diagnosis; `disable-login.sh` removes them. A mirror
that runs but does not list every device after 30 s (upstream unreachable, say) is left to the agent, which keeps
waiting.

`agent.sh` starts `server.mjs` as its child, waits until `AvailableDevices.json` lists every device the server loaded
(it keeps waiting if upstream is unreachable at login, and logs any device file it could not load), and then checks
Razer.app: already running through the mirror, it is left alone;
running without the switches (started by the stock launcher, say), it is quit and relaunched with them; not running,
it is launched. The agent then waits on the server, so the job lives exactly as long as the mirror. If the server
dies, launchd restarts the job and Razer.app, which already points at `127.0.0.1:8443`, reconnects by itself. On
SIGTERM (`launchctl bootout`, `kickstart -k`) the agent stops the server and leaves Razer.app running.

The repo and the installed copy never write each other's pidfile or logs: each script works on the folder it runs from.
The repo's scripts stop the agent's mirror with `launchctl bootout`; an installed-copy server that launchd no longer
manages (left over from an unloaded agent) is killed directly, found by the `server.mjs` path in its command line.

| Script (from the repo) | With start at login enabled |
|---|---|
| `enable-login.sh` | Idempotent. Re-syncs the copy and reloads the agent. A manual mirror from `launch.sh` is stopped and the agent starts its own. Razer.app keeps running (same pid). |
| `launch.sh` | Starts no second server: `launchctl kickstart -k` on the agent, or `launchctl bootstrap` if `stop.sh` unloaded it. It refuses `--backend`, `MIRROR_BACKEND` and `MIRROR_DRY_RUN`, which apply to a manual mirror only (the agent uses `device.backend` of each device file). |
| `stop.sh` | Unloads the agent first (`launchctl bootout`; otherwise KeepAlive would restart the mirror), then quits Razer.app and stops any mirror. The plist stays, so everything comes back at the next login or with `launch.sh`. `--disable-login` also removes the plist and the copy. |
| `disable-login.sh` | Idempotent. Unloads the agent, removes the plist and the installed copy. Razer.app is left alone; the mirror is handed back to a manual mirror from the repo, so a running Synapse stays served. |
| `status.sh` | Reports the port's owner (manual mirror from the repo, the installed copy, or another process), the copy and whether it matches the repo, and the agent's state, pid, runs and last exit code. |

Nothing else starts Synapse at login: on 2026-11-04, Razer's only background items were the Elevation Service and
UninstallerWatcher daemons and the `com.razer.gms` agent. The login agent starts only the mirror and Razer.app; the
dexts, the Elevation Service, GameManagerService and RzEngineMon are not touched (RzEngineMon exits and returns with
Razer.app on its own).

## Revert

```bash
./stop.sh --stock                   # quit Razer.app, stop the mirror, relaunch stock Synapse
./stop.sh --stock --disable-login   # the same, and remove the login agent and its installed copy
```

Then delete the folder. With start at login enabled, run `./disable-login.sh` (or the second line) **before** deleting
the folder: the plist and the installed copy live outside it, and nothing else does.

Already deleted the folder with start at login still on? The agent keeps starting the mirror and Razer.app with the
switches at every login, and `disable-login.sh` went with the folder. Remove it by hand, then quit Razer Synapse and
open it again from `/Applications/Razer/Razer Synapse.app`:

```bash
launchctl bootout gui/$(id -u)/com.synapse-unlock-mac.agent   # unloads the agent; its mirror stops with it
rm ~/Library/LaunchAgents/com.synapse-unlock-mac.agent.plist
rm -rf ~/Library/Application\ Support/synapse-unlock-mac
```

**Nothing Razer-owned is modified.** No file under `/Applications`, `/Library`, `~/Library/Razer` or
`~/Library/Application Support/Razer` is written. The scripts only quit and launch Razer.app
(`com.razer.appengine.app`), with process patterns anchored at its executable path (`Contents/MacOS/Razer` and
`Contents/Frameworks/`), so the SIGTERM fallback never reaches RzEngineMon (`Contents/CommonDylib`) or a process whose
arguments merely mention the path. The dexts, the Elevation Service and GameManagerService are never touched. Razer.app
saves only `applicationHost`/`launchApps` on quit, and those values are unchanged, so a normal launch through
`/Applications/Razer/Razer Synapse.app` uses the real server again.

One leftover: the service worker caches the device lists stale-first, and Chromium caches what it fetched, so the
first stock launch after a revert may still show the mirrored list (and cached rewritten 153 files stay in the
service-worker cache until it updates). It corrects itself after the background revalidation, usually by the next launch.

## Caveats

Honest ones:

1. **Unofficial, and tied to today's builds.** The rewrites were written against mw `main.7350e9b0198f982a848a.js`,
   ui `main.38358e33.js` and `4555.dd346277.chunk.js`. When Razer republishes the sibling module, rewrites can miss:
   the server logs `warn=` and lists the mismatch under `recentWarnings` in `status.sh` (`grep warn= logs/mirror.log`
   for a manual mirror; with start at login on, the live log is
   `~/Library/Application Support/synapse-unlock-mac/logs/mirror.log`, and `status.sh` names the one in use).
   `expect` keys name hashed files, so a renamed bundle gives no warning; the `required` `productId` check covers that
   case and answers 502 instead of serving a module that can never find the mouse.
2. **`--ignore-certificate-errors` is scoped, but not narrow.** It applies only to the Synapse process tree that
   `launch.sh` or the login agent starts, for that session; not to the system, Safari or Chrome, and a stock launch
   does not have it. Inside Synapse, though, it covers every HTTPS connection its Chromium side makes, Razer ID login
   included, so for that session a forged certificate on any of those connections would go unnoticed. Electron could
   also change how it treats `--host-rules`.
3. **Terms.** This uses Razer's servers in a way their terms likely do not envision. It is interoperability for
   hardware you own, but Razer could object.
4. **No Razer code is shipped.** The repo holds rules, not modules: the sibling module is fetched from Razer's CDN at
   runtime, exactly as Synapse does, and edited in memory on the way to Synapse.

Smaller ones, for the Basilisk V3:

- **DPI step.** `maxDPI` is 26000 but `dpiStep` stays 1 (Razer's 153 build uses 50). DPI values that are not multiples
  of 50 rely on the 153 firmware accepting or rounding them, as it does in OpenRazer.
- **On-board memory.** The 203 Mac OBM code writes the 203 set of profile fields: polling rate is not stored in OBM
  and profile navigation is CycleUp only. Profiles saved to the 153's 4 on-board slots therefore omit polling rate and
  scroll-wheel mode, which Razer's 153 build stores there. They work but are not identical to Windows Synapse.
- **White Edition (edition 128).** The mw module only has `203_0` and `203_129` translation chunks, so it falls back
  to the `_0` names. The ui images for `153_128` exist (from `203_128`).
- **REACT_APP_HOST_URL.** `apps.razer.com/synapse` appears in the ui env; a code path that uses it instead of
  `location.origin` goes to the Windows host directly (only the region selector was seen doing that).
- **No battery or wireless** on either model, so those paths are inert. Feature reports go to a real device; commands
  that differ between 203 and 153 beyond DPI are not known to be safe.

## Verification evidence

### Offline (2026-11-04)

Against the live upstream with curl `--resolve apps-mac.razer.com:8443:127.0.0.1`, without Razer.app:

- Dashboard: `AvailableDevices.json` = upstream + the 153 entry (34 entries); `UnavailableDevices.json` = upstream minus
  153 (263 of 264); the other three lists unchanged and valid.
- All 173 rewritable files of the 203 module, requested under `/synapse/products/153/...`, are byte-identical to the
  rewrite spec's independently verified offline copies; all 163 JS files pass `node --check`; no `expect` warnings.
  The served main bundles contain no `productId:203`, `"productId":203` or `Basilisk V3 35K`.
- Passthrough files (JSON, JS, AVIF) are byte-identical to upstream with the same `Accept-Encoding`, including
  `Content-Encoding` and `ETag`. `noRewrite` files (installer manifests, osx manifest, css, avif via `pathRewrite`) are
  byte-identical to the decoded upstream file.
- 20 parallel requests of each main bundle return the same SHA-256.
- A broken `required` rewrite returns 502 for both main bundles and shows up in `/__mirror/status`; a changed rules
  file is hot-reloaded and a broken one is rejected.
- Backend `153-win` serves `apps.razer.com`'s 153 module (`deviceName` `Razer Basilisk V3`), injects the `osx` block,
  serves the osx resource manifest and the two shared scripts.
- After the move to `devices/*.json`: the dashboard lists and 9 rewritten module files (both main bundles, the 4555
  chunk, both manifests, `dashboardNames.json`, the lighting manifest, the ui service worker, the installer manifest)
  are byte-identical to the previous single-file server, with no warnings. A second device file is merged into the
  dashboard list; breaking, fixing and deleting it, or breaking `basilisk-v3.json`, is handled per file while 153
  keeps being served.

### Live (2026-11-04)

Razer.app launched through `launch.sh`, the device page exercised control by control, results read from
`products_153_mw <container>.log` (the module's own HID log) and from the mouse's hardware events:

- `--host-rules` reaches the network service: every request of the session went through the mirror.
- The 203 module finds the 153 over HID interface 3 (`connectHidDevice … result:true`), reads serial and firmware
  (1.2.0.0), loads the on-board profiles and macros.
- DPI stages: set and restored, **confirmed by the mouse** (`DPI_CHANGE` hardware event). Max 26000; typing 35000 clamps.
- Polling rate: 125 / 500 / 1000 only; 1000 → 500 → 1000 `completed`. The UI logs a spurious `status:"error"`
  ~20 ms before each `completed`; no toast, no effect.
- Lighting: effect switch and brightness `SUCCESS`; the engine uses Razer's genuine `DeviceManifest_153_0.json`.
- Scroll: Tactile ↔ Free-Spin **confirmed by the mouse** (`SCROLL_FREE_OR_NOTCH_MODE_CHANGE_EVENT`); Smart-Reel on/off
  and Scroll Acceleration on/off `SUCCESS` (user-verified by feel).
- The **only** commands the V3 firmware rejects are the two level sliders under those toggles:
  `[2,2,35] Set Scroll Wheel Smart Reel Mode Threshold` and `[2,2,34] Set Scroll Virtual Acceleration Level`
  → `Error USB Transfer command not supported`. The 35K has these; the wired V3 does not. The features work at the
  firmware's built-in level; dragging the slider changes nothing on the mouse and the UI shows no error.
- Button map, Hypershift view, on-board memory (5 slots), profiles and calibration render; not exercised.

### Start at login

The launchd agent itself was tested under launchd from a scratch copy outside `~/Documents` on 2026-11-04; run from
`~/Documents` it failed on TCC as described above. The installed-copy layout was tested without launchd, in a scratch
home folder. The checks covered: sync into a path with a space, drift detection, and the installed `agent.sh` run by
hand (own certificate, pidfile and logs, mirror up, the quoted `--host-rules` argument). `kill -9` of the server ends
the agent with 137, the exit that KeepAlive restarts under launchd. SIGTERM stops the server. `stop.sh`,
`disable-login.sh` and `launch.sh` handle the copy correctly. `enable-login.sh` itself was then run end to end in a
scratch home folder against a stand-in for `launchctl` that starts `agent.sh` with only the plist's environment, as
launchd does. That covered the node choice (stable link, `MIRROR_NODE`, the shell's node as found), a node that
disappears afterwards (reported by `status.sh` and in `agent.out`), and each failure on a re-run while the agent
served the port (bootstrap error, TCC, copy error, a mirror that never starts); after each one a manual mirror served
the port again. A stand-in is not launchd:

**Installed-copy login agent under real launchd (2026-11-05, this Mac):** `enable-login.sh` from the repo in
`~/Documents` installed the copy, loaded the agent (`state running`, node `/opt/homebrew/bin/node`) and handed over
from the manual mirror with Razer.app left running; no `Operation not permitted` in `agent.out`. `kill -9` of the
mirror → launchd restarted it within 1 s (`runs = 2`, `last exit code = 137`), Razer.app untouched. Simulated login
(Razer.app quit, `launchctl bootout` + `bootstrap`) → `agent.out`: "mirror is up … Razer.app is not running;
launching it through the mirror", the new Razer.app carries `--host-rules` and `--ignore-certificate-errors`, and
39 of its requests reached the mirror within 20 s. `status.sh` exit 0.

---

Reverse-engineered and built with Claude Code (Anthropic) on 2026-11-04; OpenRazer was the protocol reference.

## License

MIT, see [LICENSE](LICENSE). Copyright 2026 Özgür C.
