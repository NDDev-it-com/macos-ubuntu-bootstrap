<!-- Memory Metadata
Last updated: 2026-07-04
Last verified: 2026-07-04
Last commit: 5dd9a4f94aa3833b1f002c8b4ecbb4bd00f5c80e chore(release): new-mac-or-ubuntu 0.1.2 (other)
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
- `VERSION` and `config/rldyour-contract.json`: product/config version `0.1.2`.
- `CHANGELOG.md`: release entries for `0.1.0`, `0.1.1`, and `0.1.2`, with an empty `[Unreleased]` section.
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
- Current product/config version is `0.1.2`.
- Release `0.1.2` synchronizes `VERSION`, README baseline, SECURITY current exact tag, and `config/rldyour-contract.json` after the contract baseline drift fixed by `a3dc4e0`.
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
- commit:5dd9a4f94aa3833b1f002c8b4ecbb4bd00f5c80e

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
