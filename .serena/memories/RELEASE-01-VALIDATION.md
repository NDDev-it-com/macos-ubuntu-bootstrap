<!-- Memory Metadata
Last updated: 2026-07-10
Last verified: 2026-07-10
Last commit: 42658c2 ci(pytest): cancel superseded workflow runs
Scope: README.md, VERSION, CHANGELOG.md, config/rldyour-contract.json, scripts/**, templates/**, tests/**, .github/workflows/**
Area: RELEASE
-->

# RELEASE-01-VALIDATION

## Scope
Release, validation, CI, and public README contract for the macOS/Ubuntu bootstrap module.

## Applies to
- `README.md`
- `VERSION`
- `CHANGELOG.md`
- `config/rldyour-contract.json`
- `scripts/bootstrap.sh`
- `scripts/macos/install.sh`
- `scripts/ubuntu/install.sh`
- `scripts/macos/verify.sh`
- `scripts/ubuntu/verify.sh`
- `.github/workflows/**`

## Source of truth
- `VERSION` and `config/rldyour-contract.json`: canonical product/config version source of truth (see the Current State section for the live value).
- `CHANGELOG.md`: dated release entries per version, with an empty `[Unreleased]` section.
- `scripts/bootstrap.sh`: platform selector for `macos` and `ubuntu`.
- `scripts/macos/install.sh` and `scripts/ubuntu/install.sh`: OS-specific installer profiles.
- `scripts/macos/verify.sh` and `scripts/ubuntu/verify.sh`: per-platform verification gates.
- `scripts/ubuntu/server.sh` and `scripts/ubuntu/verify-server.sh`: explicit Ubuntu server mutation and read-only verification surfaces.
- `templates/ai-cli/` and `templates/browser/`: frozen runtime manifests, locks, and fail-closed provider configuration.
- `.github/workflows/**`: CI, security, dependency, scorecard, cross-platform, and release workflows.

## Invariants
- Installer default mode is plan/dry-run; `--apply` is required for mutation.
- Runtime pins stay synchronized across README, installer scripts, and contract.
- Release automation accepts numeric tag pushes or an exact numeric manual dispatch; both must match `VERSION` plus `CHANGELOG.md` and resolve an immutable exact tag.
- Public security workflows remain enabled for the public repository posture.
- Browser automation always resolves through the managed CloakBrowser endpoint; stock-browser fallback, alternate endpoints, and Playwright arbitrary code/file execution are rejected.
- Playwright CLI and Chrome DevTools MCP are the only active providers. Webwright is retired fail-closed behind an exact wrapper that exits `78` without Python or browser execution.
- Successful apply publishes an owner-only canonical receipt binding exact runtimes, binaries, wrappers, service definition, repository policies, and rigorous live health. `scripts/verify-browser-runtime.sh` is the installed-state authority.
- Existing unmanaged state is preserved. Managed runtime and service publication is content-addressed, health-gated, and rollback-aware.
- Exact legacy CloakBrowser adoption is a one-time transaction: the prior home, all six browser wrappers, and service state are snapshotted and restored on failure; arbitrary unmanaged state is never adopted.
- launchd forward and rollback handoffs use bounded loaded/unloaded state convergence instead of treating an immediate `launchctl` exit status as proof.

## Current State
- Current product/config version is `0.3.10`.
- Supported targets are Apple Silicon macOS desktop and Ubuntu 24.04/26.04 desktop/server on amd64 or arm64. Desktop Docker mode is always `none`; server Docker is explicit `none`, `rootful`, or `rootless`.
- Exact AI pins are Claude Code `2.1.206`, Codex CLI `0.144.1`, OpenCode `1.17.18`, MiMoCode `0.1.5`, and Antigravity `1.1.1` with self-update disabled.
- The mandatory browser baseline is CloakBrowser `0.4.12`, Chrome DevTools MCP `1.6.0`, and Playwright CLI `0.1.17` on loopback CDP `127.0.0.1:9222`; Webwright has no installed runtime or dependency tree.
- AI, browser Node, and CloakBrowser runtimes install from repository-owned frozen locks into content-addressed directories before an atomic wrapper/service/receipt handoff.
- Browser Node staging removes group/world-write permission bits before publication. An already published runtime with unsafe permissions is preserved outside the active namespace and rebuilt from the frozen lock.
- Ubuntu server hardening is opt-in. SSH key/algorithm/Match context, UFW operator CIDR, Docker ownership, APT key identity, time service, Fail2ban, systemd linger, and rollback state are validated fail closed.
- Existing Homebrew/APT packages and healthy Docker workloads are preserved instead of implicitly upgraded.
- `--skip-system` bypasses both the Ubuntu workstation package layer and the composed server baseline/Docker layer before any host inventory probes; normal server plan/apply paths retain their fail-closed checks.
- macOS GUI mode installs ChatGPT and the separate Codex desktop app through independent Homebrew casks. No-GUI, Ubuntu, and server profiles do not install the Codex desktop app.
- Local CI entrypoints are `bash scripts/ci/lint.sh` and `bash scripts/ci/validate.sh`.
- Managed shell scripts use explicit conditionals for compound control flow; a static regression test rejects the ambiguous `[ A ] && [ B ] || { fallback; }` form before hosted ShellCheck runs.
- Pinned `raven-actions/actionlint` steps rely on supported default workflow discovery. Regression coverage scans every Raven actionlint use and rejects the unsupported `args` input that GitHub would annotate.
- The dedicated pytest workflow cancels superseded runs for the same workflow/ref while keeping different refs isolated.
- Manual release dispatch maps its version input through the environment, rejects non-canonical numeric SemVer, requires the exact current `origin/main` commit and its successful `bootstrap-gate`, and verifies an already existing exact non-rewritten tag in a read-only job. Root release automation is the sole tag creator; the pinned reusable workflow owns immutable publication.
- The verified pre-release local implementation gate is 74 pytest tests plus lint, validate, ShellCheck, strict real-host macOS apply, immediate non-interactive idempotent reapply, and diff checks. Hosted validation/release jobs provision ShellCheck and ripgrep, while every hosted pytest surface provisions Zsh for terminal portability coverage. Live hosted GitHub status remains a separate check before publication.

## Evidence
- path:VERSION
- path:CHANGELOG.md
- path:config/rldyour-contract.json
- path:scripts/bootstrap.sh
- path:scripts/browser_runtime_integrity.py
- path:scripts/verify-browser-runtime.sh
- path:scripts/ci/validate.sh
- path:scripts/macos/install.sh
- path:scripts/ubuntu/install.sh
- path:scripts/ubuntu/server.sh
- path:scripts/ubuntu/verify-server.sh
- path:templates/ai-cli/bun.lock
- path:templates/browser/cloakbrowser-uv.lock
- path:.github/workflows/ci.yml
- path:.github/workflows/release.yml
- commit:911265b
- commit:0ec6ec6
- commit:ec5416b
- commit:03419cc
- commit:c7fc734
- commit:7b31369
- commit:0ea9b5b
- commit:8631dd0
- commit:42658c2

## Do Not Infer
- Do not infer a successful live GitHub Actions run or release publication from local files. Check GitHub Actions and Releases before claiming live release readiness.

## Update Triggers
- Update when runtime pins, installer behavior, verification scripts, workflow names, release policy, README baseline, `VERSION`, or `CHANGELOG.md` change.

## Validation Commands
- `bash scripts/ci/lint.sh`
- `bash scripts/ci/validate.sh`
- `python3 -m pytest -q`
- `ruff check scripts/browser_runtime_integrity.py tests/test_browser_runtime_integrity.py`
- `pyright scripts/browser_runtime_integrity.py tests/test_browser_runtime_integrity.py`
- `find scripts -type f -name '*.sh' -print0 | xargs -0 shellcheck`
- `actionlint`
- `bash scripts/macos/verify.sh --strict --skip-optional`
- `bash scripts/ubuntu/verify.sh --strict --skip-optional`
- `bash scripts/ubuntu/verify-server.sh --docker-mode <none|rootful|rootless>`
- `python3 ../../../scripts/validate_release_version_policy.py`

## Repair Procedure
- Reconcile `VERSION`, `CHANGELOG.md`, contract, README, and installer pins, then rerun local CI and root release validators.

## Update policy
Keep this memory synchronized with release, validation, and public CI contract changes only.
