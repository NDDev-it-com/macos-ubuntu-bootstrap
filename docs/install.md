# Installation And Target Matrix

This guide describes adapter contract `2.0.0`. Use `scripts/bootstrap.sh` as the
public entry point so platform, profile, GUI, Docker, browser, safety, and
verification settings are composed consistently.

## Supported Targets

- **macOS Apple Silicon:** `desktop`; GUI enabled by default or disabled with
  `--no-gui`; Docker `none`; policy `source-lsp-only`.
- **Ubuntu 24.04/26.04 desktop (`amd64`/`arm64`):** GUI enabled by default or
  disabled with `--no-gui`; Docker `none`; policy `source-lsp-only`.
- **Ubuntu 24.04/26.04 server (`amd64`/`arm64`):** headless; Docker `none`,
  `rootful`, or `rootless`; default `rootful`; policy `container-execution-only`
  (project builds/tests run inside Docker; no host build toolchain is installed).

macOS supports only the desktop profile. Ubuntu requires an explicit
`--profile desktop|server`; the bootstrap never infers a runtime or Docker role
from Linux alone. Desktop and server are roles; `--no-gui` removes only the GUI
overlay and does not turn a desktop into a server.

Apply mode validates the real target. Ubuntu apply is supported only on exact
Ubuntu releases `24.04` and `26.04`.

## Plan First

Every invocation defaults to a read-only plan. Review that output before adding
`--apply`.

```bash
# Apple Silicon macOS desktop
bash scripts/bootstrap.sh --platform macos
bash scripts/bootstrap.sh --platform macos --no-gui

# Ubuntu desktop
bash scripts/bootstrap.sh --platform ubuntu --profile desktop
bash scripts/bootstrap.sh --platform ubuntu --profile desktop --no-gui

# Ubuntu server; rootful Docker is the bootstrap default
bash scripts/bootstrap.sh --platform ubuntu --profile server
```

Apply examples:

```bash
bash scripts/bootstrap.sh --platform macos --apply
bash scripts/bootstrap.sh --platform ubuntu --profile desktop --apply
bash scripts/bootstrap.sh --platform ubuntu --profile server --apply
```

The platform can be auto-detected, but explicit `--platform` is preferable in
automation and reviewable runbooks.

The full Ubuntu composition must run from the non-root developer account that
will own the managed home and CloakBrowser systemd-user service; that account
needs sudo. Root/cloud-init automation may invoke `scripts/ubuntu/server.sh`
for the root-owned baseline only. This separation avoids silently building the
AI environment under `/root` without a usable user manager.

## Public Options

```text
--platform macos|ubuntu
--profile desktop|server
--gui | --no-gui
--docker-mode none|rootful|rootless
--plan | --apply
--skip-system
--skip-ai
--skip-lsps
--skip-checks
--strict
--harden-ssh
--enable-ufw
--with-fail2ban
```

The three hardening flags are Ubuntu-server-only. Desktop profiles reject
Docker modes other than `none` and reject server hardening flags.

There is no compliant browser skip. `--skip-browser` and
`RLDYOUR_SKIP_CLOAKBROWSER=1` fail because every supported composition requires
the managed CloakBrowser boundary.

## Profile Composition

### Desktop: Source/LSP Only

Both desktop platforms receive:

- terminal and source-management utilities;
- Node/Python tool hosts required by managed CLIs and language tooling (Ubuntu
  pins the official Node.js `24.18.0` LTS tarball and both architecture hashes);
- source-analysis, LSP, formatter, linter, quality, and security tools;
- managed AI CLIs;
- the mandatory fail-closed browser layer;
- an optional platform-specific GUI overlay.

Desktop manifests intentionally exclude Docker, project build orchestration,
language SDKs used as project runtimes, and local project test/runtime
provisioning. A tool-host runtime that supports an AI CLI or LSP does not change
that boundary. On macOS, clangd is delivered by Homebrew's LLVM distribution,
but the bootstrap never invokes its compiler/linker for a project. Build and
execute projects on an Ubuntu server profile or another explicit runtime host.

### Ubuntu Server: Build/Runtime

The Ubuntu server profile is headless and adds the server build baseline,
OpenSSH and update/time-service safeguards, server verification, and the
selected Docker mode. It also retains the terminal, LSP, AI CLI, quality, and
mandatory browser layers.

Docker choices:

- `rootful` - bootstrap default; installs Docker Engine and plugins but never
  adds a user to the root-equivalent `docker` group;
- `rootless` - explicit alternative for a non-root user after reviewing its
  networking, cgroup, storage, and privileged-port limitations;
- `none` - leaves Docker state unmanaged.

Examples:

```bash
bash scripts/bootstrap.sh --platform ubuntu --profile server --docker-mode rootful
bash scripts/bootstrap.sh --platform ubuntu --profile server --docker-mode rootless
bash scripts/bootstrap.sh --platform ubuntu --profile server --docker-mode none
```

## Managed Harnesses (one owner per harness)

The owner's active harness set is **codex** and **zcode** only. Bootstrap no
longer inline-installs any AI CLI and never installs a harness through a bun/npm
global path. Each harness is owned by its dedicated authoritative NDDev module.
GDS device bootstrap materializes each module checkout and passes its absolute
path in an environment variable; when a variable is unset, the harness is
installed out-of-band by its GDS module and the standalone bootstrap logs the
delegation and continues.

| Harness | Owner module | Module path env | Delegated install |
| --- | --- | --- | --- |
| Codex | `nddev-codex-app` | `RLDYOUR_CODEX_MODULE` | `install-cli`, `apply --setup safe`, then `install-builder` |
| ZCode | `nddev-zcode-app` | `RLDYOUR_ZCODE_MODULE` | `bootstrap`, then `install --setup nddev-builder` (`--plan`/`--apply`) |

The codex setup defaults to the read-only `safe` profile; the unrestricted
`full-auto` profile is selected only by the explicit owner flag
`RLDYOUR_CODEX_FULL_AUTO=1`. `RLDYOUR_DRY_RUN` is respected: a codex dry run only
logs the exact planned module commands, and the zcode module is driven through
its own `--plan` lifecycle.

The codex harness stays update-locked: both `DISABLE_AUTOUPDATER=1` and
`DISABLE_UPDATES=1` are exported by the managed shell drop-in so the module's
standalone binary cannot silently drift.

## Mandatory Browser Automation

Browser automation is a required platform layer, not an optional desktop app.

| Component | Pin | Contract |
| --- | --- | --- |
| CloakBrowser | `0.4.12` | only supported browser backend |
| Managed CDP service | `http://127.0.0.1:9222` | fixed loopback endpoint |
| Chrome DevTools MCP | `1.6.0` | wrapper supplies the fixed browser URL |
| Playwright CLI | `0.1.17` | wrapper supplies the managed CDP config |
| Webwright | retired fail-closed | exact disabled wrapper exits `78` |

CloakBrowser is installed in an isolated environment. launchd on macOS or a
systemd user service on Ubuntu owns the persistent headless process and its
managed profile. `cloakbrowser-cdp-health` validates process ownership, command
line, loopback binding, discovery response, and WebSocket endpoint.

The only active providers are Chrome DevTools MCP and Playwright CLI. Their
wrappers run that health check before browser actions and reject:

- alternate CDP or WebSocket endpoints;
- alternate executables, channels, browser names, or configuration files;
- provider auto-start of stock Chrome or Chromium;
- Playwright arbitrary `run-code` or `--filename` execution;
- embedded or stock-browser fallback.

Every successful apply also publishes a canonical receipt that binds the exact
runtimes, provider binaries, wrappers, service definition, policy sources, and
live health proof. Verify the complete installed state with:

```bash
bash scripts/verify-browser-runtime.sh
```

A missing or unhealthy endpoint is a hard failure. Keep port `9222` bound to
`127.0.0.1`; exposing CDP remotely exposes browser pages, cookies, storage, and
JavaScript execution.

## GUI Overlay

### macOS

GUI mode installs the verified Homebrew casks for:

- Ghostty;
- cmux;
- ChatGPT;
- the separate [Codex desktop app](https://openai.com/index/introducing-the-codex-app/),
  installed through Homebrew's verified `codex-app` cask;
- Claude Desktop.

`--no-gui` skips these applications while preserving the desktop source/LSP,
AI CLI, terminal, and browser layers.

Existing casks are preserved without an implicit upgrade. Missing casks use
Homebrew's verified cask metadata; the repository does not pin mutable desktop
app versions.

### Ubuntu Desktop

GUI mode installs only the desktop font support used by the terminal
environment. No harness desktop app is installed by bootstrap: the codex and
zcode harnesses are owned by their GDS modules, and the ZCode desktop app is
installed by `nddev-zcode-app`. ChatGPT, Codex, and cmux have no supported Linux
desktop build.

Ubuntu server never installs GUI applications.

### Harness ownership

The codex and zcode harnesses (CLIs, setups, and — for ZCode — the desktop app)
are installed and version-owned by their authoritative NDDev modules, not by
this bootstrap. Bootstrap only delegates to each module's own install
lifecycle; it publishes no apt `.deb`, bun/npm global, or frozen AI-CLI bundle
for any harness.

## Explicit Ubuntu Server Hardening

No firewall, SSH authentication, Fail2ban, generic sysctl, resource-limit, or
Docker access change is inferred automatically. Plan mode remains the default.

The composed bootstrap exposes three independent opt-ins:

```bash
bash scripts/bootstrap.sh \
  --platform ubuntu \
  --profile server \
  --apply \
  --harden-ssh \
  --enable-ufw \
  --with-fail2ban
```

For an explicit SSH user, port, or UFW source CIDR, use the sourceable server
entry point after reviewing the composed bootstrap plan:

```bash
bash scripts/ubuntu/server.sh \
  --apply \
  --docker-mode rootful \
  --harden-ssh \
  --ssh-user deploy \
  --ssh-match-address 203.0.113.25 \
  --ssh-local-address 203.0.113.10 \
  --ssh-match-host admin.example.net \
  --ssh-port 22 \
  --enable-ufw \
  --ssh-allow-cidr 203.0.113.0/24 \
  --enable-fail2ban
```

Safety behavior:

- key-only SSH requires an existing non-root user and a readable supported
  public key in `authorized_keys`; `ssh-keygen` parsing plus StrictModes-safe
  owner/mode checks must pass;
- the managed OpenSSH drop-in is checked with `sshd -t` and effective settings
  are verified for the complete live connection tuple before reload;
- an SSH session supplies client/local addresses and local port automatically;
  console/cloud-init hardening must provide the explicit Match context shown
  above;
- a validation or reload failure restores the prior managed drop-in;
- an already active or enabled `ssh.service`/`ssh.socket` provider is preserved;
- authentication-only changes do not restart a socket-activated listener;
- UFW creates the SSH allow rule before enabling the firewall;
- Fail2ban validates the sshd jail before service restart;
- failed Fail2ban enable/restart/live-jail checks restore the prior file and
  service enable/active state;
- post-apply verification runs unless the low-level server module is explicitly
  invoked with `--skip-verify`.

An already synchronized clock or active NTP/PTP provider is preserved. The
bootstrap only installs Chrony when no provider is detected; verification still
requires the clock to reach a synchronized state.

Keep the current SSH session open until a second key-authenticated connection
works. Docker-published ports can bypass ordinary UFW input policy, so validate
exposure from outside the host and apply a host-specific network design.

## Authentication Handoff

Installation and authentication are intentionally separate. The repository
never manages credentials.

```bash
bash scripts/auth-handoff.sh show
bash scripts/auth-handoff.sh check
```

`show` documents owner-controlled sign-in for GitHub CLI, the Codex/OpenAI and
ZCode harnesses, supported desktop applications, browser health, and cmux.
`check` performs only non-secret CLI status probes and reports `ok` or
`pending`; it does not print account secrets.

Headless Codex authentication uses `codex login --device-auth`. ZCode signs in
with Z.ai account OAuth on first launch.

## Ownership And Idempotency

Managed files are updated atomically and carry repository ownership markers.
Existing unmanaged files, symlinks, directories, or dirty managed-source
checkouts are preserved and cause a failure instead of being adopted or
overwritten. Existing global package installations outside the managed browser
prefix are not removed.

Shell integration uses owned `~/.config/rldyour/zshenv` and `zprofile` drop-ins
plus narrowly delimited source blocks in the owner's existing `~/.zshenv` and
`~/.zprofile`. Content outside those blocks is retained, the original file is
backed up before mutation, and a clean second apply makes no further backup or
change. Fresh-login verification proves managed PATH precedence, tool
resolution, CloakBrowser routing, trust-override removal, and updater policy.
Interactive modern-tool aliases and abbreviations are enabled only when their
target executable exists; Ubuntu's `batcat` and `fdfind` command names are
selected automatically.

Ubuntu Node.js, uv, and Bun use immutable versioned release assets plus tracked
per-architecture SHA-256 values. Each extracted Ubuntu runtime carries an owned
receipt binding the tracked archive digest to hashes of its managed
executables; strict verification also requires the owned `~/.local/bin` links.
External same-version PATH binaries are never accepted as provenance. Homebrew
uses a hash-verified, signed, and
notarized package. The codex and zcode harnesses are installed by their
authoritative NDDev modules (`nddev-codex-app`, `nddev-zcode-app`), which own
their pinned standalone artifacts and integrity checks; bootstrap only delegates
to each module's install lifecycle and never installs a harness through a
bun/npm global path. RTK `0.43.0` uses a hash-pinned
native artifact and tamper-evident launcher. Chrome DevTools MCP and Playwright
CLI install from a separate tracked `bun.lock` with `--frozen-lockfile`.
CloakBrowser dependencies come from a tracked universal lock and install with
`uv sync --frozen`. Webwright has no installed runtime or dependency tree.
Digest drift is a hard failure that requires a reviewed contract update.

APT uses `--no-upgrade` for already present baseline packages. Existing uv/Bun
source tools and a complete healthy Docker CE installation are preserved on
rerun; partial, unhealthy, custom, or unowned Docker state causes a fail-closed
handoff instead of an automatic install/upgrade over live workloads.
Existing Homebrew formulae and casks are also preserved: the macOS profile
installs missing entries but never runs an implicit `brew upgrade`.

Secrets belong in owner-controlled credential stores or local secret files,
never in tracked templates, logs, CI artifacts, or repository history.

## Verification

Repository checks:

```bash
bash scripts/ci/lint.sh
bash scripts/ci/validate.sh
```

Platform checks:

```bash
bash scripts/macos/verify.sh --strict
bash scripts/ubuntu/verify.sh --strict
```

Independent Ubuntu server checks:

```bash
bash scripts/ubuntu/verify-server.sh --docker-mode rootful
```

Browser runtime checks:

```bash
cloakbrowser-cdp-health
chrome-devtools-mcp --version
playwright-cli --version
```

Full server evidence requires an Ubuntu 24.04/26.04 VM with systemd. A container
cannot prove SSH reachability, UFW behavior, time synchronization, Docker daemon
mode, or externally observable port exposure.
