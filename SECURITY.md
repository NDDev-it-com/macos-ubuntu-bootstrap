# Security Policy

## Supported Versions

Only the current exact numeric product release receives security fixes. This
repository is a bootstrap adapter, so operational safety depends on using a
reviewed commit and the matching versioned contract.

| Version | Supported |
| --- | --- |
| Current exact tag `2.0.0` | yes |
| Older patch, minor, or major versions | no |

The `0.3.x` release-line label tracks only the latest released patch. The
supported artifact is always the exact numeric tag named above.

## Reporting A Vulnerability

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/NDDev-it-com/macos-ubuntu-bootstrap/security/advisories/new).
Do not open a public issue for a confirmed vulnerability.

Include:

- affected component, command, and path;
- target OS, release, architecture, profile, GUI mode, and Docker mode;
- exact module commit SHA and adapter version;
- minimal reproduction steps, observed behavior, and expected impact;
- redacted logs or outputs with no credentials, tokens, cookies, or personal data.

## Scope

In scope:

- installer, helper, authentication-handoff, and verification scripts under
  `scripts/**`;
- managed terminal and browser templates;
- profile composition, platform detection, and target validation;
- dependency acquisition, version pinning, integrity checks, and managed-file
  ownership behavior;
- the fixed CloakBrowser/CDP provider boundary;
- Ubuntu server Docker, SSH, UFW, Fail2ban, update, and time-service automation;
- CI workflows and machine-readable contract metadata.

Out of scope:

- vulnerabilities in third-party providers or binaries that are not caused by
  this adapter's acquisition, configuration, or invocation behavior;
- locally modified forks or unmanaged files that change bootstrap behavior;
- custom host or network configuration outside repository ownership;
- credentials or accounts supplied directly to third-party applications.

## Operational Security Boundaries

### Plan And File Ownership

Plan mode is the default. Mutations require `--apply`. Managed files are
replaced atomically, while unmanaged files, symlinks, directories, and dirty
managed-source checkouts are preserved and rejected rather than silently
adopted or overwritten.

The bootstrap never owns provider credentials. Use
`scripts/auth-handoff.sh` for owner-controlled login instructions and non-secret
status probes. Never attach secret-bearing logs, browser profiles, traces,
cookies, tokens, `.env` files, or credential exports to an issue or artifact.

### Mandatory Browser Isolation

Every supported profile requires CloakBrowser `0.4.12`. A managed service owns
the fixed endpoint `http://127.0.0.1:9222`; it must never listen on a non-loopback
address. The only active providers are Chrome DevTools MCP and Playwright CLI;
their managed wrappers reject alternate endpoints, executables, configs,
auto-started stock browsers, arbitrary Playwright code/file execution, and
browser fallbacks. Webwright is retired: its exact compatibility wrapper exits
`78` and must never start Python or a browser.

There is no supported browser skip. `--skip-browser` and
`RLDYOUR_SKIP_CLOAKBROWSER=1` fail closed. A missing or unhealthy managed CDP
service is a hard error. Treat any unintended exposure of port `9222` as
security-sensitive because CDP controls pages, cookies, storage, and browser
JavaScript.

Every successful browser apply publishes an owner-only canonical receipt that
binds exact runtime identities, provider binaries, wrappers, service file,
policy sources, and live service health. `scripts/verify-browser-runtime.sh`
recomputes the complete state and fails on drift; a marker substring or a
reachable CDP-compatible endpoint alone is never sufficient proof.

Development-only CloakBrowser variables that replace the binary, download
origin, checksum policy, browser version, or Widevine path are rejected by the
managed installer and launcher. Only `CLOAKBROWSER_LICENSE_KEY` is accepted as
a secret runtime extension to the signed upstream path; it cannot change the
platform-specific browser build pinned by this repository.

### Desktop Runtime Boundary

macOS and Ubuntu desktop profiles are source/LSP-only. They do not provision
Docker or configure local project build/runtime execution. Tool-host binaries
that accompany an LSP distribution are not used to build projects. This keeps
project builds on explicit server or runtime hosts.

### Ubuntu Server Changes

Ubuntu server defaults to rootful Docker in the composed bootstrap, but Docker
group membership is never granted automatically because it is root-equivalent.
Rootless and no-Docker modes are explicit alternatives.

SSH hardening, UFW, and Fail2ban are independent opt-ins and are never inferred
from the server profile. Key-only SSH requires a validated non-root account and
authorized key. OpenSSH changes are syntax- and effective-config-checked before
reload, with rollback after failure. UFW adds an SSH allow rule before enablement.
Keep the current SSH session open until a second key-authenticated session
succeeds.

The server baseline never switches an existing host between `ssh.service` and
`ssh.socket`. Socket-only hosts keep their listener unchanged during
authentication hardening; the validated policy is consumed by future sshd
processes. Effective port discovery runs as a read-only privileged probe so
root-only host keys do not make normal non-root verification fail.

Key-only hardening accepts only `ssh-keygen`-parseable authorized keys whose
home, `.ssh`, and key-file ownership/modes satisfy StrictModes. Effective policy
is evaluated with `sshd -T -C` using the real user/client/local connection tuple
and a separate root context, preventing `Match` blocks from creating a false
green result. Fail2ban activation and service state are rolled back on failure;
existing NTP/PTP providers are not replaced.

Docker-published ports may bypass ordinary UFW input policy. Review bindings,
reverse proxies, `DOCKER-USER` policy, source networks, and external exposure for
the actual host. The bootstrap deliberately does not invent a generic network
policy.

## Supply-Chain And Integrity Policy

- AI CLIs and browser providers use the versions recorded in
  `config/rldyour-contract.json` and tracked Bun locks. AI package lifecycle
  scripts are disabled; OpenCode uses its locked native optional package
  directly.
- Claude Code and Antigravity managed launchers disable every supported
  self-update path; upgrades require a reviewed pin and lock refresh.
- Remote installer content is pinned to an immutable commit/version where the
  upstream supports it and must match its tracked SHA-256 before execution;
  incoming network streams are never piped directly into a shell.
- Ubuntu Node.js, uv, and Bun use versioned assets with tracked architecture
  hashes plus owned receipts for every managed executable; strict verification
  requires exact `~/.local/bin` links and never trusts a same-version external
  PATH binary. Browser Node providers resolve through a tracked `bun.lock` and
  CloakBrowser resolves through a tracked universal `uv.lock`; both install in
  frozen mode rather than from live open dependency ranges. Webwright has no
  installed dependency tree or executable runtime.
- Available signing keys, fingerprints, hashes, or upstream manifests are
  verified before managed installation. APT key bundles must contain exactly
  one primary key with the expected fingerprint; extra primary keys fail.
- Existing global package installations outside repository-managed prefixes
  are not removed to create a false clean state.
- Package upgrades and restarts are never inferred from a rerun: apt uses
  no-upgrade semantics, existing source tools are preserved, and Docker CE is
  installed only over an empty Docker/containerd state.

The current managed AI baseline is Claude Code `2.1.206`, Codex `0.144.1`,
OpenCode `1.17.18`, MiMoCode `0.1.5`, and Antigravity (`agy`) exact `1.1.1`.
The supporting RTK output compressor is exact `0.43.0`.

ZCode is manual by default because upstream publishes no checksum or signature
manifest. On Ubuntu, the installer accepts only an owner-supplied, separately
verified `RLDYOUR_ZCODE_SHA256` and fails on mismatch. Do not report the absence
of an automatic ZCode install as a defect unless an upstream verifiable
integrity channel has become available.

## Repository Security Controls

The repository uses:

- GitHub secret scanning and push protection;
- Dependabot alerts and security updates;
- CodeQL analysis;
- Dependency Review where supported;
- Gitleaks secret scanning in CI;
- OpenSSF Scorecard;
- GitHub Actions pin and workflow lint checks;
- protected `main` changes through review and required checks.

These controls complement, but do not replace, real-target verification. Full
Ubuntu server security evidence requires a supported VM with systemd plus
external SSH, firewall, and port-exposure tests.
