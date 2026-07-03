# Security Policy

## Supported Versions

Only the current exact numeric product release tag receives security fixes. This repository is a bootstrap adapter, so operational safety relies on explicit release pinning.

| Version | Supported |
| --- | --- |
| Current exact tag `0.1.2` | yes |
| The `0.1.x` line label tracks only the latest released patch | no |
| Older minor / major lines | no |

## Reporting a Vulnerability

Please report vulnerabilities privately through GitHub Security Advisories:

- https://github.com/NDDev-it-com/rldyour-new-mac-or-ubuntu/security/advisories/new

Public issues are not accepted for confirmed security reports.

Include all of the following:

- Affected component/command/path
- OS (macOS/Linux/Ubuntu)
- Exact module SHA and commit
- Reproduction steps and expected impact
- Redacted logs or outputs (no secrets)

## Scope

In-scope:

- Installer scripts under `scripts/**`
- Runtime and bootstrap checks under `scripts/bootstrap.sh`, `scripts/macos/**`, `scripts/ubuntu/**`
- CI workflows under `.github/workflows/**`
- Contract/metadata in `config/rldyour-contract.json`, `README.md`, `docs/**`

Out of scope:

- Third-party AI providers or runtimes themselves (e.g., provider SDK or binary distributors)
- Forked/modified local copies that change installer behavior without upstream changes
- Issues introduced by custom OS configuration outside this repository

## Security Controls

This module enables the following baseline OSS security controls:

- Native GitHub secret scanning + push protection
- Dependabot alerts and security updates
- CodeQL analysis
- Dependency Review for supported package ecosystems
- Secret scanning in CI (`gitleaks`)
- OpenSSF Scorecard workflow
- GitHub Action pin and workflow lint checks

## Branch Protection

Branch protection is enabled on `main` with:

- required PR review: 1
- no force pushes
- no branch deletions
- required status checks: `bootstrap-gate`
