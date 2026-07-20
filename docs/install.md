# Installation And Target Matrix

This guide describes adapter contract `1.0.0`. Use `scripts/bootstrap.sh` as the
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

## Managed AI CLI Versions

The installers and `config/rldyour-contract.json` must agree on these values:

| CLI | Package or channel | Version policy |
| --- | --- | --- |
| Claude Code | `@anthropic-ai/claude-code` | exact `2.1.206` |
| Codex | `@openai/codex` | exact `0.144.1` |
| OpenCode | `opencode-ai` | exact `1.17.18` |
| MiMoCode | `@mimo-ai/cli` | exact `0.1.5` |
| Antigravity | generation-pinned native artifact | exact `1.1.1` |

Antigravity is installed from a generation-pinned platform artifact whose
SHA-512 is tracked in the contract. The managed launcher exports
`AGY_CLI_DISABLE_AUTO_UPDATE=true`, so the verified binary cannot silently move
away from `1.1.1`.

Claude Code is also update-locked: both `DISABLE_AUTOUPDATER=1` and
`DISABLE_UPDATES=1` are exported by its managed wrapper and the managed shell
drop-in. A reviewed lock/contract update is the only supported upgrade path.

## Mandatory Browser Automation

Browser automation is a required platform layer, not an optional desktop app.

| Component | Pin | Contract |
| --- | --- | --- |
| CloakBrowser | `0.4.10` | only supported browser backend |
| Managed CDP service | `http://127.0.0.1:9222` | fixed loopback endpoint |
| Chrome DevTools MCP | `1.5.0` | wrapper supplies the fixed browser URL |
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

GUI mode installs Claude Desktop through its verified package channel and the
desktop font support used by the terminal environment. ChatGPT, Codex, and cmux
do not have supported Linux desktop builds, so their managed CLI surfaces remain
the supported Ubuntu path.

Ubuntu server never installs GUI applications.

### ZCode Integrity Gate

ZCode `3.3.3` is not installed automatically by default because upstream does
not publish a checksum or signature manifest.

- macOS: use the manual installation link from `scripts/auth-handoff.sh` after
  independently checking the artifact.
- Ubuntu GUI: either use the same manual path or provide a separately verified
  SHA-256 as `RLDYOUR_ZCODE_SHA256`. The installer verifies that value before
  installing the tracked package and fails on a mismatch.

Do not source the checksum from the same unverified artifact URL. The absence of
an upstream integrity manifest is a real trust boundary, not a best-effort
warning to bypass.

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

`show` documents owner-controlled sign-in for GitHub CLI, Codex/OpenAI, Claude
Code, OpenCode, MiMoCode, Antigravity, supported desktop applications, ZCode,
browser health, and cmux. `check` performs only non-secret CLI status probes and
reports `ok` or `pending`; it does not print account secrets.

Headless Codex authentication uses `codex login --device-auth`. Claude Code and
Antigravity can hand an OAuth URL/code exchange to a trusted desktop while the
original SSH terminal remains open.

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
notarized package. Claude Code, Codex, OpenCode, and MiMoCode install from a
tracked `bun.lock` with `--frozen-lockfile --ignore-scripts`; OpenCode runs its
locked native optional dependency directly instead of executing its fallback
postinstall. Codex also runs its lock-installed platform-native binary directly;
the managed wrapper removes inherited npm/Bun/pnpm provenance so diagnostics
and update behavior cannot target another global prefix. Antigravity uses generation-pinned native archives with tracked
SHA-512 values and a no-auto-update wrapper. RTK `0.43.0` uses a hash-pinned
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
