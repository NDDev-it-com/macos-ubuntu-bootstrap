# macOS / Ubuntu Bootstrap

Plan-first bootstrap automation for Apple Silicon macOS desktops, Ubuntu
24.04/26.04 desktops, and headless Ubuntu 24.04/26.04 servers.

## Current Baseline

The adapter contract version is `0.3.10`.

| Field | Value |
| --- | --- |
| Adapter version | `0.3.10` |
| Runtime baseline | macOS arm64 and Ubuntu 24.04/26.04 amd64/arm64 |
| GitHub release tag | `0.3.10` |

## What This Repository Provides

- **macOS Apple Silicon:** desktop, GUI or no GUI, Docker `none`, source/LSP
  only.
- **Ubuntu 24.04/26.04 desktop (`amd64`/`arm64`):** GUI or no GUI, Docker
  `none`, source/LSP only.
- **Ubuntu 24.04/26.04 server (`amd64`/`arm64`):** headless, server
  build/runtime, Docker `none`, `rootful`, or `rootless`; default `rootful`.

Desktop profiles install source-analysis tools, LSPs, quality checks, terminal
tooling, AI CLIs, and the mandatory browser layer. They do not install Docker
or configure local project build/runtime execution. Node and Python are tool
hosts, and the macOS clangd provider arrives in Homebrew's LLVM distribution;
those supporting binaries do not authorize local project builds.

On Ubuntu, Node.js `24.18.0`, uv `0.11.28`, and Bun `1.3.14` are installed from
versioned upstream assets with tracked per-architecture SHA-256 values. macOS
bootstraps Homebrew from its notarized `6.0.9` package. The four registry-backed
AI CLIs install from a repository-owned Bun lock with lifecycle scripts disabled.
Antigravity uses a generation-pinned native artifact and disables self-update.
Browser Node providers and CloakBrowser also use tracked locks with frozen
artifact hashes.

Ubuntu tool-host artifacts always install into owned versioned directories
with archive/hash receipts and managed `~/.local/bin` links. A same-version
binary elsewhere on `PATH` is preserved but never accepted as provenance;
unmarked or tampered managed destinations fail closed. Existing apt packages,
Python tools, Bun source tools, and healthy Docker CE installations are not
implicitly upgraded on a rerun. Existing Homebrew formulae and casks are also
preserved; macOS installs only missing baseline entries.

The Ubuntu server profile adds the build/runtime baseline and an explicit Docker
mode. macOS does not support the server profile.

## Active Catalog

| CLI | Managed version |
| --- | --- |
| Claude Code | `2.1.206` |
| Codex | `0.144.1` |
| OpenCode | `1.17.18` |
| MiMoCode | `0.1.5` |
| Antigravity (`agy`) | exact `1.1.1`, self-update disabled |
| RTK output compressor | exact `0.43.0`, hash-pinned artifact |

The exact sources of truth are `config/rldyour-contract.json`,
`scripts/macos/install.sh`, and `scripts/ubuntu/install.sh`.

Claude's managed launcher and shell environment set both
`DISABLE_AUTOUPDATER=1` and `DISABLE_UPDATES=1`; Antigravity sets
`AGY_CLI_DISABLE_AUTO_UPDATE=true`. Exact runtime pins therefore remain under
repository control instead of drifting through a background or manual updater.
The Codex launcher executes the lock-installed platform-native binary directly
and removes inherited npm/Bun/pnpm provenance. This preserves bundled Codex
resources while preventing diagnostics or update actions from targeting an
unrelated global package-manager prefix.

## Native Boundaries

The bootstrap owns versioned drop-ins under `~/.config/rldyour/` and adds one
small source block to `~/.zshenv` and `~/.zprofile`. Existing owner content is
preserved byte-for-byte outside that block and backed up under
`~/.local/share/rldyour/backups/shell/` before the first change. Symlinks,
non-regular paths, duplicate markers, and malformed blocks fail closed.

Post-apply verification starts a fresh `zsh -l -c` and proves that
`~/.local/bin` has precedence, every managed CLI/browser command resolves from
that directory, the fixed CloakBrowser endpoint is active, forbidden trust
overrides are unset, and managed updater policy is present.

## Install / Update / ry-repair

Plan mode is the default and does not mutate the target:

```bash
# macOS desktop with GUI apps
bash scripts/bootstrap.sh --platform macos

# macOS desktop without GUI apps
bash scripts/bootstrap.sh --platform macos --no-gui

# Ubuntu server, headless, rootful Docker within the explicit server profile
bash scripts/bootstrap.sh --platform ubuntu --profile server

# Ubuntu desktop with GUI apps
bash scripts/bootstrap.sh --platform ubuntu --profile desktop

# Ubuntu desktop without GUI apps
bash scripts/bootstrap.sh --platform ubuntu --profile desktop --no-gui
```

Apply only after reviewing the plan:

```bash
bash scripts/bootstrap.sh --platform macos --apply
bash scripts/bootstrap.sh --platform ubuntu --profile desktop --apply
bash scripts/bootstrap.sh --platform ubuntu --profile server --apply
```

The same apply command is the supported update and repair path: it revalidates
owned receipts, preserves unmanaged or user-modified state, and changes only
missing or contract-divergent managed artifacts. The `ry-repair` workflow must
use these repository entry points rather than reproducing installation logic.

Run the full Ubuntu bootstrap while logged in as the non-root developer account
that will own `~/.local`, AI configuration, and the CloakBrowser user service;
the account must have sudo. Root-only/cloud-init administration may run the
sourceable `scripts/ubuntu/server.sh` baseline separately, but the full composed
bootstrap rejects `EUID=0` instead of installing user state under `/root` and
failing late at `systemctl --user`.

Server Docker alternatives are explicit:

```bash
bash scripts/bootstrap.sh --platform ubuntu --profile server --docker-mode none
bash scripts/bootstrap.sh --platform ubuntu --profile server --docker-mode rootless
```

Ubuntu always requires an explicit `--profile desktop|server`; Linux alone is
not enough information to infer a safe Docker/runtime role. Supported layer
controls are `--skip-system`, `--skip-ai`, `--skip-lsps`, and `--skip-checks`.
Browser automation cannot be skipped.

See [docs/install.md](docs/install.md) for the complete profile, GUI, Docker,
hardening, verification, and authentication handoff guidance.

## Browser / Design / DevTools Routing

Every profile installs the same fail-closed browser stack:

- CloakBrowser `0.4.10` in an isolated environment;
- a managed headless service fixed to `http://127.0.0.1:9222`;
- Chrome DevTools MCP `1.5.0`;
- Playwright CLI `0.1.17`;
- an exact disabled `webwright` compatibility wrapper that exits `78` without
  starting Python or a browser.

The only active providers are Playwright CLI and Chrome DevTools MCP. Managed
wrappers force both through the fixed loopback CDP endpoint and run the exact
health check before browser actions. Playwright `run-code` and `--filename`
escape hatches, alternate executables/endpoints/configuration, auto-started
stock browsers, and stock Chromium fallbacks are rejected. Every successful
apply publishes a canonical owner-only runtime receipt; verify it with
`bash scripts/verify-browser-runtime.sh`. `--skip-browser` and
`RLDYOUR_SKIP_CLOAKBROWSER=1` are unsupported.

Design and UI work remains source/LSP-only on desktops. Any browser-visible
validation must route through one of the two active managed providers; embedded
browser agents, Playwright MCP, raw Playwright, and product-specific browser
fallbacks are outside this boundary.

The CDP endpoint must remain loopback-only because CDP grants full control over
browser pages, cookies, storage, and JavaScript execution.

## GUI Application Support

GUI is an overlay on desktop profiles and can be disabled with `--no-gui`.

- macOS GUI mode installs Ghostty, cmux, ChatGPT, the separate Codex desktop
  app, and Claude Desktop.
- Ubuntu GUI mode installs Claude Desktop. ChatGPT, Codex, and cmux do not have
  supported Linux desktop builds; their managed CLIs remain available.
- Ubuntu server is always headless.

ZCode is manual by default on both platforms because upstream does not publish
a checksum or signature manifest. Ubuntu can install tracked ZCode `3.3.3` only
when the owner supplies a separately verified SHA-256 through
`RLDYOUR_ZCODE_SHA256`; otherwise use the documented manual handoff. The
bootstrap does not weaken this integrity gate for convenience.

## Authentication Handoff

The bootstrap never reads, prints, stores, or uploads provider credentials.
After installation, display the owner-controlled sign-in steps and check the
non-secret CLI status probes:

```bash
bash scripts/auth-handoff.sh show
bash scripts/auth-handoff.sh check
```

The handoff covers GitHub, Codex/OpenAI, Claude Code, OpenCode, MiMoCode,
Antigravity, supported desktop applications, ZCode, cmux, and the browser health
boundary.

## Ubuntu Server Safety

The default Ubuntu server composition uses rootful Docker, but Docker group
membership is never granted automatically because it is root-equivalent.
Rootless Docker is available only when its networking, cgroup, storage, and
privileged-port limitations are acceptable.

Firewall and SSH mutations are never inferred. These server-only options must
be selected explicitly on an apply run:

```bash
bash scripts/bootstrap.sh \
  --platform ubuntu \
  --profile server \
  --apply \
  --harden-ssh \
  --enable-ufw \
  --with-fail2ban
```

Before key-only SSH is enabled, the server module requires a non-root account
with an `ssh-keygen`-parseable key and StrictModes-safe ownership/permissions.
It evaluates the candidate OpenSSH policy against the full live connection
tuple (`user`, client host/address, local address/port), checks the root context
separately, and restores the prior managed drop-in if validation or reload
fails. Outside an SSH session, explicit Match addresses are required. Keep the
current session open until a second SSH connection succeeds.
UFW adds the SSH allow rule before enabling the firewall. Docker-published ports
still require host-specific exposure review.

The baseline preserves the host's existing `ssh.service` versus `ssh.socket`
activation choice. Authentication-only hardening reloads an active service;
for socket-only hosts, future socket-activated processes read the validated
configuration without restarting the listener or changing its port semantics.
Existing synchronized, NTP, or PTP time providers are preserved. Fail2ban
activation validates the live sshd jail and rolls configuration and service
state back if enablement or restart fails.

## Repository Context / Serena Memory

- `scripts/bootstrap.sh` - public profile compositor and entry point.
- `scripts/macos/install.sh`, `scripts/ubuntu/install.sh` - platform installers.
- `scripts/ubuntu/server.sh` - sourceable Ubuntu server build/runtime and
  safety layer.
- `scripts/macos/verify.sh`, `scripts/ubuntu/verify.sh` - composed target
  verification.
- `scripts/ubuntu/verify-server.sh` - read-only server verification.
- `scripts/auth-handoff.sh` - non-secret post-install sign-in handoff.
- `config/rldyour-contract.json` - machine-readable target and pin contract.
- `docs/adr/0004-profile-composition-and-cloakbrowser-boundary.md` - profile
  and browser decision.
- `templates/terminal/`, `templates/browser/` - managed runtime templates.
- `.serena/memories/CORE-01-INDEX.md` - durable architecture and entry points.
- `.serena/memories/RELEASE-01-VALIDATION.md` - release and verification facts.
- `.serena/memories/TECHDEBT-01-NOW.md` - verified current debt only; remove
  resolved items instead of preserving historical speculation.

## Validation

```bash
bash scripts/ci/lint.sh
bash scripts/ci/validate.sh

bash scripts/macos/verify.sh --strict
bash scripts/ubuntu/verify.sh --strict
bash scripts/ubuntu/verify-server.sh --docker-mode rootful
```

Full server verification requires a real Ubuntu VM with systemd. Container-only
CI cannot prove SSH reachability, firewall exposure, time synchronization, or
Docker daemon state.

## Release / Rollback

Numeric tag pushes remain the primary release path. A manual
`workflow_dispatch` accepts only the exact numeric value from `VERSION`, must
run at the current `origin/main` commit with a successful `bootstrap-gate`, and
requires an already existing tag that resolves to that exact commit. It never
creates or rewrites a tag; root release automation is the sole tag creator. The
pinned reusable supply-chain workflow then publishes one immutable release
with checksums, an SPDX SBOM, and attestations.

Rollback uses a previously reviewed numeric release: check out that tag, run a
plan, and apply the matching contract. Never move or recreate a published tag,
and never force-push `main`.

## Security Boundary

No credentials belong in this repository. Runtime-local caches, browser
profiles, traces, tokens, and authentication state must remain untracked.

See [SECURITY.md](SECURITY.md) for private reporting, supply-chain controls,
the CDP boundary, and Ubuntu server hardening constraints.

## Support / License

- License: [AGPL-3.0-or-later](LICENSE)
- Security reports: [GitHub Security Advisories](https://github.com/NDDev-it-com/macos-ubuntu-bootstrap/security/advisories/new)
- Issues: [NDDev-it-com/macos-ubuntu-bootstrap](https://github.com/NDDev-it-com/macos-ubuntu-bootstrap/issues)
- Releases: [release history](https://github.com/NDDev-it-com/macos-ubuntu-bootstrap/releases)
