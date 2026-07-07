# rldyour New Mac or Ubuntu Bootstrap

## Purpose

This module is the bootstrap adapter that installs and validates prerequisites for the
rldyour AI CLI toolchain on:

- macOS desktops
- Ubuntu workstations/servers

It owns only bootstrap automation for base dependencies and validation gates used by
the owner terminal stack:

- Claude Code
- Codex
- OpenCode
- Antigravity CLI (`agy`)
- MiMoCode (`mimo`)

## Scope and Source of Truth

- Entry point: `scripts/bootstrap.sh`
- Platform installers:
  - `scripts/macos/install.sh`
  - `scripts/ubuntu/install.sh`
- Shared helpers: `scripts/lib/common.sh`
- Verification scripts:
  - `scripts/macos/verify.sh`
  - `scripts/ubuntu/verify.sh`
- CI workflow: `.github/workflows/ci.yml`
- Module contract: `config/rldyour-contract.json`
- Product metadata: `LICENSE`, `NOTICE`, `VERSION`
- Documentation: `README.md`, `docs/install.md`

## Verified Dependency Policy

- Installer runs in two modes:
  - plan (default, dry-run)
  - apply (`--apply`)
- Pinned AI runtimes:
  - `@anthropic-ai/claude-code@2.1.201`
  - `@openai/codex@0.142.5`
  - `opencode-ai@1.17.13`
  - `@mimo-ai/cli@0.1.4`
  - `agy` (via `https://antigravity.google/cli/install.sh`)
- Python tooling via `uv tool`:
  - `pyright` (provides both `pyright` and `pyright-langserver`), `ruff`, `pytest`
- Multi-language LSPs (Homebrew on macOS, mixed apt/bun/cargo on Ubuntu):
  - `basedpyright`, `ruff`, `ty` (Python; `ruff server` is the active LSP)
  - `clangd` (C/C++/Qt via `llvm` + `qt`)
  - `rust-analyzer` (via `rustup`)
  - `gopls` (Go)
  - `dart` Analysis Server (in Dart SDK)
  - `jdtls` (Java), `kotlin-language-server` (Kotlin; requires JDK)
  - `postgres-language-server` (Supabase), `sqls` (multi-DB SQL)
  - R `languageserver` (requires R runtime)
- Config / docs LSPs:
  - `@vtsls/language-server` (TS/JS; replaces `typescript-language-server`)
  - `yaml-language-server`, `bash-language-server`
  - `dockerfile-language-server-nodejs` (provides `docker-language-server`)
  - `vscode-langservers-extracted`
  - `taplo`, `marksman`, `markdown-oxide`
  - `terraform-ls`, `helm-ls`, `cmake-language-server`
  - `gh-actions-language-server`
- Quality-gate CLIs (verified by strict verify):
  - `shellcheck`, `shfmt` (shell)
  - `oxlint`, `biome` (JS/TS/JSON)
  - the security/SAST scanner set (positive inventory lives in the platform install manifests)
  - `hadolint`, `actionlint`, `yamllint`, `markdownlint-cli2`
- Shared tools verified by installer:
  - `node`, `bun`, `python3`, `uv`, `go`, `rustup`, `dart`, `git`, `curl`, `java`, `R`

## Commands

- Quick check:
  - `bash scripts/bootstrap.sh --platform macos`
  - `bash scripts/bootstrap.sh --platform ubuntu`
- Apply:
  - `bash scripts/bootstrap.sh --platform macos --apply`
  - `bash scripts/bootstrap.sh --platform ubuntu --apply`
- Skip modes:
  - `--skip-system`, `--skip-ai`, `--skip-lsps`, `--skip-browser`, `--skip-checks`
- Verification:
  - `bash scripts/macos/verify.sh --strict --skip-optional`
  - `bash scripts/ubuntu/verify.sh --strict --skip-optional`

## Quality and CI

- GitHub Actions matrix:
  - `ubuntu-latest`, `macos-latest`
  - runs `bash scripts/ci/lint.sh`
  - runs `bash scripts/ci/validate.sh`
  - runs platform checks with:
    - `mode=plan`: `--plan --skip-checks`
    - `mode=apply`: `--apply`
  - runs cross-check plan for the alternate platform
- `workflow_dispatch` inputs:
  - `mode=plan|apply` (default: `plan`)
  - `platform=both|macos|ubuntu` (default: `both`)
- Manual CI runs:
  - `gh workflow run .github/workflows/ci.yml -f mode=plan -f platform=both`
  - `gh workflow run .github/workflows/ci.yml -f mode=apply -f platform=macos`
- Always run before merge:
  - `bash scripts/ci/lint.sh`
  - `bash scripts/ci/validate.sh`
  - platform plan runs (`--plan`) for both macOS and Ubuntu

## Commit Standards

- Use Conventional Commits.
- Commit installer/verification changes separately from docs and policy updates.
- Do not commit secrets, credentials, runtime markers, local browser artifacts, or caches.

## Ownership Notes

- Adapter contract version is tracked in `config/rldyour-contract.json`.
- Submodule updates in the superproject must only move gitlinks after pushing module changes.
