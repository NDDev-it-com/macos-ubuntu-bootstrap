# Ubuntu server bootstrap reference

scripts/ubuntu/server.sh is a sourceable, fail-safe server layer for Ubuntu
24.04 LTS (Noble) and Ubuntu 26.04 LTS (Resolute). It is independent from the
existing workstation installer and defaults to a read-only plan.

## Supported contract

- Ubuntu only: VERSION_ID 24.04 or 26.04.
- Docker is explicit: none, rootful, or rootless.
- UFW, key-only SSH, and Fail2ban are separate opt-ins.
- There is no generic sysctl or resource-limit tuning pack.
- Existing managed destinations are backed up before replacement.
- Docker repository files use namespaced paths plus exact ownership sidecars;
  unknown files are preserved and stop the apply.
- Remote scripts are never piped into a shell.
- verify-server.sh is read-only and does not pull container images.

Docker currently lists both supported releases in its
[Ubuntu installation guide](https://docs.docker.com/engine/install/ubuntu/).
See also the [Ubuntu 26.04 release notes][ubuntu-2604-notes].

## Invocation

Plan:

    bash scripts/ubuntu/server.sh --docker-mode rootful

Apply and verify:

    bash scripts/ubuntu/server.sh --apply --docker-mode rootful

Opt-in hardening:

    bash scripts/ubuntu/server.sh \
      --apply \
      --docker-mode rootful \
      --enable-ufw \
      --harden-ssh \
      --ssh-user deploy \
      --ssh-allow-cidr 203.0.113.0/24 \
      --enable-fail2ban

Keep the existing SSH session open until a second key-authenticated connection
has succeeded. The module validates authorized_keys before key-only changes,
validates the complete OpenSSH configuration with sshd -t, and reloads rather
than restarts the service. A failed validation or reload restores the previous
managed drop-in.

## Environment contract

| Variable | Default | Meaning |
| --- | --- | --- |
| RLDYOUR_DRY_RUN | 1 | 0 applies changes; 1 plans only |
| RLDYOUR_SERVER_DOCKER_MODE | none | none, rootful, or rootless |
| RLDYOUR_SERVER_ENABLE_UFW | 0 | Enable the UFW opt-in |
| RLDYOUR_SERVER_HARDEN_SSH | 0 | Enable key-only SSH opt-in |
| RLDYOUR_SERVER_ENABLE_FAIL2BAN | 0 | Enable the Fail2ban sshd jail |
| RLDYOUR_SERVER_SSH_PORT | detected | Explicit SSH port override |
| RLDYOUR_SERVER_SSH_ALLOW_CIDR | empty | Optional UFW source restriction |
| RLDYOUR_SERVER_SSH_USER | inferred | Non-root key-authenticated account |
| RLDYOUR_SERVER_SKIP_VERIFY | 0 | Skip post-apply verification |

RLDYOUR_SERVER_OS_RELEASE_FILE exists for controlled test fixtures. Production
invocations should leave it unset so /etc/os-release remains authoritative.
On successful validation, validate_os exports RLDYOUR_SERVER_OS_VERSION,
RLDYOUR_SERVER_OS_CODENAME, and RLDYOUR_SERVER_ARCH for downstream functions.
The verifier's RLDYOUR_SERVER_VERIFY_FAILURES counter is internal to its main
subshell and is not an input contract.

## Sourceable functions

Sourcing either file has no install or verification side effects:

    source scripts/ubuntu/server.sh
    source scripts/ubuntu/verify-server.sh

Installer API:

- rldyour::ubuntu_server::validate_os
- rldyour::ubuntu_server::install_baseline
- rldyour::ubuntu_server::configure_unattended_upgrades
- rldyour::ubuntu_server::ensure_time_sync
- rldyour::ubuntu_server::install_docker_rootful
- rldyour::ubuntu_server::install_docker_rootless
- rldyour::ubuntu_server::configure_ufw
- rldyour::ubuntu_server::harden_ssh
- rldyour::ubuntu_server::configure_fail2ban
- rldyour::ubuntu_server::main

Verifier API:

- rldyour::ubuntu_server_verify::base
- rldyour::ubuntu_server_verify::docker_rootful
- rldyour::ubuntu_server_verify::docker_rootless
- rldyour::ubuntu_server_verify::ufw
- rldyour::ubuntu_server_verify::ssh_hardening
- rldyour::ubuntu_server_verify::fail2ban
- rldyour::ubuntu_server_verify::main

The main entry points run in subshells so their strict shell options and local
state do not leak into a sourcing orchestrator.

## Docker installation and access

The module writes Docker's official deb822 repository and installs:

- docker-ce
- docker-ce-cli
- containerd.io
- docker-buildx-plugin
- docker-compose-plugin

The apt key is checked against the fixed full fingerprint
`9DC858229FC7DD38854AE2D88D81803C0EBFCD88`. It is a code-reviewed trust root,
not an environment override. Key rotation therefore requires a reviewed source
change. The managed files are:

- `/etc/apt/keyrings/rldyour-docker.asc`
- `/etc/apt/keyrings/rldyour-docker.asc.rldyour-owner`
- `/etc/apt/sources.list.d/rldyour-docker.sources`
- `/etc/apt/sources.list.d/rldyour-docker.sources.rldyour-owner`

An existing namespaced file is updated only with its exact ownership sidecar,
or adopted when its content is byte-for-byte equal to the generated known
content. Unknown, symlinked, or non-regular paths are preserved and fail the
apply. Existing Docker sources elsewhere under `/etc/apt` are also preserved,
but must be reviewed or migrated explicitly because duplicate `Signed-By`
settings can make apt fail. Conflicting distribution packages are reported and
must be removed explicitly; the module does not purge workloads.

Rootful mode leaves the docker group unchanged. Docker documents that group
membership grants root-level privileges:

- [Docker Linux post-installation guidance][docker-postinstall]

Rootless mode must be launched by the target non-root user. It requires
non-overlapping subordinate UID/GID ranges of at least 65,536 IDs. Its
preflight classifies the host before package changes:

- A healthy existing rootless context is verified idempotently. Any existing
  rootful units, sockets, containerd service, and data are preserved.
- An inactive rootless context can have only its user service repaired when no
  rootful runtime is active and the complete package set already exists.
- Any rootful install/runtime/socket/data with no healthy rootless context
  fails closed. The module never performs a silent rootful-to-rootless
  migration.
- Only a clean host enters package installation. Package post-install scripts
  can start rootful units, so the module creates and health-checks the rootless
  context first. It then disables only those rootful units proven absent during
  preflight and therefore created by this invocation. It never removes
  `/run/docker.sock` or `/var/run/docker.sock` directly.

If rootless startup fails during a clean installation, the newly installed
rootful package services remain available for recovery and no stop is
attempted. Re-run is idempotent after a healthy rootless setup. Review the
limitations first:

- [Docker rootless mode][docker-rootless]
- [Docker rootless troubleshooting][docker-rootless-troubleshooting]

The daemon should remain on a Unix socket. For remote access, use an SSH Docker
context or mutually authenticated TLS:

- [Protect the Docker daemon socket][docker-protect-access]

## UFW and published container ports

The UFW opt-in adds the SSH allow rule before enabling the firewall. Without a
CIDR it deliberately permits the SSH port from any source to avoid automated
lockout. Restrict the source only when the management network is known.

Before mutation, the module snapshots UFW's user rules, IPv6 user rules,
enablement file, defaults, and active/inactive state. Any local command or
post-apply validation failure restores those files and reapplies the previous
active state. This is a bounded best-effort rollback, not a remote-connectivity
transaction: it cannot prove upstream routing/security-group correctness,
cannot undo concurrent administrator edits made during the apply, and cannot
guarantee execution after the process or host is killed. Installing the `ufw`
package itself is not rolled back. Keep console/provider access and the current
SSH session open, and prove a second connection before closing either.

Docker-published ports bypass ordinary UFW input rules. UFW status alone is not
proof that a container port is protected:

- [Docker packet filtering and firewalls][docker-packet-filtering]
- [Docker with iptables][docker-iptables]
- [Ubuntu firewall guidance][ubuntu-firewalls]

Prefer binding application ports to loopback behind a reverse proxy. Direct
publication needs a host-specific DOCKER-USER policy with verified interfaces,
source CIDRs, and ports. The bootstrap does not invent those values and does
not disable Docker's firewall management. Test exposure externally.

## OpenSSH, updates, time, and Fail2ban

The baseline installs OpenSSH and unattended-upgrades, enables periodic package
metadata refreshes and unattended security updates through the managed
/etc/apt/apt.conf.d/52rldyour-unattended-upgrades drop-in, enables Ubuntu apt
timers, validates SSH, and preserves an active Chrony or systemd-timesyncd
provider. If neither exists, it installs Ubuntu Chrony.

Automatic reboot settings are not changed:

- [Ubuntu automatic updates][ubuntu-automatic-updates]
- [Ubuntu Chrony client guidance][ubuntu-chrony]
- [Ubuntu OpenSSH server guidance][ubuntu-openssh]

Fail2ban is an optional rate limiter, not a substitute for public-key
authentication. Its sshd jail uses the systemd backend and is validated before
the service is restarted.

## No generic kernel or limit tuning

IP forwarding, reverse-path filtering, TCP buffers, swappiness, nofile, and
process limits depend on the host role. Docker also manages forwarding for
bridge networking. Any required kernel setting belongs in a separately
reviewed /etc/sysctl.d overlay; service limits belong in a systemd unit
drop-in.

## Verification and idempotency

Independent verification:

    bash scripts/ubuntu/verify-server.sh --docker-mode rootful

Expected optional features:

    bash scripts/ubuntu/verify-server.sh \
      --docker-mode rootful \
      --expect-ufw \
      --expect-ssh-hardening \
      --ssh-user deploy \
      --expect-fail2ban

The verifier checks OS/architecture, OpenSSH, apt timers, time sync, Docker
packages and plugins, the rootless user-socket/context boundary, absence of TCP
listeners on 2375/2376, and explicitly expected UFW/SSH/Fail2ban state. When
the namespaced Docker repository exists it also checks exact sidecars, content,
fixed key fingerprint, owner, and mode. In rootless mode, an active rootful
runtime is reported as a warning rather than modified or treated as proof that
automatic migration is safe.

Idempotency evidence is two consecutive apply runs: the second must report
managed files as current and leave checksums unchanged. Firewall exposure and
SSH reachability still require external VM tests.

## GitHub Actions and deployment secrets

Use approved NDDev-it-com/nddev-ci-workflows reusable workflows pinned to a
full commit SHA and minimal permissions. Pass only explicitly required secrets;
avoid broad secrets inheritance.

Prefer GitHub OIDC for cloud deployments. For raw SSH targets:

- private key: protected GitHub Environment secret;
- host/user and pinned known_hosts: environment-scoped configuration;
- never use StrictHostKeyChecking=no;
- deploy from a protected branch or manual dispatch;
- use environment approvals, concurrency, health checks, and rollback.

No private key, token, .env, rendered credential file, or secret-bearing log
belongs in the repository or artifacts:

- [GitHub reusable workflow configuration][github-reusable-workflows]
- [GitHub Actions secrets][github-actions-secrets]
- [GitHub OIDC deployment guidance][github-oidc]

[docker-iptables]: https://docs.docker.com/engine/network/firewall-iptables/
[docker-packet-filtering]: https://docs.docker.com/engine/network/packet-filtering-firewalls/
[docker-postinstall]: https://docs.docker.com/engine/install/linux-postinstall/
[docker-protect-access]: https://docs.docker.com/engine/security/protect-access/
[docker-rootless]: https://docs.docker.com/engine/security/rootless/
[docker-rootless-troubleshooting]: https://docs.docker.com/engine/security/rootless/troubleshoot/
[github-actions-secrets]: https://docs.github.com/en/actions/concepts/security/secrets
[github-oidc]: https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-cloud-providers
[github-reusable-workflows]: https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations
[ubuntu-2604-notes]: https://documentation.ubuntu.com/release-notes/26.04/
[ubuntu-automatic-updates]: https://ubuntu.com/server/docs/how-to/software/automatic-updates/
[ubuntu-chrony]: https://ubuntu.com/server/docs/how-to/networking/chrony-client/
[ubuntu-firewalls]: https://ubuntu.com/server/docs/how-to/security/firewalls/
[ubuntu-openssh]: https://ubuntu.com/server/docs/how-to/security/openssh-server/
