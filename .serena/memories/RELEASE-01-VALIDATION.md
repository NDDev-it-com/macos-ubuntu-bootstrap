<!-- Memory Metadata
Last updated: 2026-07-07
Last verified: 2026-07-07
Last commit: a0e3eb4 feat: 0.2.3 terminal layer for macOS/Ubuntu + release checksum fix (#8)
Scope: README.md, VERSION, CHANGELOG.md, config/rldyour-contract.json, scripts/**, .github/workflows/**
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
- `.github/workflows/**`: CI, security, dependency, scorecard, cross-platform, and release workflows.

## Invariants
- Installer default mode is plan/dry-run; `--apply` is required for mutation.
- Runtime pins stay synchronized across README, installer scripts, and contract.
- Release workflow is tag-driven and must match `VERSION` plus `CHANGELOG.md`.
- Public security workflows remain enabled for the public repository posture.

## Current State
- Current product/config version is `0.2.3`.
- Release `0.2.3` absorbs the terminal layer from the retired `awesome-terminal-for-ai` spec: macOS brew wave (antidote, zsh-completions, olets/tap zsh-abbr, Ghostty cask, starship, atuin, fzf, zoxide, carapace, gh, lazygit, yazi, xh, jaq, jnv, duckdb, ast-grep, scc, difftastic, tmux, dust, dua-cli, duf, procs, btop, doggo, gping, hexyl, sd, viddy, tealdeer), the Ubuntu apt subset plus official installers (starship/atuin/xh, git-clone antidote), managed zsh/starship templates in `templates/terminal/` installed never-clobber via `rldyour::install_terminal_configs`, and global git perf keys plus delta pager config in `scripts/lib/common.sh`.
- The AI runtime pins are `@anthropic-ai/claude-code@2.1.202` and `opencode-ai@1.17.14` (npm latest as of 2026-07-07; source of truth `scripts/macos/install.sh` and `scripts/ubuntu/install.sh`). The `0.2.3` baseline also removes `httpie`/`dasel`/`miller` and extends both platform `verify.sh` required sets to the terminal layer.
- Release `0.2.3` fixes the release workflow: `release-notes.md` is generated before checksums, `SHA256SUMS` is built from a mapfile asset list excluding only itself, `templates/` is included in the release tarball, and `release-notes.md` joined `required_artifacts` (0.2.2 shipped SHA256SUMS without it).
- Releases `0.2.0`-`0.2.2` expanded the multi-language LSP stack, quality-gate CLI set, eza/bat baseline, tsc verify probe fix, and release-integrity surfaces (SECURITY table, contract version).
- The module supports macOS and Ubuntu/server bootstrap profiles.
- Local CI entrypoints are `bash scripts/ci/lint.sh` and `bash scripts/ci/validate.sh`.
- Strict platform checks are `bash scripts/macos/verify.sh --strict --skip-optional` and `bash scripts/ubuntu/verify.sh --strict --skip-optional`.

## Evidence
- path:VERSION
- path:CHANGELOG.md
- path:config/rldyour-contract.json
- path:scripts/bootstrap.sh
- path:scripts/ci/validate.sh
- path:scripts/macos/install.sh
- path:scripts/ubuntu/install.sh
- path:.github/workflows/ci.yml
- path:.github/workflows/release.yml
- commit:a0e3eb4

## Do Not Infer
- Do not infer a successful live GitHub Actions run or release publication from local files. Check GitHub Actions and Releases before claiming live release readiness.

## Update Triggers
- Update when runtime pins, installer behavior, verification scripts, workflow names, release policy, README baseline, `VERSION`, or `CHANGELOG.md` change.

## Validation Commands
- `bash scripts/ci/lint.sh`
- `bash scripts/ci/validate.sh`
- `bash scripts/macos/verify.sh --strict --skip-optional`
- `bash scripts/ubuntu/verify.sh --strict --skip-optional`
- `python3 ../../../scripts/validate_release_version_policy.py`

## Repair Procedure
- Reconcile `VERSION`, `CHANGELOG.md`, contract, README, and installer pins, then rerun local CI and root release validators.

## Update policy
Keep this memory synchronized with release, validation, and public CI contract changes only.
