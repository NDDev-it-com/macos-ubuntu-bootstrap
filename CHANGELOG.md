# Changelog

All notable changes to this module are documented here. Older release history
remains available in immutable Git tags.

## [Unreleased]

## [3.1.0] - 2026-08-13

- Added an explicit Ubuntu privilege state machine for root, one-time TTY
  `sudo -v` plus non-interactive cache use, passwordless sudo, and a narrowly
  allowlisted pre-provisioned PolicyKit desktop helper. Password transport and
  arbitrary privileged command channels remain forbidden; real GUI prompting
  is explicitly not proven by hosted evidence.
- Centralized Chrome signing identity in the machine-readable contract and
  made the privileged installer and independent verifier consume it fail
  closed, including single-key and normalized-fingerprint validation.
- Added no-follow, no-replace, fsync-ordered publication for the root-owned
  helper bundle, with immutable transaction evidence and race-safe preservation
  of unmanaged or divergent targets.
- Added a canonical machine-readable clean-system support/evidence matrix and
  made hosted evidence fail closed when a required capability is unproven or a
  runner/lane architecture is outside the declared proof boundary.
- Bound unprivileged validation tools to explicit root-owned or declared
  managed-package trust classes, including exact Homebrew bottle/keg receipts
  and content-addressed bundle identities; undeclared PATH shadows fail closed.

### Fixed

- Made Herdr permission verification deterministic across BSD/macOS and GNU/Linux
  test hosts, with explicit fail-closed shell control flow and repeat-apply coverage.
- Installed the exact receipt-bound Herdr 0.8.0 macOS release artifact instead
  of accepting the older mutable Homebrew formula.
- Published terminal plugins from verified pinned Git commit trees instead of
  exposing mutable checkout metadata to the executable Antidote source layer.
- Made Ubuntu server verification and device receipts prove the complete
  contract 3.0.1 source-tool set.
- Restricted Ubuntu GUI apply to amd64 because required vendor applications do
  not publish compatible Linux ARM64 builds; ARM64 no-GUI profiles remain
  supported.
- Synchronized release metadata and architecture policy across the contract,
  implementation, tests, ADRs, and operator documentation.

## [3.0.1] - 2026-08-13

### Fixed

- Updated Herdr to `0.8.0`, with verified macOS and Linux x86_64/aarch64
  installation and verification.
- Updated Telegram Desktop to the official `7.0.9` release and pinned its Linux
  x86_64 archive and source assets to tag commit `a1e89e1f`.
- Declared Herdr on macOS and every Ubuntu profile and Telegram on supported GUI
  targets.

## [3.0.0] - 2026-08-13

### Changed

- Standardized the active AI CLI set on official Codex CLI, Claude Code, and
  Grok Build distributions, with verified installer inputs and `cx`, `cl`, and
  `gk` unrestricted-mode launchers.
- Made Google Chrome stable the sole installed browser.
- Added ChatGPT, Claude, RustDesk, Telegram, Ghostty, and cmux to the applicable
  macOS GUI composition; added Chrome, RustDesk, Telegram, GNOME integration,
  and Firefox removal to Ubuntu GUI.
- Extended Go, Rust, Dart, language servers, terminal tooling, and local static
  verification to the supported profile matrix while retaining explicit
  execution-policy boundaries.
