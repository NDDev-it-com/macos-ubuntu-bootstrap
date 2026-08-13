# Installation guide

Run `scripts/bootstrap.sh`; platform installers are internal composition layers.
Plan mode is the default and Ubuntu always requires an explicit profile.

```bash
bash scripts/bootstrap.sh --platform macos [--no-gui] [--apply]
bash scripts/bootstrap.sh --platform ubuntu --profile desktop [--no-gui] [--apply]
bash scripts/bootstrap.sh --platform ubuntu --profile desktop-builds [--no-gui] [--apply]
bash scripts/bootstrap.sh --platform ubuntu --profile server [--apply]
```

`desktop` provisions editing, LSPs, scanners, formatters, terminal tooling, and
local static checks without Docker. `desktop-builds` adds rootful Docker for
local builds/tests. `server` configures a headless Docker server and keeps risky
network hardening behind explicit flags.

Every profile installs official Codex, Claude Code, and Grok Build distributions
through verified downloads. `cx`, `cl`, and `gk` launch them without approval or
permission prompts. Authentication is performed afterward with
`scripts/auth-handoff.sh` and is never automated by bootstrap.

Herdr is a required terminal tool on macOS and every Ubuntu profile. Both
platforms install the pinned architecture-specific binary from the official
`herdrdev/herdr` GitHub release and verify its checksum, managed launcher,
runtime receipt, and exact version. Bootstrap does not depend on a lagging
or subsequently updated Homebrew formula for the managed macOS runtime. The pinned upstream identity,
independently verified asset hashes, and update policy are recorded in the
[dependency source register](reference/source-register.md).

GUI profiles install current Google Chrome stable. macOS also installs the
desktop applications listed in the contract. Ubuntu GUI installs RustDesk and
Telegram, configures GNOME, and removes Firefox. `--no-gui` retains command-line
tools, Herdr, language servers, and source checks.

Ubuntu Telegram Desktop is pinned to the official `telegramdesktop/tdesktop`
GitHub Linux tarball. That upstream release currently provides Linux x86_64 but
not Linux ARM64; Google Chrome has the same architecture boundary. Ubuntu ARM64
therefore supports `--no-gui` profiles only, and a real ARM64 GUI apply fails
before changing the host rather than claiming a partial GUI installation.

On Ubuntu, apply selects privilege once before changing the machine. A terminal
session performs an ordinary `sudo -v` prompt when required, then bootstrap uses
only cached, non-interactive `sudo -n` checks. Root is supported by the
sourceable server layer; the full desktop compositor remains a non-root owner
process. A non-TTY desktop GUI can request PolicyKit authorization only after a
trusted root/TTY run has installed the narrow receipt-owned helper. A clean
machine cannot safely elevate a user-writable checkout through pkexec, so an
absent helper fails before mutation with instructions to run once from a TTY.
Denied, cancelled, unavailable, or timed-out authorization never falls back to
another prompt mechanism. No mode accepts a password through bootstrap input.

Server hardening is explicit:

```bash
bash scripts/bootstrap.sh --platform ubuntu --profile server --apply \
  --harden-ssh --enable-ufw --with-fail2ban
```

Keep the current SSH session open until a second key-authenticated connection
succeeds. UFW alone does not contain Docker-published ports.

Validate changes with `bash scripts/ci/lint.sh`, `bash scripts/ci/run-clean-validation.sh`,
and `python3 -m pytest`. Platform verification requires real target machines.

Repository script ownership is declared once in `config/script-inventory.json`.
Its isolated stdlib meta-validator rejects missing, renamed, duplicate, newly
unclassified, or cyclic tools, interpreter/dependency/launcher drift, invalid
platform assignments, and inapplicable evidence gates.
Diagnostics use stable typed codes and canonical phase precedence: schema and
cardinality, filesystem path identity, launcher target resolution, launcher
cycles, then role/dependency/gate invariants. Within a phase the lexically first
`(code, path, detail)` is authoritative, independent of manifest entry order.
Shell lint selection is emitted as a versioned JSON receipt containing the
sorted unique paths, exact cardinality, and SHA-256 of their newline-delimited
representation. `lint.sh` consumes only a validator-verified receipt, so both
pinned and current ShellCheck runs share the same subject boundary.
