# Changelog

All notable changes to this module are documented here. Older release history
remains available in immutable Git tags.

## [Unreleased]

### Added

- Weekly discovery of pin drift against official sources. `#66` found seven pins
  behind their upstreams, one a whole minor version, and nothing in the
  repository would have said so — Dependabot covers the GitHub Actions
  ecosystem, and every pin here is a direct upstream artifact it cannot see.
  `scripts/ci/discover_source_drift.py` reads first-party release metadata for
  all twenty-five and reports where each stands. It is discovery only: it holds
  no write permission, opens no pull request, downloads no install artifact, and
  a test asserts it cannot open a file for writing. A refresh stays a reviewed
  change with digests computed from the downloaded artifact. A source that
  contradicts the contract — a missing architecture, a mutable download URL,
  metadata in an unexpected shape — fails the run; a source that is merely
  unreachable is reported as `unknown` and does not, because a report that fails
  on a rate limit is a report people mute.

- Ubuntu 26.04 hosted evidence. Every sandbox lane now runs on both supported
  releases, and the evidence matrix expands per `(lane, release, architecture)`
  so a 24.04 result can never stand in for its 26.04 twin — the artifact count
  goes from 13 to 21 and the gate keys on the release. The container's release
  is a lane property rather than the runner's, so this needs no dependency on
  the `ubuntu-26.04` runner labels, which exist but are public preview and would
  queue indefinitely rather than fail if withdrawn. Each artifact records the
  release it proved and the runner's stability class.

### Fixed

- Stopped superseded evidence runs holding the queue. `evidence-gate` proves
  the artifacts belong to one exact SHA and the release gate resolves a
  candidate through the head whose gate is green, so a run for an older head
  answers a question nobody is asking. With the lane count doubled by 26.04
  coverage and `max-parallel: 2` serialising the sandbox matrix, letting each
  push queue a full run behind the one it invalidated turned two quick
  corrections into two hours of runner time.
- The privilege state machine can use sudo on Ubuntu 26.04. `absolute_tool`
  required a privileged tool to be a real file at a fixed path, but 26.04 ships
  sudo through the alternatives system — `/usr/bin/sudo` →
  `/etc/alternatives/sudo` → `/usr/bin/sudo.ws` — because the release carries
  both the classic implementation and sudo-rs. The strict check refused it, the
  sudo-noninteractive branch was skipped, and a non-TTY 26.04 host fell through
  to `NONINTERACTIVE_AUTH_UNAVAILABLE`: sudo was unusable on a release the
  contract claims to support, and every 26.04 sandbox lane failed on it. The
  check now follows an alternatives chain, bounded against loops, requiring
  every hop to be root-owned and every containing directory to be root-owned
  and closed to others — the property that actually matters, since repointing
  such a link needs root. Symlink modes are not consulted because Linux does
  not enforce them. Artifacts this repository publishes keep the strict,
  symlink-free check, and a test asserts only `/usr/bin/*` tools use the
  link-following one.
- Key-only SSH hardening no longer refuses a valid `authorized_keys` on Ubuntu
  26.04. The preflight asked `test -r` through `sudo`, and coreutils 9.5
  answers `-r` via `access(2)` without granting root its usual override, so a
  correct mode-0600 key file owned by the target user read as unreadable. On
  24.04 the same probe returned true. Measured as root with full capabilities
  on one file: external `test -r` gave 0 on 24.04 and 1 on 26.04, while the
  shell builtin and `test -e` agreed on both. Readability is now answered by
  opening the file, which depends on no coreutils policy about what root may
  read and reads no key material. This was a refusal on a real server, not a
  test artifact, and only the release matrix surfaced it.

- Made the sandbox readiness check release-portable. It waited for systemd to
  report `running`, but on 26.04 `systemd-modules-load.service` fails inside a
  container — it cannot load kernel modules — so systemd settles `degraded` and
  never reaches `running`. A correct 26.04 lane would have timed out after 30
  attempts for a reason unrelated to the bootstrap. Readiness now accepts either
  settled state and records a degraded boot with its failed units in the
  evidence, rather than either rejecting it or tolerating it silently; the
  facility assertions the lane actually depends on still have to hold.

### Security

- Removed `workflow_dispatch` from `platform-evidence`, leaving `pull_request`
  as its only trigger. Those jobs check out a contributor's exact head SHA and
  execute it — they run the bootstrap with `sudo` — so any trigger able to write
  the default-branch Actions cache scope made this a cache-poisoning path:
  unreviewed code running where it can plant an entry a privileged workflow
  later restores. CodeQL reported four such alerts against this file, all of
  them predating the evidence-gate work. A `pull_request` run's cache scope is
  the pull request's own branch, which is the isolation the finding asks for.
  Nothing needed the trigger: re-running a lane still works through re-run-jobs
  on the original run, and the release gate proves a candidate's tree is
  identical to a head whose `evidence-gate` is green rather than asking for a
  fresh run. A test now binds the trigger set and rejects a job condition that
  re-admits one.

### Added
<!-- The privilege state machine below is unreleased work on the #55 line.
     It carried a dated `## [3.1.0] - 2026-08-13` heading while the latest
     GitHub release was 3.0.1, issue #55 was open and the required gate was
     red -- a heading that reads as a published release. Work stays here
     until it is actually released. -->

### Fixed

- Narrowed the macOS validation-path provenance to what a resolver can actually
  establish, per ADR 0010. The schema declared a coherent
  formula/bottle/executable five-tuple per anchor while the resolver flattened
  every variant to a set of `executable_sha256` values and tested membership —
  `formula_revision`, `bottle_tag`, `bottle_rebuild` and `bottle_sha256` were
  never read, so a keg recording one rebuild could be authorized by a hash
  belonging to another. Under a rolling formula the leaf digest is not a pin
  either: homebrew-core moves it on every rebuild, which is what made macOS
  clean validation red and made "append another accepted hash" look like a fix.
  Homebrew anchors now declare their determinism class and carry no build
  digests at all, and the resolver **refuses** those fields rather than ignoring
  them, so they cannot return as decoration. What is enforced is the chain that
  is locally checkable: expected prefix rather than a lookalike, keg ownership
  and mode, a regular executable inside that keg no symlink escapes, the install
  receipt's tap and stable version, and the reported version. A rebuilt bottle
  with identical version now resolves; a wrong reported version or a receipt
  naming a different stable version still does not.

- Replaced `timeout --foreground` around the PolicyKit path, which bounded
  nothing. GNU coreutils documents that mode as not timing out children, and the
  signal it sends goes to a setuid-root `pkexec` an unprivileged launcher may not
  signal at all — so it exited 124 on the deadline while `apt-get`, `dpkg` or
  `curl` kept running as root. Only root can bound root, so descendant ownership
  now lives in the helper: it leads its own process group, escalates TERM to KILL
  over its descendants, reaps them by PID, and reports a typed residual. The
  launcher keeps only the honest half — an authentication bound that
  distinguishes "never authorized, nothing ran" from
  `AUTH_TIMEOUT_OPERATION_RESIDUAL`, using a marker the helper emits before its
  first mutation rather than a guess from elapsed time.
- Made Firefox removal an exact operation. `apt_install --purge firefox` was
  rejected by the helper's own allowlist — neither `--purge` nor `firefox` is a
  member — so a GUI apply aborted under `set -euo pipefail` *after* locale,
  keymap, RustDesk and Chrome had been applied. The call was also inverted:
  `apt-get install … --purge firefox` installs Firefox. Removal is now its own
  operation with its own package list and `apt-get purge`; the install channel
  was not widened into a removal channel.
- Made the shell scanner record heredoc delimiter quoting. It tokenized with
  `shlex(posix=True)`, which strips quotes, so `<<'PY'` and `<<PY` were
  indistinguishable and the gate could not refuse an expanding body on a
  privileged surface. Delimiters are now read from the raw line, and an unquoted
  delimiter on a system-Python surface is refused.
- Named one canonical validation entrypoint. `AGENTS.md` instructed
  `scripts/ci/validate.sh`, which exits 2 without the clean-path resolution;
  CI runs `scripts/ci/run-clean-validation.sh`. The docs now name what CI runs.
- Restored truthful release metadata. `VERSION` and the contract claimed 3.1.0
  and `CHANGELOG.md` carried a dated `## [3.1.0] - 2026-08-13` heading while the
  latest release was 3.0.1, issue #55 was open and the required gate was red.
  Unreleased work is under `[Unreleased]` again.

- Added an explicit Ubuntu privilege state machine for root, one-time TTY
  `sudo -v` plus non-interactive cache use, passwordless sudo, and a narrowly
  allowlisted pre-provisioned PolicyKit desktop helper. Password transport and
  arbitrary privileged command channels remain forbidden; real GUI prompting
  is explicitly not proven by hosted evidence.
- Centralized Chrome signing identity in the machine-readable contract and
  made the privileged installer and independent verifier consume it fail
  closed, including single-key and normalized-fingerprint validation.
- Added no-follow, no-replace, fsync-ordered publication for the root-owned
  helper bundle, with immutable transaction evidence and race-safe preservation
  of unmanaged or divergent targets.
- Added a canonical machine-readable clean-system support/evidence matrix and
  made hosted evidence fail closed when a required capability is unproven or a
  runner/lane architecture is outside the declared proof boundary.
- Bound unprivileged validation tools to explicit root-owned or declared
  managed-package trust classes, including exact Homebrew bottle/keg receipts
  and content-addressed bundle identities; undeclared PATH shadows fail closed.

### Changed

- Refreshed every pinned upstream source against first-party release metadata
  and recomputed each digest from the downloaded artifact: Node.js
  24.18.0 -> 24.19.0, uv 0.11.30 -> 0.12.4, Homebrew.pkg 6.0.9 -> 6.0.17,
  Go 1.26.5 -> 1.26.6, Dart SDK 3.12.2 -> 3.13.0, osv-scanner 2.4.0 -> 2.5.0,
  and ast-grep 0.45.0 -> 0.45.1. Bun 1.3.14, gopls v0.23.0, Rust 1.97.1,
  Herdr 0.8.0, Telegram 7.0.9, RustDesk 1.4.9, Codex 0.147.0, the Chrome
  signing key, both vendor AI installer scripts, and the remaining eight
  pinned source tools were re-downloaded and confirmed unchanged. The macOS
  Dart floor stays at 3.12 on purpose: `dart-sdk` is a rolling Homebrew
  formula whose determinism class is decided in #63, and raising the floor
  before that decision would fail verification on a host whose already
  installed formula the installer deliberately preserves.

### Added

- ADR 0010 takes the macOS package determinism decision the repository had
  drifted into without recording: the Homebrew formula and cask sets are
  intentionally rolling, and anything whose exact bytes matter is installed from
  an immutable upstream artifact instead, as Herdr already was. Every macOS
  package now carries a determinism class in `macos_package_determinism`, bound
  to the installer's arrays by tests, so a package cannot be added without one.
  The record also fixes what provenance metadata may claim -- only facts a
  resolver can establish on the machine it runs on -- and names each field it may
  not claim together with the reason, so `executable_sha256` cannot be re-added
  for a rolling formula whose digest moves on every homebrew-core rebuild.

### Fixed

- Made `evidence-gate` prove something. It read four `needs.*.result` values and
  never opened an artifact, and the runtime check inside `finalize_evidence`
  re-tested an invariant the matrix validator already refused statically, so it
  could never fire. REQUIRED capabilities now declare the steps a lane must
  record; the lane script appends a step name only after the command that proves
  it returns, so a successful lane that skipped a step fails. The gate downloads
  all thirteen artifacts and requires the payload count, the (lane, architecture)
  set, each result, each capability list, each observation ledger, each
  `not_proven` list and each SHA to hold. `evidence-gate` is now in the
  checked-in required-check projection.
- Made release preparation verify both mandatory gates before publication, on
  every trigger including a tag push, which previously published without asking
  about hosted evidence at all. `evidence-gate` reports against a PR head rather
  than the merge commit that lands, so rather than give `platform-evidence` a
  default-branch trigger — it checks out a contributor's head SHA and runs it,
  and a default-branch trigger would hand that write access to the default-branch
  Actions cache scope — the release gate proves the candidate's tree is identical
  to the head whose `evidence-gate` is green. `main` already guarantees that
  through `strict_required_status_checks_policy`, and the gate verifies it rather
  than assuming it. `platform-evidence`'s `sha` dispatch input was removed for the
  same reason: it accepted any commit reachable from the repository, including a
  fork's PR head under `refs/pull/*`.

- Connected the device integrity receipt to the lifecycle it documents.
  `scripts/device_integrity.py` had no runtime caller, and its
  one-owner-per-harness check read a contract key that did not exist, so it
  could not report drift — while ADR 0007 and `AGENTS.md` described receipts as
  a working mechanism. Apply now writes the receipt after strict verification
  passes, `verify.sh --strict` reads it back and compares the device to it
  exactly, and `harnesses.detection` in the contract gives the ownership check
  something to check: `codex` is enforced to the prefix this repository installs
  it into, and a second copy from a package-manager global is reported by name.
  `claude-code` and `grok-build` are observe-only because their vendor installer
  owns the target. Exact-version assertions are now scoped to the platforms the
  contract actually pins, so a macOS device is no longer reported as drifting
  from `ubuntu_*` fields Homebrew cannot honour.

- Closed the macOS/Ubuntu interactive tool boundary. `templates/terminal/zshrc`
  guards every alias with `command -v`, so a tool only one platform installs
  degrades silently rather than erroring. Ubuntu now installs `eza`, `lazygit`,
  `difft` and `jaq` as pinned source tools, macOS gains `btop`, `duf` and
  `hexyl`, and six guards for `dust`, `dua`, `procs`, `doggo`, `gping` and
  `viddy` were removed because no profile has ever installed them on either
  platform. `duckdb`, `jnv`, `xh` and `yazi` stay macOS-only, each with its
  reason recorded. The contract now owns the boundary as `terminal_tools`, and
  tests bind the zshrc guard set to it and it to both installers, so a future
  addition cannot become a silent no-op. The test that previously asserted the
  guards existed carried a literal list including all six phantom tools; it now
  derives that list from the contract.

- Bound every version the Ubuntu verifier asserts to the contract. The
  verifier checks uv with an escaped-dot regex, so it was the one pin a
  literal refresh could not reach: the installer and the verifier could
  publish and demand different versions, and a strict verify would then fail
  on a correctly installed host. Two parity tests now prove the verifier
  asserts the contract's versions and asserts no others.
- Repaired Ubuntu GUI strict verification, which could not pass in any state:
  the Chrome signing-key check was written inside a double-quoted command
  substitution, so its escaped quotes reached `awk` verbatim and the verifier
  aborted under `set -o pipefail`. Vendor-key identity is now one library
  primitive shared by the Chrome and Docker installers and verifiers, and it
  rejects a keyring carrying a second primary key.
- Stopped a failed user tool stranding the layers behind it. Herdr is a user
  tool on every profile, so one divergent Herdr left a server without Docker,
  without the vendor AI CLIs and without verification. Optional-layer failures
  are now reported once, after every layer has been attempted.
- Made plan mode read-only. A plan created `~/.local/bin`, `~/.bun/install/global`
  and `~/.cache/uv` on every Ubuntu profile, and reported a Docker daemon health
  verdict it had never obtained because the probe was routed through the
  dry-run helper.
- Verified every tool the Ubuntu installer publishes. starship, atuin, carapace,
  semgrep, ty, biome, oxlint, markdownlint-cli2, prettier,
  ansible-language-server and gh-actions-language-server were installed on every
  profile and checked by nothing.
- Aligned the desktop layer with its contract: desktop entries follow the
  GUI-capable profile set, the GUI font is a declared package group rather than
  an inline literal, and every managed launcher guards its own program with
  `TryExec`.
- Made the required plan lane exercise the full plan path instead of argument
  parsing alone, and fail if a plan writes to the home directory it describes.
- Removed a Dependabot ecosystem pointing at a directory deleted with the
  browser layer, replaced the release lane's unpinned `pip` install with the
  contract-pinned, SHA-256-verified `uv` path used everywhere else, and repaired
  citations to the two decision records retired in 3.0.0.

## [3.0.1] - 2026-08-13

### Fixed

- Made Herdr permission verification deterministic across BSD/macOS and GNU/Linux
  test hosts, with explicit fail-closed shell control flow and repeat-apply coverage.
- Installed the exact receipt-bound Herdr 0.8.0 macOS release artifact instead
  of accepting the older mutable Homebrew formula.
- Published terminal plugins from verified pinned Git commit trees instead of
  exposing mutable checkout metadata to the executable Antidote source layer.
- Made Ubuntu server verification and device receipts prove the complete
  contract 3.0.1 source-tool set.
- Restricted Ubuntu GUI apply to amd64 because required vendor applications do
  not publish compatible Linux ARM64 builds; ARM64 no-GUI profiles remain
  supported.
- Synchronized release metadata and architecture policy across the contract,
  implementation, tests, ADRs, and operator documentation.

- Updated Herdr to `0.8.0`, with verified macOS and Linux x86_64/aarch64
  installation and verification.
- Updated Telegram Desktop to the official `7.0.9` release and pinned its Linux
  x86_64 archive and source assets to tag commit `a1e89e1f`.
- Declared Herdr on macOS and every Ubuntu profile and Telegram on supported GUI
  targets.

## [3.0.0] - 2026-08-13

### Changed

- Standardized the active AI CLI set on official Codex CLI, Claude Code, and
  Grok Build distributions, with verified installer inputs and `cx`, `cl`, and
  `gk` unrestricted-mode launchers.
- Made Google Chrome stable the sole installed browser.
- Added ChatGPT, Claude, RustDesk, Telegram, Ghostty, and cmux to the applicable
  macOS GUI composition; added Chrome, RustDesk, Telegram, GNOME integration,
  and Firefox removal to Ubuntu GUI.
- Extended Go, Rust, Dart, language servers, terminal tooling, and local static
  verification to the supported profile matrix while retaining explicit
  execution-policy boundaries.
