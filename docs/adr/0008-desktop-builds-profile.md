# ADR 0008: The desktop-builds Profile for Local Development with Docker

- Status: accepted
- Date: 2026-08-04
- Amends: the retired ADR 0004 (see `docs/adr/README.md`); relaxes its
  "desktop profiles never install Docker" invariant

## Context

The retired ADR 0004 established that desktop profiles never install Docker — local
workstations "cannot accidentally become project runtime hosts through this
bootstrap." This held while every developer machine was either a pure
source-editing workstation (macOS/Ubuntu desktop, `source-lsp-only`) or a
headless CI/build server (Ubuntu server, `container-execution-only`).

A third use case emerged: a developer Ubuntu workstation that needs **local
Docker** for building and testing projects — a "desktop that acts like a
server" for builds, but retains the full GUI desktop experience. Installing
Docker manually on a `source-lsp-only` desktop (as happened on
`rldyourmnd-ubuntu-1`) created a contract violation: the device declared
`docker_mode: none` while running Docker CE 29.7.1 with the user in the
`docker` group.

## Decision

Introduce a third Ubuntu profile, **`desktop-builds`**, with a new execution
policy **`local-dev-with-builds`**.

### What desktop-builds receives

Everything the desktop profile receives (compiled-language hosts, user tools,
and the optional GUI overlay) **plus Docker Engine rootful**
installed via the existing `server.sh` Docker functions — but with
`--skip-baseline`, so the server baseline (openssh-server, unattended-upgrades,
chrony) is NOT installed.

### What desktop-builds does NOT receive

- The server baseline (no openssh-server, no unattended-upgrades, no chrony)
- Server hardening (no UFW, no SSH hardening, no fail2ban)
- The `docker` group membership is NOT automatically granted
  (`safety.docker_group_membership: "explicit"`). The developer must opt in
  manually (`sudo usermod -aG docker $USER`) after understanding that docker
  group membership is root-equivalent.

### Profile matrix

| Profile | Docker | GUI | Policy | Server baseline |
|---|---|---|---|---|
| desktop | none | on/off | source-lsp-only | no |
| **desktop-builds** | rootful | on/off | local-dev-with-builds | **no** (--skip-baseline) |
| server | none/rootful/rootless | off | container-execution-only | yes |

### Implementation

- `bootstrap.sh` accepts `--profile desktop-builds`; auto-defaults Docker to
  `rootful` for this profile on Ubuntu; rejects it on macOS.
- `install.sh` `validate_target` accepts `desktop-builds:local-dev-with-builds:rootful:{0,1}`.
- `run_server_layer` passes `--skip-baseline` when `PROFILE=desktop-builds`,
  invoking only the Docker install path in `server.sh`.
- `server.sh` `main()` gains a `--skip-baseline` flag that guards
  `install_baseline` and `ensure_time_sync`.

## Consequences

- The retired ADR 0004's invariant "desktop profiles never install Docker" is relaxed:
  the **plain desktop** profile still forbids Docker, but `desktop-builds`
  is a new, explicit, audited escape hatch.
- The `docker_group_membership` safety policy changes from `never-automatic`
  to `explicit`: the bootstrap still does not grant the group, but the
  contract acknowledges that the developer will do so manually.
- The device descriptor for a desktop-builds machine declares
  `profile: desktop-builds`, `docker_mode: rootful`,
  `execution_policy: local-dev-with-builds` — all three must agree, enforced
  by `validate_gds_schemas.py`.
