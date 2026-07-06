<!-- Memory Metadata
Last updated: 2026-07-06
Last verified: 2026-07-06
Last commit: 7adf2d7 feat(install): expand LSP and quality-gate stack to 0.2.0
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
- Current product/config version is `0.2.0`.
- Release `0.2.0` expands the macOS and Ubuntu installer profiles with the full multi-language LSP stack (basedpyright, ty, jdtls, kotlin-language-server, postgres-language-server, sqls, R languageserver, markdown-oxide, terraform-ls, helm-ls, cmake-language-server) and the quality-gate CLI set (oxlint, biome, osv-scanner, gitleaks, semgrep, hadolint, actionlint, yamllint, markdownlint-cli2, shfmt), plus the JDK/Qt/R runtimes and base utilities.
- Release `0.2.0` synchronizes `VERSION`, README baseline, SECURITY current exact tag, and `config/rldyour-contract.json`.
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
- commit:7adf2d7

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
