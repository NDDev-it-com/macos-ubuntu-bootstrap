# Changelog

All notable changes to this module will be documented in this file.

## [Unreleased]


## [0.2.2] - 2026-07-07

### Fixed

- Complete the release-integrity surfaces that `0.2.1` shipped without:
  SECURITY.md supported-versions table and `config/rldyour-contract.json`
  adapter version now track the current exact tag. The `0.2.1` tag was
  published manually and its release carried no build assets (the release
  workflow collided with the pre-created release); `0.2.2` supersedes it
  through the canonical tag-driven workflow with the full asset bundle.

### Changed

- AGENTS.md quality-gate inventory now references the security/SAST scanner
  set through the platform install manifests (positive-inventory wording)
  instead of naming individual scanners in active docs.

## [0.2.1] - 2026-07-07

### Added

- Add `eza` and `bat` to the macOS Homebrew baseline and the Ubuntu profile
  (apt `bat`, exposed as `batcat` on Debian/Ubuntu; `eza` best-effort on older
  LTS archives), with verification coverage on both platforms.

### Fixed

- Verification probed a nonexistent `typescript` binary; the `typescript`
  package ships `tsc`/`tsserver`, so both platform gates now check `tsc`.
  Strict verification could never pass before this fix.

## [0.2.0] - 2026-07-06

### Added

- Expand macOS installer with the full multi-language LSP stack and quality
  gates: basedpyright, ruff, ty, jdtls, kotlin-language-server, gopls,
  postgres-language-server (Supabase), sqls (via `go install`), R languageserver,
  markdown-oxide, terraform-ls, helm-ls, cmake-language-server, oxlint, biome,
  osv-scanner, gitleaks, semgrep, hadolint, actionlint, yamllint,
  markdownlint-cli2, shfmt, and the `fd`, `httpie`, `dasel`, `miller`, `git-delta`,
  `watchexec`, `hyperfine`, `just`, `prettier`, `pandoc`, `kubeconform`, `mise`,
  `libxml2`, `xmlstarlet` utilities.
- Add `qt` headers and `openjdk` to the macOS system baseline so clangd can
  resolve Qt projects and Java/Kotlin LSPs have a runtime.
- Replace `typescript-language-server` with `@vtsls/language-server` (chosen by
  Zed and LazyVim) in both macOS and Ubuntu LSP bundles; add
  `gh-actions-language-server` to both profiles.
- Add Ubuntu extended LSP/quality surface: `default-jdk` and `r-base` runtimes,
  bun-global quality CLIs (`biome`, `oxlint`, `markdownlint-cli2`, `prettier`),
  `sqls` and R `languageserver` (best-effort), and cargo-hosted `gitlab-ci-ls`.
- Add Ubuntu `install_security_scanners()` installing the verify-required
  scanners via their official channels: `basedpyright` (uv tool), `osv-scanner`
  and `gitleaks` (binary install scripts), `semgrep` (pip3), `hadolint` (GitHub
  release binary), and `actionlint` (rhysd download script).
- Extend macOS and Ubuntu `verify.sh` required/optional command sets to cover
  the expanded stack (Java/Kotlin/SQL LSPs, quality gates, utilities) and print
  java/R/clangd runtime versions.
- Document the full dependency matrix in `docs/install.md` across the new
  categories (extended LSPs, quality-gate CLIs, base utilities, JDK/Qt/R,
  Ubuntu security scanners).

### Changed

- Bump adapter contract and README baseline to `0.2.0`; verified_on
  `2026-07-06`.

### Fixed

- Close the macOS/Ubuntu `verify.sh` ↔ `install.sh` contract gaps so strict
  post-checks never fail on a fresh machine: Ubuntu now installs every
  verify-required scanner, and both platforms moved `chrome-devtools-mcp` /
  `playwright-cli` to `optional_cmds` because the browser layer is gated behind
  `--skip-browser`.
- Guard `R --version` in macOS `verify.sh` behind `command -v` so the optional
  R runtime cannot abort verification under `set -euo pipefail`.
- Remove duplicate `ruff` (kept the Homebrew formula as the single source of
  truth, dropped from `PYTHON_TOOLING_PACKAGES`) and duplicate
  `vscode-langservers-extracted` (kept Homebrew, dropped from
  `BUN_LSP_PACKAGES`) on macOS.
- Add `$HOME/go/bin` to `rldyour::ensure_path` so `go install`-built binaries
  like `sqls` are discoverable during verification.
- Align `SECURITY.md` supported-version tag (`0.1.11` -> `0.2.0`), README
  counters (`Scripts: 8`, `Workflows: 11`), and the broken
  `python3 scripts/ci/*.sh` instructions in README (now `bash`).
- Refresh the three Serena memory files to the 2026-07-06 / `0.2.0` baseline.
- Drop the misleading `postgres-language-server` reference from the Ubuntu
  `ensure_cargo_lsps` comment (it never installed it) and the `markdown-oxide`
  entry from the Ubuntu LSP docs (macOS-only install channel).
- shfmt-format `bootstrap.sh` case patterns; ignore `.DS_Store`, `*.swp`,
  `.idea/`, `.vscode/` in `.gitignore`.

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
