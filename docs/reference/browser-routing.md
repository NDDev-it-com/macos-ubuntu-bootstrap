# Fail-Closed Browser Routing

The bootstrap browser layer has one supported browser backend: CloakBrowser on
`http://127.0.0.1:9222`. It never falls back to stock Chrome or Chromium.

## Managed Runtime

- `cloakbrowser==0.4.12` is installed in a content-addressed isolated runtime
  below `~/.local/share/rldyour/cloakbrowser/runtimes/`.
- The wrapper resolves and verifies the CloakBrowser binary before launch.
- `com.rldyour.cloakbrowser` (launchd) or
  `rldyour-cloakbrowser.service` (systemd user) owns the persistent headless
  browser and its private `daemon-profile`.
- `cloakbrowser-cdp-health` requires the managed service PID and command line to
  match the fixed loopback address, port, and profile. It proves that PID owns
  the listening socket and that its executable is the exact CloakBrowser binary
  resolved during the verified install. It then validates the `/json/version`
  discovery document and WebSocket endpoint.

The CDP listener must never be exposed beyond loopback. CDP grants full control
over pages, cookies, storage, and browser-side JavaScript.

## Provider Entry Points

The bootstrap requires a Node.js version compatible with the pinned providers,
then installs isolated packages below
`~/.local/share/rldyour/browser-stack/node-runtimes/` and managed PATH wrappers below
`~/.local/bin`:

- `chrome-devtools-mcp` `1.6.0` adds the fixed `--browser-url` and rejects
  WebSocket, auto-connect, executable, channel, or alternate URL selectors.
- `playwright-cli` `0.1.17` loads the managed `browser.cdpEndpoint` config in
  an isolated session registry. It rejects external attach, alternate endpoint,
  config, browser, profile, or extension values, stock-browser installs,
  `run-code`, and `--filename` execution.
- Both Node providers resolve from `templates/browser/provider/bun.lock` with
  `bun install --frozen-lockfile --ignore-scripts`.
- `webwright` is retired fail-closed. Its exact compatibility wrapper prints a
  `NOT_PROVEN` diagnostic and exits `78`; no Webwright checkout, Python
  environment, dependency lock, config overlay, or browser object is installed.

Every browser action runs `cloakbrowser-cdp-health` first. A successful apply
then publishes an owner-only canonical receipt binding exact content-addressed
runtimes, provider binaries, wrappers, service definition, policy sources, and
live health. `scripts/verify-browser-runtime.sh` recomputes that entire state;
a marker substring or reachable CDP-compatible process is not proof.
Diagnostic/version commands may run without a live browser, but they cannot
start one.

The bootstrap intentionally does not run `playwright-cli install`, including its
skills mode, because that workspace initializer also downloads Playwright's
stock Chromium. Any skill metadata must be provisioned independently of this
runtime path.

Agent adapters must invoke these PATH entry points. Direct invocation of package
binaries under another global prefix or proprietary built-in browser agents is
outside this contract and must remain disabled when strict CloakBrowser routing
is required.

The production bootstrap pins active provider versions and managed installation
paths in source. It rejects upstream development overrides that can replace the
signed browser path:
`CLOAKBROWSER_BINARY_PATH`, `CLOAKBROWSER_DOWNLOAD_URL`,
`CLOAKBROWSER_SKIP_CHECKSUM`, `CLOAKBROWSER_VERSION`, and
`CLOAKBROWSER_WIDEVINE_CDM`. `CLOAKBROWSER_LICENSE_KEY` remains the only
supported secret override and is never committed; it cannot change the
platform-specific browser build pinned by the repository.

## Idempotency And Ownership

Managed files carry a unique ownership marker and are replaced atomically; the
strict JSON Playwright config uses a separate ownership sidecar. Only exact
legacy service definitions and explicit legacy launcher markers are adopted.
Existing unmanaged files, symlinks, directories, and configs are preserved;
the browser installation fails instead of replacing them. Retired historical
Webwright runtimes are never executed or destructively removed. Existing global
npm/bun installations are not removed.

`--skip-browser` is rejected by the bootstrap. `RLDYOUR_SKIP_CLOAKBROWSER` is
also rejected: this mandatory layer has no compliant skip mode, stock-browser
fallback, or provider-only installation path.

## Verification

```bash
cloakbrowser-cdp-health
chrome-devtools-mcp --version
playwright-cli --version
bash scripts/verify-browser-runtime.sh
```

The final command is the exact installed-runtime authority and includes the
first command's live proof. A missing service, changed endpoint, unexpected
process command, invalid discovery document, wrapper drift, receipt drift, or
unreachable port is a hard failure.
