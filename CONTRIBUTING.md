# Contributing to rldyour macOS or Ubuntu

Thanks for contributing to this module.
The module provides bootstrap automation and validation for:

- Claude Code
- Codex
- OpenCode
- Antigravity CLI
- MiMoCode

## Quick links

- Code of Conduct: [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)
- Security policy: [SECURITY.md](./SECURITY.md)
- Branch protection: [`.github/branch-protection/main.json`](./.github/branch-protection/main.json)
- CI workflow: [`.github/workflows/ci.yml`](./.github/workflows/ci.yml)
- Contract: [config/rldyour-contract.json](./config/rldyour-contract.json)

## Prerequisites

- Python 3.13+
- Bun 1.x
- uv (or `pip install uv`)
- Bash + `shellcheck`

## Local workflow

- Run formatting and workflow lint checks:
  - `bash scripts/ci/lint.sh`
- Run local validation (plan mode):
  - `bash scripts/ci/validate.sh`
- Run installer verification for platform:
  - `bash scripts/macos/verify.sh --strict --skip-optional`
  - `bash scripts/ubuntu/verify.sh --strict --skip-optional`

Before opening a PR, include evidence of successful checks in PR description.

## Commit and PR conventions

- Use Conventional Commits.
- Keep PR scope atomic and split implementation, docs, and policy/config updates.
- PR description must include:
  - Scope
  - Validation commands run
  - Risk assessment
  - Rollback plan
- Security-impacting changes must call out `SECURITY.md` implications.

## Code + docs quality

- No placeholders, no secrets, no runtime markers in history.
- Keep `README.md`, `docs/install.md`, workflow files and contract in sync.
- Preserve installer idempotency and safe mode behavior.
