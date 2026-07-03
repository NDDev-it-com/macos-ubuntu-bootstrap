# Support

Use public GitHub Issues for this adapter for:

- bootstrap, install, and validation failures,
- installer/CLI setup mismatches,
- documentation drift.

For security reports, use a private advisory at the repository security page.
Do **not** open public issue text for exploit details.

When filing an issue, include:

- OS/platform (`macos` / `ubuntu` / server),
- exact command chain (`scripts/bootstrap.sh` / platform installer / verify),
- relevant commit SHA,
- sanitized output snippets from `scripts/macos/verify.sh`, `scripts/ubuntu/verify.sh` or `scripts/ci/validate.sh`.
