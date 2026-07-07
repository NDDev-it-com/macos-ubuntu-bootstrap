# rldyour New Mac / Ubuntu Bootstrap

rldyour module for macOS and Ubuntu workstation bootstrap, dependency installation, and terminal-first AI-CLI setup.

## Current Baseline

| Field | Value |
| --- | --- |
| Adapter version | `0.2.2` |
| Runtime baseline | Claude Code `2.1.201`; Codex `0.142.5`; OpenCode `1.17.13`; MiMoCode `0.1.4`; Antigravity `agy` |
| GitHub release tag | `0.2.2` |

Runtime pin sources: `scripts/macos/install.sh`, `scripts/ubuntu/install.sh`, and `config/rldyour-contract.json`.

## What This Repository Provides

This module is a configuration and bootstrap adapter for local terminals on macOS desktops and Ubuntu workstations/servers. It installs and validates terminal prerequisites for the rldyour AI CLI stack: Node/Bun/uv/Python/Go/Rust/Dart runtimes, AI CLI tools, terminal LSP/runtime helpers, and CI policy enforcement for public-repo quality and security.

It is not an upstream AI runtime source. It orchestrates pinned installer flows and validations only.

## Native Boundaries

This repository exposes these native runtime surfaces:

- `scripts/bootstrap.sh` - profile switcher (`--platform macos|ubuntu`).
- `scripts/macos/install.sh`, `scripts/ubuntu/install.sh` - OS-specific dependency installation profiles.
- `scripts/macos/verify.sh`, `scripts/ubuntu/verify.sh` - per-platform verification gates.
- `scripts/ci/*.sh` - shell lint/validation driver scripts.
- `.github/workflows/**` - CI, security, dependency and release controls.

Source-only (not projected into runtime installers): historical docs, contracts, and local agent context.

## Install / Update / ry-repair

**Install / plan mode (default):**

```bash
bash scripts/bootstrap.sh --platform macos
bash scripts/bootstrap.sh --platform ubuntu
```

**Apply mode:**

```bash
bash scripts/bootstrap.sh --platform macos --apply
bash scripts/bootstrap.sh --platform ubuntu --apply
```

**Targeted plans:**

```bash
bash scripts/bootstrap.sh --platform macos --plan --skip-checks
bash scripts/bootstrap.sh --platform ubuntu --plan --skip-checks
```

**Verification-only:**

```bash
bash scripts/macos/verify.sh --strict --skip-optional
bash scripts/ubuntu/verify.sh --strict --skip-optional
```

**Skip layers as needed:**

- `--skip-system`
- `--skip-ai`
- `--skip-lsps`
- `--skip-browser`
- `--skip-checks`

A local repository-level repair/convergence pass is performed via `scripts/ci/validate.sh` and the control-plane repair workflow before merge.

## Active Catalog

- `scripts/`: installer and validation entrypoints.
- `config/rldyour-contract.json`: module contract.
- `docs/install.md`: dependency matrix and mode documentation.
- `.github/workflows/`: 11 security and CI workflows.
- `AGENTS.md`, `LICENSE`, `NOTICE`, `SECURITY.md`, `CONTRIBUTING.md`.

```text
Scripts: 8
Workflows: 11
OS profiles: 2 (macOS, Ubuntu)
```

## Browser / Design / DevTools Routing

The bootstrap installs the pinned browser providers that every AI CLI config
adapter relies on for browser evidence, debugging, and design validation:

- Chrome DevTools MCP (`chrome-devtools-mcp@1.5.0`, bun global)
- Playwright CLI (`@playwright/cli@0.1.15`, bun global) plus its bundled skills
- Microsoft Webwright (pinned GitHub checkout, best-effort venv install)

The two bun-global providers are verified by the strict verify scripts; Webwright
is best-effort so a slow clone or Chromium download never breaks the deterministic
base layer. Skip the whole layer with `--skip-browser`. Browser/design *workflow
skills* still live in the adapter repositories (`rldyour-claudecode`,
`rldyour-opencode`, `rldyour-codex`, etc.); this module provides the runtime
providers those workflows need.

## Repository Context / Serena Memory

Public metadata and context are tracked in git. Runtime-only artifacts remain ignored (for example, cache, local traces, markers, and diagnostics output).

- Durable AI-context files are validated through root super-repo contracts and policy checks.
- Branch updates in super-repo should move the submodule pointer only after module validation and CI pass.

Relevant checks:

```bash
bash scripts/ci/validate.sh
bash scripts/ci/lint.sh
```

## Security Boundary

No credentials are committed in this module. Only public dependencies and pinned runtime commands are documented.

Security controls included:

- `codeql` + `dependency-review` in CI,
- secret scanning (`gitleaks`, GitHub secret scanning, push protection),
- Dependabot alerts + security updates,
- OSSF Scorecard,
- branch protection (`main`, required review, required status checks, no force-push/delete,
  code owners).

The owner executes with explicit terminal risk posture and explicit command boundaries; runtime tools are pinned to explicit versions in install profiles.

## Validation

**Static / local:**

```bash
bash scripts/ci/lint.sh
bash scripts/ci/validate.sh
```

**Per-platform checks:**

```bash
bash scripts/macos/verify.sh --strict
bash scripts/ubuntu/verify.sh --strict
```

**CI lanes:**

- `.github/workflows/ci.yml` (plan/apply)
- `.github/workflows/validate.yml`
- `.github/workflows/secret-scan.yml`
- `.github/workflows/codeql.yml`
- `.github/workflows/dependency-check.yml`
- `.github/workflows/dependency-review.yml`
- `.github/workflows/cross-platform.yml`
- `.github/workflows/actionlint.yml`
- `.github/workflows/pytest.yml`
- `.github/workflows/release.yml`
- `.github/workflows/scorecard.yml`

## Release / Rollback

Release workflow is tag-driven via `.github/workflows/release.yml`.

- Release version is read from `VERSION` and must match `CHANGELOG.md`.
- Release artifacts are packaged, checksummed, and attestable.

```bash
git tag <X.Y.Z>
git push origin <X.Y.Z>
```

Rollback is based on git history and prior tags; reinstall the desired release tag from the release page.

## Support / License

**License:** [AGPL-3.0-or-later](LICENSE)

**Author:** Danil Silantyev (github:rldyourmnd), CEO NDDev

**Security:** report via
https://github.com/NDDev-it-com/rldyour-new-mac-or-ubuntu/security/advisories/new

**Issues:** https://github.com/NDDev-it-com/rldyour-new-mac-or-ubuntu/issues

**Discussions:** https://github.com/NDDev-it-com/rldyour-new-mac-or-ubuntu/discussions

**Releases:** https://github.com/NDDev-it-com/rldyour-new-mac-or-ubuntu/releases
