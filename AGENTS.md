# rldyour macOS or Ubuntu Bootstrap

## Purpose

This repository owns plan-first bootstrap and verification for the rldyour AI
CLI environment on Apple Silicon macOS desktops, Ubuntu 24.04/26.04 desktops,
and headless Ubuntu 24.04/26.04 servers.

It is an adapter, not an upstream AI runtime. Keep installation logic,
verification, contract metadata, tests, and documentation synchronized.

## Sources Of Truth

- Public compositor: `scripts/bootstrap.sh`
- Shared helpers and managed browser layer: `scripts/lib/common.sh`
- macOS installer/verifier: `scripts/macos/install.sh`, `scripts/macos/verify.sh`
- Ubuntu installer/verifier: `scripts/ubuntu/install.sh`, `scripts/ubuntu/verify.sh`
- Ubuntu server module/verifier: `scripts/ubuntu/server.sh`, `scripts/ubuntu/verify-server.sh`
- Authentication handoff: `scripts/auth-handoff.sh`
- Machine-readable contract: `config/rldyour-contract.json`
- Profile/browser decision: `docs/adr/0004-profile-composition-and-cloakbrowser-boundary.md`
- Operator guide: `README.md`, `docs/install.md`, `SECURITY.md`
- Product version: `VERSION`, `CHANGELOG.md`

When prose and implementation disagree, verify the scripts and contract, then
update the affected documentation in the same change. Do not invent a second
policy source.

## Contract `1.0.0`

Ubuntu profile selection is always explicit. Never infer server/rootful Docker
from `uname=Linux`; require `--profile desktop|server`.

Supported compositions:

- Apple Silicon macOS: `desktop`, GUI enabled or disabled, Docker `none`,
  `source-lsp-only`.
- Ubuntu 24.04/26.04 `amd64` or `arm64` desktop: GUI enabled or disabled,
  Docker `none`, `source-lsp-only`.
- Ubuntu 24.04/26.04 `amd64` or `arm64` server: headless, Docker
  `none|rootful|rootless`, default `rootful`, `container-execution-only` (project
  builds/tests run inside Docker; the host installs no build toolchain or SDKs).

macOS never accepts the server profile. Desktop profiles never install Docker
or configure local project build/runtime execution. `--no-gui` removes only
the GUI overlay; it does not change the desktop execution policy. Server is
Ubuntu-only and always headless.

## Managed Versions

These values must match both platform installers, the contract, tests, and
operator documentation:

- Active harness set (one owner per harness, RVR-P1-004): `codex` and `zcode`.
  Bootstrap installs no AI CLI inline and never through a bun/npm global path.
  Each harness is owned by its authoritative NDDev module, whose materialized
  checkout GDS device bootstrap passes in an env var:
  - `codex`: `nddev-codex-app` (`RLDYOUR_CODEX_MODULE`); `install-cli`, then
    `apply --setup safe` (full-auto only via `RLDYOUR_CODEX_FULL_AUTO=1`), then
    `install-builder`.
  - `zcode`: `nddev-zcode-app` (`RLDYOUR_ZCODE_MODULE`); `bootstrap` then
    `install --setup nddev-builder` through the module's `--plan`/`--apply`
    lifecycle.
- RTK: exact `0.43.0`, hash-pinned native artifact
- CloakBrowser: `0.4.10`
- Chrome DevTools MCP: `1.5.0`
- Playwright CLI: `0.1.17`
- Webwright: retired fail-closed; publish only the exact disabled wrapper
- Ubuntu Node.js/uv/Bun: `24.18.0` / `0.11.28` / `1.3.14`, immutable assets
  with tracked architecture hashes

Use current, source-backed facts before changing a dependency. Preserve exact
pins and integrity checks unless the change intentionally updates the contract.
Never reintroduce mutable, unauthenticated remote installer execution or
unfrozen dependency resolution. The Node browser providers use
`templates/browser/provider/bun.lock`; CloakBrowser uses its tracked `uv.lock`.
The codex and zcode harnesses own their standalone artifacts inside their
modules; never reintroduce an inline AI-CLI bundle or a bun/npm global install.

The codex and zcode harnesses stay update-locked: `DISABLE_AUTOUPDATER=1` and
`DISABLE_UPDATES=1` keep the codex module's standalone binary from drifting.

## Non-Negotiable Browser Boundary

CloakBrowser is mandatory on every profile. A managed launchd or systemd user
service owns `http://127.0.0.1:9222`. Chrome DevTools MCP, Playwright CLI, and
the exact disabled Webwright tombstone are repository-managed. Only Chrome
DevTools MCP and Playwright CLI are active and may use the fixed endpoint;
Webwright must exit `78` without starting Python or a browser.

There is no supported `--skip-browser`, `RLDYOUR_SKIP_CLOAKBROWSER`, alternate
browser executable, alternate endpoint, auto-started stock browser, or stock
Chromium fallback. Playwright `run-code` and `--filename` are also forbidden.
Missing, unhealthy, or receipt-divergent browser state must fail closed. Never
bind the CDP listener beyond loopback. Use `scripts/verify-browser-runtime.sh`
as the exact installed-runtime authority.

Preserve unmanaged browser files and fail instead of adopting or replacing
them. The only adoption exception is the complete byte/shape-verified legacy
rldyour CloakBrowser home, launcher pair, and service template. Its migration
must snapshot the home, all six browser wrappers, and active service state;
failed handoff must restore them transactionally. Browser Node staging must
remove group/world-write bits before publication and rebuild an already unsafe
managed runtime from the frozen lock while preserving the rejected tree.
Runtime browser profiles, traces, caches, tokens, and service state must never
be committed.

## GUI And Integrity Boundaries

- macOS GUI: Ghostty, cmux, ChatGPT, and the separate Codex app.
- Ubuntu GUI: no bootstrap-installed harness apps; the ZCode desktop app is
  installed by its `nddev-zcode-app` module.
- Ubuntu server: no GUI applications.

macOS GUI apply configures cmux non-interactively only for Codex. Do not replace
that targeted `--yes` install with broad interactive `cmux hooks setup`, which
can create unrelated agent configs.

ZCode `3.3.3` remains manual by default because upstream publishes no checksum
or signature manifest. On Ubuntu, installation is allowed only when the owner
supplies a separately verified `RLDYOUR_ZCODE_SHA256`. Do not add a silent
download, fallback checksum, or integrity bypass.

Authentication is a post-install owner handoff. `scripts/auth-handoff.sh` may
show instructions and perform non-secret status probes, but bootstrap code must
not read, print, store, upload, or synthesize credentials.

## Ubuntu Server Safety

Plan mode is the default. Rootful Docker is the composed server default, but
the installer never grants Docker group membership. Rootless and `none` remain
explicit alternatives.

The full Ubuntu compositor runs as the non-root sudo-capable developer account
that owns its home and systemd-user browser service. Root-only automation may
use the sourceable server layer, not install AI state under `/root`.

UFW, key-only SSH, and Fail2ban are independent explicit opt-ins. Never infer
them from the server profile. Preserve these safeguards:

- require a non-root account with a readable supported public key before
  disabling password authentication;
- require `ssh-keygen` parsing and StrictModes-safe key path metadata;
- validate OpenSSH syntax and full `sshd -T -C` user/client/local connection
  contexts before reload, including a separate root context;
- preserve the active/enabled `ssh.service` versus `ssh.socket` provider and
  never restart a socket for authentication-only changes;
- restore the previous managed SSH drop-in after validation or reload failure;
- add the SSH allow rule before enabling UFW;
- validate the Fail2ban jail before restart;
- restore prior Fail2ban file/service state after activation failure;
- preserve existing synchronized NTP/PTP providers;
- warn operators to keep the current SSH session open until a second connection
  succeeds;
- do not pretend UFW alone contains Docker-published ports;
- do not add generic sysctl or resource-limit tuning without a separate,
  host-specific decision.
- never upgrade apt packages or an existing healthy Docker runtime implicitly;
  fail on partial/custom Docker state.

Full server validation requires a real supported Ubuntu VM with systemd.

## Implementation Rules

- Keep shell entry points strict, idempotent, plan-aware, and non-interactive
  unless an explicit owner handoff is the purpose.
- Never pipe a remote network stream directly into a shell. Download to a
  temporary file, verify available integrity metadata, then execute.
- Update managed files atomically. Preserve unmanaged or user-modified files
  and fail with a clear explanation.
- Keep shell policy in owned `~/.config/rldyour/` drop-ins. Modify owner shell
  files only through the delimited, backed-up source blocks and verify a fresh
  login shell after apply.
- Ubuntu Node.js, uv, and Bun must retain verified runtime receipts and exact
  managed links; an external same-version PATH binary is not provenance.
- APT key validation must reject bundles with more than one primary key.
- Keep desktop source/LSP manifests free of Docker and general project runtime
  dependencies.
- Keep server build/runtime and hardening behavior in the Ubuntu server layer.
- Prefer existing shared helpers and namespaced server functions over duplicate
  shell logic.
- Do not swallow errors, fake successful checks, or downgrade mandatory checks
  to best-effort behavior.
- Do not commit credentials, `.env` files, local browser state, caches, traces,
  diagnostics output, or runtime markers.

## Common Commands

Plan:

```bash
bash scripts/bootstrap.sh --platform macos
bash scripts/bootstrap.sh --platform macos --no-gui
bash scripts/bootstrap.sh --platform ubuntu --profile desktop
bash scripts/bootstrap.sh --platform ubuntu --profile server
```

Apply:

```bash
bash scripts/bootstrap.sh --platform macos --apply
bash scripts/bootstrap.sh --platform ubuntu --profile desktop --apply
bash scripts/bootstrap.sh --platform ubuntu --profile server --apply
```

Supported skip flags are `--skip-system`, `--skip-ai`, `--skip-lsps`, and
`--skip-checks`. Do not document a browser skip.

Authentication handoff:

```bash
bash scripts/auth-handoff.sh show
bash scripts/auth-handoff.sh check
```

## Verification Gates

Run checks matching the touched scope and report exact commands:

```bash
bash scripts/ci/lint.sh
bash scripts/ci/validate.sh
python3 -m pytest
```

Use platform verification on real targets when platform behavior changes:

```bash
bash scripts/macos/verify.sh --strict
bash scripts/ubuntu/verify.sh --strict
bash scripts/ubuntu/verify-server.sh --docker-mode rootful
```

For documentation-only changes, at minimum run `git diff --check` and targeted
stale-fact scans. Do not claim macOS, Ubuntu GUI, SSH, firewall, systemd, or
Docker runtime evidence that was not actually produced.

## Git And Delivery

- Preserve unrelated user changes in a dirty worktree.
- Use atomic Conventional Commits when commits are requested.
- Keep implementation, tests/validators, docs/policy, and generated metadata
  independently reviewable when practical.
- Do not force-push `main` or rewrite pushed history without explicit approval.
- Releases support numeric tag pushes and a numeric `workflow_dispatch` input.
  Manual dispatch must use the exact `origin/main` commit, require its green
  `bootstrap-gate`, and verify an already existing exact non-rewritten tag.
  Root automation is the sole tag creator; the pinned reusable workflow owns
  immutable release publication.
- Move any superproject gitlink only after this repository's changes are pushed
  and verified.
