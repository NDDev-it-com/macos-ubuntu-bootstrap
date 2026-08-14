# macOS and Ubuntu bootstrap contributor instructions

This repository owns plan-first installation and verification for Apple Silicon
macOS, Ubuntu 24.04/26.04 desktops, and Ubuntu 24.04/26.04 servers.

The sources of truth are `scripts/bootstrap.sh`, `scripts/lib/common.sh`, the
platform installers/verifiers, `config/rldyour-contract.json`, `README.md`, and
`SECURITY.md`. Keep implementation, verification, contract, tests, docs,
`VERSION`, and `CHANGELOG.md` synchronized.

`config/support-evidence-matrix.json` owns clean-system support compositions,
typed evidence tiers, and required-versus-optional proof. Device-integrity
receipts report the state of one installed device; they do not redefine platform
support or promote container/structural observations to native-host evidence.
`scripts/device_integrity.py` is written by apply after strict verification
passes and read back by `verify.sh --strict`; ADR 0007 records both call sites
and what the receipt does and does not assert. `harnesses.detection` in the
contract is what makes one-owner-per-harness checkable — do not describe an
enforcement this repository cannot observe.

## Contract 3.0.1

- macOS supports `desktop`, with optional GUI, no Docker, and source-analysis
  plus local-check tooling.
- Ubuntu requires explicit `desktop`, `desktop-builds`, or `server` selection.
- Ubuntu GUI is supported on `amd64`; `arm64` supports the same profiles with
  GUI disabled because Chrome and Telegram publish no compatible Linux builds.
- Ubuntu `desktop` has no Docker; `desktop-builds` adds rootful Docker for local
  builds/tests without the server baseline.
- Ubuntu `server` is headless, defaults to rootful Docker, and supports explicit
  `rootless` or `none` alternatives.
- All profiles receive Codex CLI, Claude Code, Grok Build, zsh configuration,
  modern terminal tools, source-quality tools, and applicable language servers.
- `terminal_tools` in the contract owns the interactive tool boundary. Every
  command `templates/terminal/zshrc` guards must appear in `shared` and be
  published by both installers; `macos_only` entries each carry a reason. Do
  not add a guard for a tool one platform does not install — the guard makes it
  a silent no-op rather than an error, which is how six such guards survived.
- `cx`, `cl`, and `gk` invoke the three AI CLIs in their documented unrestricted
  modes. Keep the ordinary vendor commands unchanged.
- Google Chrome stable is the only installed browser. macOS GUI installs
  ChatGPT, Claude, Ghostty, cmux, RustDesk, and Telegram. Ubuntu GUI installs
  Chrome, RustDesk, Telegram, and removes Firefox.
- Herdr 0.8.0 is installed from the official, checksum-pinned GitHub release
  asset on macOS and every Ubuntu profile; `config/rldyour-contract.json` owns
  its tag, source URLs, architecture hashes, and receipt identities. Never
  substitute a downstream Homebrew formula for that exact managed artifact,
  even when its version has caught up. Telegram is GUI-only and is installed
  on supported Linux architectures.

## Implementation rules

- Keep entrypoints strict, idempotent, plan-aware, and non-interactive.
- Never pipe a network response into a shell. Download, verify reviewed integrity
  metadata, then execute.
- Use atomic managed-file updates. Preserve unmanaged/user-modified files.
- Never read, print, store, upload, or synthesize authentication credentials.
- Keep desktop source/check manifests free of deployment orchestration. Keep
  server runtime and hardening in `scripts/ubuntu/server.sh`.
- Preserve exact runtime receipts and architecture hashes for fixed artifacts.
- Do not add mutable dependency resolution where a frozen/pinned path exists.
- macOS Homebrew formulae and casks are **intentionally rolling** (ADR 0010).
  Ubuntu pins exact artifacts; the platforms differ and
  `macos_package_determinism` in the contract records the class of every macOS
  package. Anything whose exact bytes matter is not a Homebrew package -- that is
  why Herdr comes from a checksum-pinned release asset. Provenance metadata may
  claim only what a resolver can establish locally; never re-add a frozen
  `executable_sha256` for a rolling formula, because homebrew-core rebuilds move
  it and freezing it turns an ordinary upstream event into a red required check.

## Ubuntu server safeguards

The full compositor runs as the non-root sudo-capable owner. Never grant Docker
group membership automatically. UFW, key-only SSH, and Fail2ban are independent
opt-ins. Validate SSH syntax and live contexts before reload, preserve the active
service/socket provider, add the SSH allow rule before enabling UFW, validate
Fail2ban before restart, and roll back failed managed changes. Do not upgrade
existing packages or healthy Docker implicitly.

## Verification

```bash
bash scripts/ci/lint.sh
bash scripts/ci/run-clean-validation.sh
python3 -m pytest
```

`run-clean-validation.sh` is the only supported entrypoint, and it is what
`.github/workflows/ci.yml` runs. It resolves the validation path from a clean
`PATH` before delegating to `scripts/ci/validate.sh`, which refuses to run
without that resolution and exits 2. Do not invoke `validate.sh` directly: it
is the inner half, not the command.

Use the strict platform verifiers on real target machines when platform behavior
changes. Do not claim runtime evidence that was not produced.

Preserve unrelated worktree changes. Use atomic Conventional Commits when
committing. This public repository executes untrusted fork PR code; reusable
workflow callers with a `runner` input must explicitly pass `ubuntu-latest`.
