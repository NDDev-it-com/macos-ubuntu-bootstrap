# rldyour macOS and Ubuntu bootstrap

Plan-first bootstrap for Apple Silicon macOS, Ubuntu 24.04/26.04 desktops, and
headless Ubuntu servers. The current contract is `3.0.1`.

## Profiles

| Target | GUI | Docker | Policy |
|---|---|---|---|
| macOS `desktop` | optional | none | source analysis and local checks |
| Ubuntu `desktop` | optional | none | source analysis and local checks |
| Ubuntu `desktop-builds` | optional | rootful | local builds and tests |
| Ubuntu `server` | none | rootful by default | production server/container host |

Every profile receives the zsh-first terminal environment, source-analysis
tools, language servers, Codex CLI, Claude Code, Grok Build, and the launchers
`cx`, `cl`, and `gk`. These launchers select each vendor's explicit unrestricted
mode; use them only on machines and repositories you trust.

GUI workstations install Google Chrome stable. macOS GUI additionally installs
Ghostty, cmux, ChatGPT, Claude, RustDesk, and Telegram. Ubuntu GUI installs
Chrome, RustDesk, Telegram, desktop integration, and removes Firefox. Headless
profiles do not install GUI applications. Herdr is installed and verified on
macOS and every Ubuntu profile, including headless desktops and servers.
Ubuntu GUI is supported on amd64; ARM64 remains supported with `--no-gui`
because Google and Telegram publish no compatible Linux ARM64 applications.

Desktop source hosts include Node, Python, LLVM/clangd, Go/gopls, Rust with
rust-analyzer, Dart with its analysis server, TypeScript, YAML, Bash, Dockerfile,
HTML/CSS/JSON, TOML, Markdown, Terraform, CMake, GitHub Actions, and Ansible
analysis tooling. The `desktop` profile does not authorize project execution or
deployment. Use `desktop-builds` for local Docker builds/tests.

The Ubuntu server profile installs and verifies a server baseline, Docker,
unattended security updates, and time synchronization. UFW, key-only SSH, and
Fail2ban remain independent explicit opt-ins to prevent accidental lockout.

Ubuntu privilege handling is explicit and fail closed. Root executes the
sourceable server layer directly; a terminal owner authenticates once with
`sudo -v`, after which every step uses only `sudo -n`; passwordless or already
cached sudo also remains non-interactive. A non-TTY Ubuntu desktop GUI may use
PolicyKit only when the root-owned, receipt-verified helper was provisioned by
an earlier trusted root/TTY run. That helper exposes one fixed desktop-GUI
operation and accepts no caller paths, packages, URLs, hashes, environment, or
arbitrary command. The real GUI authorization prompt is `NOT_PROVEN` on hosted
runners and requires disposable real-host evidence.

## Usage

```bash
# Plans (default)
bash scripts/bootstrap.sh --platform macos
bash scripts/bootstrap.sh --platform macos --no-gui
bash scripts/bootstrap.sh --platform ubuntu --profile desktop
bash scripts/bootstrap.sh --platform ubuntu --profile desktop-builds
bash scripts/bootstrap.sh --platform ubuntu --profile server

# Apply
bash scripts/bootstrap.sh --platform macos --apply
bash scripts/bootstrap.sh --platform ubuntu --profile desktop --apply
bash scripts/bootstrap.sh --platform ubuntu --profile desktop-builds --apply
bash scripts/bootstrap.sh --platform ubuntu --profile server --apply
```

Supported recovery skips are `--skip-system`, `--skip-ai`, `--skip-lsps`, and
`--skip-checks`. Authentication is always an owner handoff:

```bash
bash scripts/auth-handoff.sh show
bash scripts/auth-handoff.sh check
```

## Validation

```bash
bash scripts/ci/lint.sh
bash scripts/ci/run-clean-validation.sh
python3 -m pytest
```

`config/script-inventory.json` is the canonical classification of repository
scripts by platform, trust role, interpreter, dependency class, launcher,
evidence class, and applicable gate. Its isolated stdlib validator validates
its own manifest identity before serving gate selections; validation fails
closed when the source tree or launcher graph drifts.

Real platform behavior must also be verified on the corresponding macOS or
Ubuntu host; container checks are not evidence for launchd, systemd, GNOME,
SSH, firewall, Docker daemon, or macOS application behavior.

The machine-readable support and proof boundary is
[`config/support-evidence-matrix.json`](config/support-evidence-matrix.json).
It distinguishes required core behavior from optional real-host capabilities
and prevents hosted or container evidence from being promoted to a stronger
tier. A successful evidence lane may contain typed `NOT_PROVEN` observations
only for optional capabilities; every required capability must be `PROVEN`.
See the [support/evidence reference](docs/reference/support-evidence.md) for the
typed tiers, current hosted coverage, and explicit real-host gaps.
