# Basilisk V3 in Razer Synapse for macOS (local mirror)

Razer Synapse for macOS does not support the wired **Razer Basilisk V3** (USB `1532:0099`, product id **153**).
This folder makes Synapse treat it as supported, without changing any Razer file. A small local HTTPS server
stands in for `apps-mac.razer.com`, and Razer.app is started with Chromium switches that send its traffic to that server.

## Why this works

Synapse on macOS is two parts:

- `/Applications/Razer/Razer Synapse.app` is a launcher. It starts the Electron shell
  `~/Library/Razer/RazerAppEngine/Razer.app` with `--url-params=apps=synapse --application-host=apps-mac.razer.com`.
- The shell loads all of its UI from `https://apps-mac.razer.com`. That includes the background manager, the dashboard,
  the lighting engine and the per-product modules under `/synapse/products/<pid>/{mw,ui}`.

Two things on the server block the Basilisk V3. Neither is signed:

1. **The device lists.** `/synapse/dashboard/UnavailableDevices.json` lists `{"productId":153,"commercialName":"Basilisk V3"}`,
   and `AvailableDevices.json` does not list 153. The background manager therefore marks the mouse "unavailable".
2. **The product module.** `/synapse/products/153/**` returns HTTP 403 on the Mac host. The Mac host does publish
   `/synapse/products/203/**`, which is the **Basilisk V3 35K** (codename DariaRefresh). It is the same mouse body,
   with the same control interface (3), transaction id (0x1f), polling, scroll and DPI-stage commands.
   The Windows host `apps.razer.com` does publish `/synapse/products/153/**`.

`rules.json` fixes both: it edits the device lists, and it serves `/synapse/products/153/**` from the 203 Mac module
with the rewrites listed below (backend `203-mac`, the default), or from Razer's Windows 153 module (backend `153-win`).

## What is in the folder

| File | Purpose |
|---|---|
| `server.mjs` | HTTPS mirror on `127.0.0.1:8443`. It uses only Node built-ins and needs no npm install. It is generic: all product knowledge lives in `rules.json`. |
| `rules.json` | Active rules: the dashboard edits, the 203→153 module route with its rewrites, the lighting route and the `153-win` routes. |
| `rules.example.json` | Schema example with made-up product ids. Not a patch set. |
| `launch.sh` | Quits Razer.app, starts the mirror, waits until it serves 153, then launches Razer.app pointed at it. |
| `stop.sh` | Quits Razer.app and stops the mirror. `--stock` also relaunches stock Synapse. |
| `status.sh` | Reports whether the mirror is up, whether Razer.app runs with the mirror switches, rewrite warnings, and the last requests. |
| `lib.sh` | Shell helpers shared by the three scripts. |
| `certs/` | Self-signed certificate for `apps-mac.razer.com`. `server.mjs` creates it with openssl on first start. |
| `logs/` | `mirror.log` (one line per request), `server.out` (server stdout) and `server.pid`. |

## Run, stop, revert

```bash
./launch.sh                    # default backend 203-mac
./launch.sh --backend 153-win  # use Razer's Windows 153 module instead (untested fallback)
./status.sh                    # exit 0 when the mirror is up and Razer.app carries the switches
tail -f logs/mirror.log
./stop.sh                      # quit Razer.app and stop the mirror
./stop.sh --stock              # the same, then relaunch stock Synapse (this is the full revert)
```

`MIRROR_DRY_RUN=1 ./launch.sh` starts the mirror and prints the `open` command without launching Razer.app
(it still quits a running Razer.app first). `MIRROR_PORT` changes the port (default 8443) for all three scripts.

`launch.sh` runs this command:

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

`--host-rules` changes only where Chromium connects. The `Host` header and TLS SNI stay `apps-mac.razer.com`.
`--ignore-certificate-errors` makes Chromium accept the self-signed certificate.

## Nothing Razer-owned is modified

- No file under `/Applications`, `/Library`, `~/Library/Razer` or `~/Library/Application Support/Razer` is written.
- The dexts, the Elevation Service and the GameManagerService are never touched. The scripts only quit and launch
  Razer.app (`com.razer.appengine.app`).
- Nothing persists: Razer.app saves only `applicationHost`/`launchApps` on quit, and those values are unchanged.
  A normal launch through `/Applications/Razer/Razer Synapse.app` uses the real server again.
- One leftover: the service worker caches the device lists ("DeviceDataJson") stale-first, and Chromium caches what
  it fetched. The first stock launch after a revert may still show the mirrored list. It corrects itself after the
  background revalidation, usually by the next launch. For the same reason, the first mirrored launch may still
  show the stock list.

## What rules.json changes

### Dashboard lists (both backends)

- `AvailableDevices.json`: `{"productId":153,"commercialName":"Basilisk V3"}` is appended. No `repId`: the background
  manager would then report and open the module under the repId pid, and the 203 module never reads `realProductId`,
  so it would still not find the 153 hardware.
- `UnavailableDevices.json`, `inDevelopmentDevices.json`, `Synapse2Devices.json`, `Windows10Devices.json`: entries with
  productId 153 are dropped (today only `UnavailableDevices` has one). A list with nothing to drop is served byte-identical.
- Matched by path only, so the `?d=` / `?_=` cache-busters do not matter.

### Lighting manifest (both backends)

`/synapse/products/153/mw/lighting-manifests/DeviceManifest_153_<ed>.json` is answered with Razer's genuine
`/synapse/lighting-engine/manifest/DeviceManifest_153_<ed>.json`, unmodified. The lighting engine asks the module-local
path first. Razer's `DeviceManifest_203_0` and `DeviceManifest_153_0` have the same `ledConfig` (1x11 device matrix,
7x5 chroma matrix, regions 1/4/10 with 1/1/9 LEDs), so the 13 vs 11 column difference in OpenRazer does not apply to
Synapse. This route comes before the generic product routes.

### Backend `203-mac` (default): `/synapse/products/153/{mw,ui}/**` from `/synapse/products/203/{mw,ui}/**`

Path: `/synapse/products/153/(mw|ui)/X` → `/synapse/products/203/$1/X`, and every path segment that starts with
`153_<n>` becomes `203_<n>` (`pathRewrite`). Example:
`/synapse/products/153/ui/153_0/PluginImages/153_0_0_dashboard3x.avif` → `/synapse/products/203/ui/203_0/PluginImages/203_0_0_dashboard3x.avif`
(the 203 dashboard image is byte-identical to the Windows 153 one).

Body rewrites run only on 2xx responses with `Content-Type` `text/javascript`, `application/javascript`,
`application/json` or `text/html`. They never run on `/installer-manifest.json`, `/manifests/**`, `*.map`, or
svg/png/avif/ico/css/woff files (`noRewrite`): those are served byte-identical. The installer manifests still say
`"name":"203"` and `baseURL synapse/products/203/...`; the code overwrites the name with the pid, the osx resource list
is empty (no driver on macOS) and the `jws` hashes stay valid.

| Rewrite (`name` in rules.json) | From → to | Expected matches (2026-11-04 build) | Why |
|---|---|---|---|
| `productId` (**required**) | `productId:203,` → `productId:153,` | mw main 3, ui main 1 | The real gate. `connectCurrentDevice` keeps devices whose productId is in `[DeviceInfo.productId, bleId, dongleId]`; `connectHidDevice` filters `hid.getDevices()` by the same productId. |
| `webpack-context-keys` | `"./203_` → `"./153_` | mw main 3, ui 4555 chunk 22 | Context keys built from the pid at runtime (mw translations, ui `img_prods/*.png`; the ui one is a synchronous `require()` that throws without the key). |
| `manifest-productTranslations-keys` | `"203_N":` → `"153_N":` in `*/manifest.json` | mw 2, ui 3 | background-manager reads `productTranslations["<pid>_0"]` from `/synapse/products/<pid>/mw/manifest.json`. |
| `sw-precache-dirs`, `sw-precache-image-names` | `/synapse/products/203/(mw|ui)/203_N/` and `/PluginImages/203_N_M_` → 153 in `service-worker.js` | ui 3 and 2 | Absolute precache URLs of the ui service worker. |
| `name`, `name-upper`, `name-zh-CN` | `Basilisk V3 35K` / `BASILISK V3 35K` / `巴塞利斯蛇 V3 35K` → without ` 35K` | see rules.json | Product name in bundles, translations, manifests and `dashboardNames.json`. |
| `webapp-manifest-name` | `"DariaRefresh_` → `"Daria_` in `*/manifest.json` | mw 2, ui 2 | Cosmetic; Razer's 153 module is `Daria_MW`. |
| `maxDPI` | `maxDPI:35e3,` → `maxDPI:26e3,` | mw main 1, ui main 1 | Focus+ 26K sensor. Every clamp and percentage reads this field. |
| `dpi-slider-top-segment` | `toValue:35e3,step:30*G.dpiStep/2e4` → `toValue:26e3,step:30*G.dpiStep/11e3` | ui main 1 | Top segment of the DPI slider (70–100 %) becomes 15000..26000 instead of 15000..35000. |
| `master-guide` | `BASILISKV3-00000203-` → `BASILISKV3-00000153-` | mw main 1, ui main 1 | Master guide PDF (the 153 PDF exists). |
| `support-page` | `a_id/14663` → `a_id/5620` | ui main 1 | Help link; cosmetic. |

**Kept on purpose** (still in the served files): `case 203:return 92` (HID keycode table), `KEY_ID_ENC:203` (key-id enum),
`WIFI_REASON_ASSOC_FAIL:203` (IoT enum), mw `d=35e3` next to `VPower` (calibration constant), ui 4967
`maxDPI||35e3` (fallback only when maxDPI is falsy), slider segments below 15000 and the tick arrays, DPI stage
defaults 400/800/1600/3200/6400 and clutch 400, the PAW3399 sensor table (same in both modules),
`claimInterface:3`, `vendorId:5426`, `OBMSlots:4`, the button list, polling 125/500/1000, image file names
`daria-profile-*`/`prd-*`, the webpack chunk global `webpackChunkproject_anne_basilisk_v3_35k`, and the installer
manifests (see above). The SKU of the 35K (RZ01-0523) does not appear anywhere in the module.

**Optional rewrites that are not applied** (add them to the route if a live test shows the need):

| From → to | File | Why it is left alone |
|---|---|---|
| `maxDPI:26e3,dpiStep:1,claimInterface:3` → `...dpiStep:50,...` | mw main (after the maxDPI rewrite) | Razer's 153 module uses 50 (PAW3399 native granularity). Changing it alters the slider math; the firmware accepts arbitrary 16-bit DPI. |
| `WAVE_DIRECTION:"UpDown"` → `WAVE_DIRECTION:"CWCCW"` | mw main | Only changes the wave-direction labels; the 203 Mac ui already says CWCCW. |
| `supportedFeature:{brightness:!0,dpi:!0,pollingRate:!1}` → `{...,pollingRate:!0,scrollWheel:!0}` | mw main OBMSpecs | Razer's 153 module stores polling rate and scroll-wheel mode in on-board profiles; the 203 Mac code never wrote those fields. Untested. |
| `profileNavigationGroup:["CycleUp"]` → `["PreviousProfile","NextProfile","CycleUp","CycleDown"]` | mw main OBMSpecs | Extra on-board mapping options from Windows 153; not needed. |

### Backend `153-win`: Razer's Windows 153 module from `apps.razer.com` (fallback, untested at runtime)

`/synapse/products/153/{mw,ui}/**` is proxied to `apps.razer.com` on the same path with no text rewrites. It is a
genuine 153 build (Daria_MW, branch master-m16-beta): `productId:153`, `maxDPI:26e3`, `dpiStep:50`, the same
PAW3399 table and `claimInterface:3`. It uses the same cross-platform rz-middleware as the Mac build and talks to the
mouse only through `hid.getDevices` / `hid.sendFeatureReport`. Three mirror fixes make it loadable on the Mac shell:

- `installer-manifest.json` (mw and ui) gets the 203 Mac `osx` block when it has none (`setIfMissing`). Without it
  `ResourceUpdateChecker` reads `res.osx.latest`, throws, and the install status never resolves.
- `/synapse/products/153/{mw,ui}/manifests/osx/manifest-*.json`, which that block makes the code request, is
  answered with the 203 Mac osx resource manifest (`resources: []`).
- `/synapse/assets/js/razer-config@latest/index.global.js` and `/synapse/assets/js/keyboard-nav/rz-accessibility.min.js`
  are 403 on apps-mac and are fetched from apps.razer.com. The Windows mw main reads the global `RazerConfig` at top level.
  On 2026-11-04 these were the only `/synapse/assets/**` files the Windows module references that apps-mac refuses.

Known gaps of this backend: the module calls shell actions the Mac shell 4.4.25 has no handler for (`getAppFeature`,
`startKeepAlive` / `stopKeepAlive` / `setKeepAliveCallback`, `register/unregisterBigDataEvent`,
`ble.getSupportedProtocols`, `ConfigureFFI_APIToCallWhenExit`). They are guarded by `isElectron` or optional chaining,
so they probably fail quietly, but that is not verified. The Windows driver (`NormalDriver_PID0099Drv`, a `.exe`
installer resource) is never run on macOS.

## Other traffic (passthrough notes)

- Shared assets referenced by both module `index.html` files are product-agnostic and pass through unmodified:
  `/synapse/assets/js/@sentry/browser@6.19.7/browser.js`, `@sentry/tracing@6.19.7/tracing.js`, `xstate@4.38.3/xstate.js`,
  `buffer@6.0.3/buffer.js`, `pkijs@3.0.15/pkijs.js`, `manifest.js`, `react/18.2.0`, `react-dom/18.2.0`,
  `react-redux/8.0.5`, `jszip/3.10.1`, `@sentry/react@7.72.0`, `xml-js@1.6.11`, `/synapse/assets/imgs/favicon/MOUSE.svg`.
- Upstream headers (S3 via CDN): JS is `text/javascript` with gzip (12 small JS files come back uncompressed); JSON is
  `application/json` with gzip (some small JSON uncompressed); HTML is `text/html` with gzip; SVG/AVIF/ICO are uncompressed;
  a 403 is `text/html; charset=utf-8`. Every 200 has ETag/Last-Modified/`Vary: Accept-Encoding` and no Cache-Control
  and no Content-Security-Policy. Source maps (`*.map`) come back as HTTP 404 with a full `binary/octet-stream` body.
- `index.html` contains `<script nonce="...">` but there is no CSP header and no SRI `integrity` attribute, so no
  rewrite is needed in `index.html` for the 203 backend.
- The mirror decodes gzip/br before rewriting (Node zlib); for managed requests it asks upstream for
  `Accept-Encoding: identity` anyway.
- Hosts the 203 module contacts directly (they bypass the mirror; none is product-gated): `o72136.ingest.sentry.io`
  (Sentry), `pubsub-api.razerapi.com` and the pubsub websocket, `razer-alexa.razer.com`, `app-assets.razer.com/sophie`
  (audio), `gors.razerapi.com` (remote storage), `apps.razer.com/synapse` (`REACT_APP_HOST_URL` and the region-selector
  env constants), `mysupport.razer.com` / `support.razer.com` / `www.razer.com` / `dl.razer.com` / `dl.razerzone.com`
  (help links opened in the browser), `razerid-assets.razerzone.com` (login).
- Other apps-mac paths that embed the pid and therefore arrive at the mirror as 153:
  `/synapse/products/153/ui/index.html?containerId=...` (the dashboard and background manager open the UI),
  `/synapse/products/153/mw/manifest.json` (background-manager `getManifestName`),
  `/synapse/products/153/ui/153_<ed>/PluginImages/153_<ed>_<layout>_dashboard{1x,3x}.{avif,png}` and `_wrist_` variants
  (dashboard, preload tooltip), `/synapse/products/153/ui/153_<ed>/dashboardNames.json`,
  `/synapse/products/153/{mw,ui}/installer-manifest.json?d=<ts>`, which leads to `manifests/osx/manifest-1.0.1.json`
  through `baseURL` (that still says 203, so it is fetched from the real 203 path),
  `/synapse/products/153/mw/lighting-manifests/DeviceManifest_153_<ed>.json` (lighting engine, own route) and
  `/synapse/lighting-engine/manifest/DeviceManifest_153_<ed>.json` (exists upstream, passthrough).
- Service workers: `/synapse/products/153/{mw,ui}/service-worker.js` register with a 153 scope. They precache relative
  URLs (`./static/...`) that come back through the mirror and get rewritten. Their runtime-cache regex for lighting
  manifests does not depend on the pid (`\d+`).
- The existing service-worker cache (`DeviceDataJson`) serves the dashboard lists stale-first. The first launch through
  the mirror may still show the old lists until the background revalidation lands, so expect a second launch.
- localStorage and IndexedDB are per origin. `--host-rules` keeps the origin `https://apps-mac.razer.com`, so existing
  Synapse state (login, other devices) is reused. 153 profiles are stored under `synapse_153_*` keys, separate from
  any 203 data.
- No request URL built by the module contains 203 except through `DeviceInfo.productId` (rewritten) and the ui
  service-worker precache entries (rewritten).

## How the server works

Every request is forwarded to the real `apps-mac.razer.com`. The server finds the real IP with
`dns.promises.lookup` and refuses a loopback result. If the system resolver returns only loopback (for example
because of an `/etc/hosts` entry), it asks the DNS servers directly. The forwarded request keeps the
method, path, query and headers, minus hop-by-hop headers, and uses SNI/`Host` `apps-mac.razer.com` (or the route's
`host`). A request that no rule matches is streamed back untouched: status, headers and body, including compressed
and binary bodies.

A request that a rule matches is a **managed** request:

- The server asks upstream for `Accept-Encoding: identity`, drops conditional and `Range` headers so it always
  gets a full 200, and decompresses gzip, br, deflate or zstd if upstream compresses anyway. A managed `HEAD` is sent
  as `GET` and answered with headers only.
- It edits the body only when the status is 2xx and the content type is textual (the route's `textTypes`, or by
  default js, html, json, css or plain text; an `octet-stream` response falls back to the file extension). UTF-8
  bodies are edited as UTF-8; anything else as latin1, so every byte round-trips.
- Each rewrite's match count is compared with its `expect` entry. A different count is logged as `warn="..."` and
  listed under `recentWarnings` in `/__mirror/status` (and therefore by `status.sh`). When a `required` rewrite
  matches 0 times in a file its regex covers, the mirror answers **502** instead of serving an unpatched file. For
  `productId` in the two main bundles this means a Razer rebuild that changes that literal fails loudly, and an
  already-installed service worker keeps its last good (patched) copy instead of updating to an unpatched one.
- It sends the result with a correct `Content-Length`, no `ETag`, no `Content-Encoding` and
  `Cache-Control: no-store`.
- Routed responses also carry `X-Mirror-Route` and `X-Mirror-Upstream`. In a redirect, the upstream host in
  `Location` is replaced with `apps-mac.razer.com` and the route's rewrites are applied.

Upstream errors return **502** and are logged. A log line looks like this:

```
2026-11-04T20:28:05.661Z GET /synapse/products/153/ui/static/js/main.38358e33.js -> apps-mac.razer.com/synapse/products/203/ui/static/js/main.38358e33.js 200 rewritten=yes bytes=698986 ms=529 route:module-153-from-203 rewrites=7
```

`GET https://apps-mac.razer.com:8443/__mirror/status` (curl `--resolve ...:127.0.0.1 -k`) returns the active
backend, the active and inactive routes and jsonEdits, and the recent warnings. The server never forwards this path.

## rules.json format

`rules.json` is reloaded on the first request after the file changes. If the new file is invalid, the server logs
the error and keeps the previous rules. Keys starting with `_` are ignored (rules.json uses `_why` for notes).

```jsonc
{
  "upstreamHost": "apps-mac.razer.com",   // default upstream host
  "backend": "203-mac",                    // active backend; overridden by MIRROR_BACKEND or --backend
  "resolve": { "apps-mac.razer.com": ["104.124.11.41"] },  // optional IP pin (loopback is refused)
  "jsonEdits": [{
    "name": "dashboard-available-add-153",
    "match": "^/synapse/dashboard/AvailableDevices\\.json$",  // regex on the request path; the query string is ignored
    "key": "productId",                    // identity field for array entries
    "ensure": [{ "productId": 153, "commercialName": "Basilisk V3" }],  // appended if no entry has that key
    "remove": [153],                       // array entries whose key is listed are dropped
    "set": { "a.b": 1 },                   // object roots: dotted path -> value (always written)
    "setIfMissing": { "osx": { } },        // object roots: written only when the path does not exist
    "backend": "153-win"                   // optional; omit to apply to every backend
  }],
  "routes": [{
    "name": "module-153-from-203",
    "backend": "203-mac",                  // string, array, or omitted (all backends)
    "match": "^/synapse/products/153/(mw|ui)/(.*)$",  // regex on the request path; the first active match wins
    "host": "apps-mac.razer.com",          // optional upstream host for this route (153-win: apps.razer.com)
    "path": "/synapse/products/203/$1/$2", // String.replace template; omit to keep the same path
    "pathRewrite": [{ "pattern": "(?<pre>^|/)153_(?<ed>\\d+)", "replace": "$<pre>203_$<ed>" }],  // on the mapped path
    "keepQuery": true,                     // append the original query string (default true)
    "noStore": true,                       // send no-store and drop ETag (default true)
    "textTypes": "^(text/javascript|application/javascript|application/json|text/html)\\b",  // which bodies are edited
    "noRewrite": "(/installer-manifest\\.json$|/manifests/|\\.map$)",  // request paths served byte-identical
    "rewrite": [
      { "name": "productId", "literal": "productId:203,", "replace": "productId:153,",
        "required": "/main\\.[0-9a-f]+\\.js$",          // 0 matches there -> 502 instead of an unpatched file
        "expect": { "mw/main.7350e9b0198f982a848a.js": 3 } },  // upstream path suffix -> count; mismatch -> warn
      { "name": "keys", "paths": "/manifest\\.json$", "pattern": "\"203_(\\d+)\":", "replace": "\"153_$1\":" }
    ]
  }]
}
```

The browser keeps seeing `/synapse/products/153/...`, so relative URLs inside the module resolve under 153 and are
routed again. Absolute references to `/synapse/products/203/...` inside the module go to upstream unchanged unless
a rewrite changes them (the ui service worker's are rewritten; the installer manifests' `baseURL` is kept on purpose).

## Verification (offline, 2026-11-04)

Run against the live upstream with curl `--resolve apps-mac.razer.com:8443:127.0.0.1`, without Razer.app:

- Dashboard: `AvailableDevices.json` = upstream + the 153 entry (34 entries); `UnavailableDevices.json` = upstream minus
  153 (263 of 264); the other three lists unchanged and valid.
- All 173 rewritable files of the 203 module, requested under `/synapse/products/153/...`, are byte-identical to the
  rewrite spec's independently verified offline copies; all 163 JS files pass `node --check`; no `expect` warnings.
  The served main bundles contain no `productId:203`, `"productId":203` or `Basilisk V3 35K`.
- Passthrough files (JSON, JS, AVIF) are byte-identical to upstream with the same `Accept-Encoding`, including
  `Content-Encoding` and `ETag`. `noRewrite` files (installer manifests, osx manifest, css, avif via `pathRewrite`)
  are byte-identical to the decoded upstream file.
- 20 parallel requests of each main bundle return the same SHA-256.
- A broken `required` rewrite returns 502 for both main bundles and shows up in `/__mirror/status`; a changed rules
  file is hot-reloaded and a broken one is rejected.
- Backend `153-win` serves `apps.razer.com`'s 153 module (`deviceName` `Razer Basilisk V3`), injects the `osx` block,
  serves the osx resource manifest and the two shared scripts.

Not verified: anything inside Razer.app (that `--host-rules` reaches the network service, that the 203 module finds
and drives the 153 at runtime).

## Risks

- **Razer rebuilds.** The literal and regex rewrites are tied to today's builds (mw `main.7350e9b0198f982a848a.js`,
  ui `main.38358e33.js`, `4555.dd346277.chunk.js`). Passthrough keeps everything else current. After a Razer deploy,
  check `status.sh` (recentWarnings) or `grep warn= logs/mirror.log`. Note that `expect` keys name today's hashed
  files, so a renamed bundle produces no warning; only the `required` `productId` check covers renamed main bundles.
- **DPI step.** `maxDPI` is 26000, but `dpiStep` stays 1 (Razer's 153 build uses 50). DPI values that are not
  multiples of 50 rely on the 153 firmware accepting or rounding them, as it does in OpenRazer.
- **On-board memory.** The 203 Mac OBM code writes the 203 set of profile fields: polling rate is not stored in OBM
  and profile navigation is CycleUp only. Profiles saved to the 153's 4 on-board slots therefore omit polling rate and
  scroll-wheel mode, which Razer's 153 build stores there. They work but are not identical to Windows Synapse.
- **White Edition (edition 128).** The mw module only has `203_0` and `203_129` translation chunks, so it falls back to
  the `_0` names. The ui images for `153_128` exist (from `203_128`).
- **Service workers.** The 153-scoped workers and the `DeviceDataJson` cache serve stale-first: the first launch may
  still show the device as unsupported. If the mirror is later removed, cached rewritten 153 assets stay in the
  service-worker cache until it updates. The `razer-installer-manifest` cache may hold the 203 osx manifest under a
  203 URL; this is harmless.
- **REACT_APP_HOST_URL.** `apps.razer.com/synapse` appears in the ui env; a code path that uses it instead of
  `location.origin` goes to the Windows host directly (only the region selector was seen doing that).
- **Shell-wide flags.** `--ignore-certificate-errors` applies to the whole shell, and Electron could change how it
  treats `--host-rules`.
- **No battery or wireless** on either model, so those paths are inert. Feature reports go to a real device;
  commands that differ between 203 and 153 beyond DPI are not known to be safe.
