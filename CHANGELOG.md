# Changelog

All notable changes to this module will be documented in this file.

## [Unreleased]


## [0.1.11] - 2026-07-04

### Fixed

- Adopt nddev-ci-workflows 0.2.3 and fix reusable CI edge cases.

## [0.1.10] - 2026-07-04

### Fixed

- Migrate CI workflows to nddev-ci-workflows reusable contracts.

## [0.1.9] - 2026-07-04

### Fixed

- Migrate CI workflows to nddev-ci-workflows reusable contracts.

## [0.1.8] - 2026-07-04

### Changed

- CI/CD audit remediation: real actionlint run (antigravity), gitleaks history scan replacing regex (mimocode), digest-pinned gitleaks image (new-mac), CodeQL python+actions matrix with weekly schedule and security-and-quality queries (antigravity/mimocode), job-scoped release permissions, pinned pytest, harden-runner egress audit + persist-credentials on security jobs, strict instruction-docs validation and corrected script path globs (opencode), and stronger branch-protection required checks (new-mac).

## [0.1.7] - 2026-07-04

### Changed

- Align bootstrap doc surfaces (README, AGENTS.md, .claude/CLAUDE.md, docs/install.md) to the Claude Code 2.1.201 installer pin and add an installer-pin/doc parity guard to test_bootstrap_smoke.py so the versions cannot drift silently.

## [0.1.6] - 2026-07-04

### Changed

- Refresh Claude Code runtime pin to 2.1.201 (latest stable) across adapter surfaces and the bootstrap installer.

## [0.1.5] - 2026-07-04

### Fixed

- Align bootstrap smoke tests with the corrected clean-PC install channels.

## [0.1.4] - 2026-07-04

### Fixed

- Install taplo, marksman, pyright, and clangd via working channels so a clean-PC bootstrap and strict verify succeed.

## [0.1.3] - 2026-07-04

### Added

- Install pinned browser providers (Chrome DevTools MCP, Playwright CLI, Webwright) for all adapters.

## [0.1.2] - 2026-07-04

### Fixed

- Synchronize bootstrap contract baseline with released adapter version.

## [0.1.1] - 2026-07-04

### Security

- Refresh GitHub Actions and CodeQL pins across the public module CI surface.

## [0.1.0] - 2026-07-04

### Added

- Added advanced GitHub OSS CI and release hardening for macOS and Ubuntu bootstrap module.
- Added public adapter CI policy-aligned workflow set: `validate`, `actionlint`,
  `codeql`, `dependency-check`, `gitleaks/secret-scan`, `dependency-review`,
  `pytest`, `cross-platform`, `scorecard`, and `release`.
- Added deterministic release pipeline with version checks, SPDX SBOM generation,
  hash manifest, and attestations.
- Added CI smoke tests and baseline `CHANGELOG.md` with release block.

### Fixed

- Fixed Ubuntu installer parity to install `marksman` in the LSP layer, matching
  `verify.sh` contract and macOS behavior.
- Corrected dependency-check and release workflow behavior for pinned runtime validation and SBOM manifest generation.
- Normalized CI workflow hardening artifacts and docs to include full OSS capability set used by module (`validate`, `pytest`, `actionlint`, `codeql`, `gitleaks/secret-scan`, `dependency-review`, `dependency-check`, `cross-platform`, `scorecard`, `release`).
- Synchronized README/docs/security text with actual branch-protection and public repository security controls.
