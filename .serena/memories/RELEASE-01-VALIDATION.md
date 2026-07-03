<!-- Memory Metadata
Last updated: 2026-07-04
Last commit: 0e8b8c5 chore(serena): allow durable project memories to be tracked
Scope: README.md, VERSION, config/rldyour-contract.json, scripts/**, .github/workflows/**
Area: RELEASE
-->

# RELEASE-01-VALIDATION

## Purpose

Capture the release, validation, and public README contract for the macOS/Ubuntu bootstrap module.

## Source Of Truth

- `README.md`: current public adapter template, baseline table, CI lanes, release/rollback instructions, support links.
- `VERSION`: adapter release version.
- `config/rldyour-contract.json`: adapter id `new-mac-or-ubuntu` and version `0.1.0`.
- `scripts/bootstrap.sh`: platform selector for `macos` and `ubuntu`.
- `scripts/macos/install.sh` and `scripts/ubuntu/install.sh`: runtime and dependency install profiles.
- `scripts/macos/verify.sh` and `scripts/ubuntu/verify.sh`: per-platform verification gates.
- `.github/workflows/`: CI, security, dependency, cross-platform, scorecard, and release workflows.

## Entry Points

- `bash scripts/bootstrap.sh --platform macos`: macOS plan mode.
- `bash scripts/bootstrap.sh --platform ubuntu`: Ubuntu plan mode.
- `bash scripts/bootstrap.sh --platform macos --apply`: macOS apply mode.
- `bash scripts/bootstrap.sh --platform ubuntu --apply`: Ubuntu apply mode.
- `bash scripts/ci/lint.sh`: shell syntax and shellcheck gate.
- `bash scripts/ci/validate.sh`: contract, lint, and plan-mode bootstrap validation.

## Current Behavior

Commit `9addbd7` aligned `README.md` with the shared public adapter README sections. The README now records baseline `0.1.0`, runtime pins for Claude Code `2.1.199`, Codex `0.142.5`, OpenCode `1.17.13`, MiMoCode `0.1.4`, and Antigravity `agy`.

The module is a bootstrap adapter, not an upstream runtime fork. It documents and orchestrates pinned installer flows for terminal prerequisites and AI CLI dependencies on macOS and Ubuntu.

## Contracts And Data

- Public README sections must include `Current Baseline`, `What This Repository Provides`, `Native Boundaries`, `Install / Update / ry-repair`, `Active Catalog`, `Browser / Design / DevTools Routing`, `Repository Context / Serena Memory`, `Security Boundary`, `Validation`, `Release / Rollback`, and `Support / License`.
- Release workflow is tag-driven through `.github/workflows/release.yml`.
- Release version must match `VERSION` and the release entry in `CHANGELOG.md`.
- Release artifacts are packaged, checksummed, and attestable.

## Invariants

- Keep runtime pins synchronized between README, installer scripts, and `config/rldyour-contract.json`.
- Keep validation commands in README aligned with actual scripts under `scripts/`.
- Do not add browser/design/devtools runtime surfaces to this module unless the module's scope changes; README currently states those workflows are owned by other super-repo modules.

## Change Rules

- When changing release, validation, or README sections, run the module gates and the super-repo public README/template validators.
- Update this memory when release behavior, CI workflow names, runtime pins, or README contract sections change.

## Verification

- `bash scripts/ci/lint.sh`: validates shell syntax and shellcheck for bootstrap scripts.
- `bash scripts/ci/validate.sh`: validates contract, lint, and plan-mode bootstrap flows.
- `bash scripts/macos/verify.sh --strict --skip-optional`: checks macOS required runtime commands.
- `bash scripts/ubuntu/verify.sh --strict --skip-optional`: checks Ubuntu required runtime commands.
- Super-repo `python3 scripts/validate_public_readme_template.py`: validates shared public README section parity.
- Super-repo `python3 scripts/validate_public_metadata_surfaces.py`: validates public metadata/description surfaces.
