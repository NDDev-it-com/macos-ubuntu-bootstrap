# Security Policy

## Supported versions

- `rldyour-new-mac-or-ubuntu` uses versioned bootstrap scripts from `main`.
- For security issues report with minimum detail:
  - command (with full output),
  - OS and platform profile,
  - module commit SHA,
  - exact steps to reproduce.

## Reporting vulnerabilities

- Open a private issue only for sensitive findings and use a redacted reproduction.
- Public PRs can be used for non-sensitive hardening updates.

## Security tooling

This module is designed as an OSS-first security baseline and includes:

- Secret scanning (GitHub native),
- Secret scanning push protection,
- GitHub Dependabot security alerts and security updates,
- Dependabot security updates for workflows,
- Dependency review on dependency-relevant PRs,
- CodeQL (Python),
- Gitleaks scan in CI,
- OSSF Scorecard analysis.

Dependency and security capability coverage is oriented to GitHub public/free + OSS-first controls:
secret scanning, push protection, Dependabot security alerts/updates, CodeQL, dependency review,
and OSSF Scorecard.

## Branch protection

- Required pull request reviews: 1
- No force pushes
- No branch deletion
- Status checks required for `bootstrap-gate` (this module) or branch checks configured in module policy.
