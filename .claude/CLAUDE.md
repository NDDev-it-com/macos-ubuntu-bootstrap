# Claude Code Project Memory: rldyour New Mac or Ubuntu Bootstrap

## Purpose

This module provides a unified bootstrap flow for AI CLI toolchains on:

- macOS (`scripts/macos/*`)
- Ubuntu (`scripts/ubuntu/*`)

It is a stand-alone repository submodule used by the superproject `rldyour-ai-cli-tools`
for dependency and verification parity across workstation classes.

## Repository Layout

- `scripts/bootstrap.sh` - platform selector and orchestration entrypoint.
- `scripts/lib/common.sh` - shared shell helpers and command checks.
- `scripts/macos/install.sh` and `scripts/macos/verify.sh` - macOS baseline setup.
- `scripts/ubuntu/install.sh` and `scripts/ubuntu/verify.sh` - Ubuntu baseline setup.
- `scripts/ci/validate.sh` - lint + contract + dry-run matrix preflight.
- `scripts/ci/lint.sh` - shell syntax + shellcheck for bootstrap scripts.
- `docs/install.md` - OS dependency matrix and CI notes.
- `config/rldyour-contract.json` - module contract and adapter metadata.

## Verified Runtime Baseline

- Claude Code runtime check is resilient to both possible binary names:
  - `claude` (current installed binary)  
  - `claude-code` (legacy alias in some environments)
- AI runtimes installed from pins:
  - `@anthropic-ai/claude-code@2.1.199`
  - `@openai/codex@0.142.5`
  - `opencode-ai@1.17.13`
  - `@mimo-ai/cli@0.1.4`
  - `agy` via antigravity installer URL
- Python tooling is managed through `uv tool`.
- LSP layer is provisioned via Bun globals where supported.

## Common Workflows

- Plan only (default):
  - `bash scripts/bootstrap.sh --platform macos`
  - `bash scripts/bootstrap.sh --platform ubuntu`
- Apply:
  - `bash scripts/bootstrap.sh --platform macos --apply`
  - `bash scripts/bootstrap.sh --platform ubuntu --apply`
- Strict verification:
  - `bash scripts/macos/verify.sh --strict --skip-optional`
  - `bash scripts/ubuntu/verify.sh --strict --skip-optional`
- Full CI preflight:
  - `bash scripts/ci/validate.sh`
  - `bash scripts/ci/lint.sh`
- CI workflow dispatch:
  - `platform=both|macos|ubuntu`
  - `mode=plan|apply`
- Manual examples:
  - `gh workflow run .github/workflows/ci.yml -f mode=plan -f platform=both`
  - `gh workflow run .github/workflows/ci.yml -f mode=apply -f platform=macos`

## Troubleshooting Notes

- If a binary is missing after install, rerun with platform-specific apply mode:
  - ensure base toolchain environment is present (`PATH` includes user-local bins such as
    `~/.bun/bin`, `~/.cargo/bin`, `~/.local/bin`)
    and rerun bootstrap with `--apply`.
- For strict behavior in installer or verify flows use `--strict`.

## Task Rules

- Keep changes scoped to verified facts from this module (`scripts`, `docs`, `config`).
- Prefer direct shell checks:
  - `bash -n <script>`
  - `shellcheck -x <script>`
- Keep logs and notes concise; avoid committing runtime artifacts.
