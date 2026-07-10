# ADR 0004: Profile Composition and the CloakBrowser Boundary

- Status: accepted
- Date: 2026-07-10

## Context

One bootstrap repository must configure Apple Silicon macOS desktops, Ubuntu
24.04/26.04 desktops, and Ubuntu 24.04/26.04 servers without turning every
machine into the same development host. Desktop machines are used to edit and
inspect source through language servers. Project builds and runtime execution
belong on servers. GUI applications are useful on some desktops but invalid on
headless machines. Browser automation must be predictable across every role.

## Decision

The target is composed from independent dimensions:

- platform: `macos` or `ubuntu`;
- role: `desktop` or Ubuntu-only `server`;
- GUI overlay: enabled/disabled for desktops, always disabled for servers;
- Docker mode: `none` on desktops and `none|rootful|rootless` on servers.

Desktop profiles install source-analysis tools, LSPs, quality checks, AI CLIs,
terminal tooling, and CloakBrowser. They never install Docker or a general
project runtime or configure local build execution. Server profiles install
build essentials and an explicit Docker mode in addition to the headless
toolchain.

All browser automation crosses one fail-closed boundary:

- CloakBrowser is mandatory on every profile.
- A managed service owns `http://127.0.0.1:9222`; it is never exposed on a
  non-loopback address.
- Chrome DevTools MCP, Playwright CLI, and Webwright use wrappers that reject
  alternate executables, endpoints, configuration files, and auto-started
  stock browsers.
- A missing or unhealthy CloakBrowser endpoint stops browser automation. There
  is no stock Chromium fallback and no compliant `--skip-browser` mode.
- Production provider pins, repository origins, managed paths, and the signed
  binary flow are source-owned; environment trust-root overrides are rejected.
- Product-embedded browsers are outside the trusted boundary unless upstream
  exposes a verifiable fixed external-CDP contract.

Installation is plan-first. Apply is explicit, exact managed versions are
updated idempotently, unmanaged files are preserved, and interactive account
authentication is a documented post-install handoff. SSH authentication and
UFW mutation are explicit server options because generic automation can lock
out a remote host. Docker group membership is never granted automatically.

## Consequences

- The same repository supports GUI and no-GUI desktops without weakening the
  browser invariant.
- Local workstations cannot accidentally become project runtime hosts through
  this bootstrap.
- Rootful Docker remains the practical Ubuntu server default; rootless mode is
  available when its networking, cgroup, storage, and privileged-port limits
  are acceptable.
- ZCode remains manual unless the owner supplies a separately verified SHA-256,
  because upstream does not publish a checksum/signature manifest.
- Full server validation requires a real Ubuntu VM with systemd. Container-only
  CI cannot prove SSH, firewall, time synchronization, or Docker daemon state.
