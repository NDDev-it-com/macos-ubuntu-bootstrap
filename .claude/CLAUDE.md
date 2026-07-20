# Claude Code Project Memory: rldyour macOS or Ubuntu Bootstrap

## Mission

Maintain one plan-first bootstrap adapter for:

- Apple Silicon macOS desktops, with or without GUI apps;
- Ubuntu 24.04/26.04 desktops, with or without GUI apps;
- headless Ubuntu 24.04/26.04 servers.

The public entry point is `scripts/bootstrap.sh`. Treat
`config/rldyour-contract.json`, the platform installers, verification scripts,
and tests as the executable contract. Current adapter version: `1.0.0`.

## Composition Invariants

Ubuntu profile selection is always explicit. Never infer server/rootful Docker
from `uname=Linux`; require `--profile desktop|server`.

- **macOS desktop (`arm64`):** GUI enabled or disabled, Docker `none`, policy
  `source-lsp-only`.
- **Ubuntu desktop (`amd64`/`arm64`):** GUI enabled or disabled, Docker `none`,
  policy `source-lsp-only`.
- **Ubuntu server (`amd64`/`arm64`):** headless, Docker `none`, `rootful`, or
  `rootless`; default `rootful`; policy `server-build-runtime`.

Desktop profiles do not provision Docker or configure local project build/runtime
execution. `--no-gui` is only an overlay switch. macOS cannot be a server
profile; Ubuntu server is always headless.

## Verified Pins

- Active harness set (one owner per harness, RVR-P1-004): `codex` and `zcode`,
  each installed by its authoritative NDDev module. Bootstrap installs no AI CLI
  inline or through a bun/npm global path.
  - `codex`: `nddev-codex-app` via `RLDYOUR_CODEX_MODULE` (safe setup by default;
    full-auto only with `RLDYOUR_CODEX_FULL_AUTO=1`; then `install-builder`).
  - `zcode`: `nddev-zcode-app` via `RLDYOUR_ZCODE_MODULE` (nddev-builder setup,
    module `--plan`/`--apply` lifecycle).
- RTK exact `0.43.0`, hash-pinned native artifact
- CloakBrowser `0.4.10`
- Chrome DevTools MCP `1.5.0`
- Playwright CLI `0.1.17`
- Webwright retired fail-closed; only the exact disabled compatibility wrapper
  is published
- Ubuntu Node.js/uv/Bun `24.18.0` / `0.11.28` / `1.3.14`, immutable assets
  with tracked architecture hashes

Keep the contract, both installers, tests, README, install guide, AGENTS, and
this file synchronized when a pin changes.
Do not use mutable unauthenticated installer scripts or live-unlocked dependency
resolution. Keep the AI CLI and Node-provider `bun.lock` files and the
CloakBrowser `uv.lock` frozen. AI package lifecycle scripts remain disabled.
Codex launches its lock-installed platform-native binary and the wrapper removes
inherited npm/Bun/pnpm provenance; do not restore the package-manager JS shim.

## Browser Boundary

CloakBrowser is required on every profile. A managed service owns the fixed
loopback CDP endpoint `http://127.0.0.1:9222`. The two active repository
wrappers force Chrome DevTools MCP and Playwright CLI through that endpoint and
require exact live runtime verification before browser actions. Webwright is
retired fail-closed and must never start Python or a browser.

Fail closed on missing or unhealthy browser state. Do not add or document:

- `--skip-browser` or `RLDYOUR_SKIP_CLOAKBROWSER`;
- an alternate executable, endpoint, or provider config;
- provider auto-start of Chrome/Chromium;
- a stock or embedded browser fallback;
- a non-loopback CDP listener.

Managed browser files use ownership markers. Preserve unmanaged files and fail
instead of replacing them. The sole adoption exception is a complete exact
match for the former rldyour CloakBrowser home, launcher pair, and service
template; migrate it only through the rollback-safe home/wrapper/service
transaction. Normalize Bun runtime permissions before publication, and rebuild
unsafe managed Node trees from the frozen lock while retaining the rejected
copy outside the active namespace.

## GUI And Authentication

- macOS GUI mode: Ghostty, cmux, ChatGPT, the separate Codex app, Claude Desktop.
- Ubuntu GUI mode: no bootstrap-installed harness apps; the ZCode desktop app is
  owned by its `nddev-zcode-app` module.
- Server: no GUI layer.

macOS GUI apply installs cmux hooks non-interactively only for Codex. Keep the
targeted `--yes` command; do not use broad interactive `cmux hooks setup`.

The ZCode app and CLI are owned by the `nddev-zcode-app` module and installed
through its own `--plan`/`--apply` lifecycle; bootstrap never installs ZCode via
an apt `.deb` or a `RLDYOUR_ZCODE_SHA256` gate.

Credentials are outside bootstrap ownership. Use:

```bash
bash scripts/auth-handoff.sh show
bash scripts/auth-handoff.sh check
```

The handoff must remain non-secret. It may describe owner-controlled login and
query status commands, but it must never read, print, store, or upload
credentials.

## Ubuntu Server Safety

Rootful Docker is the composed server default, but Docker group membership is
never automatic. UFW, key-only SSH, and Fail2ban are separate explicit opt-ins.

Preserve authorized-key preflight, `sshd -t` and effective-config checks,
rollback on validation/reload failure, SSH-rule-before-UFW ordering, Fail2ban
config validation, and post-apply server verification. Do not add generic
kernel or resource-limit tuning. Full evidence needs a real Ubuntu VM with
systemd and an external SSH/network check.

The full Ubuntu compositor must run as the non-root sudo-capable developer
account that owns the systemd-user CloakBrowser service. Preserve existing apt
package versions and healthy Docker workloads; fail on partial/custom Docker
state instead of upgrading over it. Managed Node.js, uv, and Bun require their
tracked receipts and exact user-local links.

Preserve the host's active/enabled `ssh.service` or `ssh.socket` choice. Do not
restart a socket-activated listener for authentication-only policy changes.
Managed shell policy belongs in versioned `~/.config/rldyour/` drop-ins; owner
dotfiles may only receive the backed-up, delimited source blocks.

## Key Paths

- `scripts/bootstrap.sh` - profile compositor.
- `scripts/lib/common.sh` - shared helpers and browser provisioning.
- `scripts/macos/*` - macOS install and verification.
- `scripts/ubuntu/install.sh` - Ubuntu profile composition.
- `scripts/ubuntu/server.sh` - sourceable server mutations and safety checks.
- `scripts/ubuntu/verify-server.sh` - read-only server verification.
- `scripts/auth-handoff.sh` - post-install authentication boundary.
- `docs/adr/0004-profile-composition-and-cloakbrowser-boundary.md` - accepted
  architecture decision.
- `docs/install.md` - operator guide.

## Workflows

Plan before apply:

```bash
bash scripts/bootstrap.sh --platform macos
bash scripts/bootstrap.sh --platform ubuntu --profile desktop
bash scripts/bootstrap.sh --platform ubuntu --profile server
```

Apply only after plan review:

```bash
bash scripts/bootstrap.sh --platform macos --apply
bash scripts/bootstrap.sh --platform ubuntu --profile desktop --apply
bash scripts/bootstrap.sh --platform ubuntu --profile server --apply
```

Supported skip flags: `--skip-system`, `--skip-ai`, `--skip-lsps`, and
`--skip-checks`. Browser provisioning is mandatory.

Validation:

```bash
bash scripts/ci/lint.sh
bash scripts/ci/validate.sh
python3 -m pytest
```

Use `bash -n` and `shellcheck -x` for targeted shell changes. Run strict
platform verification on the corresponding real OS when behavior changes.
Never claim runtime evidence that was not produced.

Release automation accepts a numeric tag push or an exact numeric
`workflow_dispatch` version. Manual dispatch must target current `origin/main`,
require its successful `bootstrap-gate`, and must verify an already existing
exact non-rewritten tag. Root automation remains the sole tag creator;
immutable publication is delegated to the pinned reusable supply-chain
workflow.

## Change Discipline

- Keep changes scoped and preserve unrelated dirty-worktree edits.
- Reuse shared helpers; keep sourceable server APIs namespaced and side-effect
  free until their main function is invoked.
- Never pipe remote code directly to a shell.
- Update managed files atomically; preserve and reject unmanaged conflicts.
- Do not weaken mandatory checks into warnings or best-effort fallbacks.
- Never commit secrets, browser profiles, traces, caches, runtime markers, or
  local authentication state.
