# ADR 0007: whole-device integrity receipt

Status: accepted

Ubuntu fixed runtime hosts and source tools are installed into managed,
versioned trees with exact contract metadata and content receipts. Verification
checks both version and provenance; an unrelated same-version binary on `PATH`
does not satisfy the contract. Mutable vendor channels are limited to software
where prompt security updates are the explicit policy, such as Google Chrome.

## When the receipt is written and read

`scripts/device_integrity.py` is invoked at two points, and only those:

- **apply**, from `verify_apply` in `scripts/ubuntu/install.sh`, *after* strict
  verification has passed. The receipt records a state something else already
  proved; it is never itself the proof. A prior receipt that fails
  self-integrity is retained beside the active one as `.rejected.N` rather than
  destroyed, because that file is the evidence of tampering.
- **strict verify**, from `scripts/ubuntu/verify.sh --strict`, which re-collects
  the device state and compares it to the receipt exactly.

The two answer different questions. The verifier's own checks ask whether each
declared thing is present and correct *now*. The receipt asks whether anything
has changed since a state was recorded — a binary replaced in place, a managed
symlink repointed, a tool that still reports the right version from the wrong
path. A device that this repository has never applied has no receipt, and that
is not a verification failure; only a receipt that no longer matches is.

The hosted sandbox lanes run apply → strict verify → apply → strict verify, so
every lane exercises both the write and the comparison.

## What the harness ownership check observes

`harnesses.detection` in the contract makes one-owner-per-harness checkable
rather than prose. Each entry names the command, the prefix its owner publishes
into, and whether that prefix is enforced:

- `enforcement: owned-prefix` — this repository installs the harness and chose
  the target, so resolving outside it is drift. `codex` is installed from a
  verified npm tarball into a prefix this repository names, so a `codex` coming
  from a package-manager global instead is exactly the condition the policy
  exists to catch, and is reported by name.
- `enforcement: observe-only` — the vendor's own installer picks the target and
  may change it between releases. `claude-code` and `grok-build` are recorded so
  drift is visible, but this repository does not own those paths and will not
  fail a device for them. Enforcing a path we do not choose would fail a correct
  install.

An all-`observe-only` block would be the previous no-op with more words, so a
test requires at least one enforced harness.

## What the receipt does not assert

The `ubuntu_*` contract fields pin exact artifacts, which only Ubuntu installs.
macOS resolves the same runtime hosts through Homebrew, which serves current
metadata and preserves an already installed formula, so a macOS device
legitimately carries a different patch. Version equality is therefore asserted
only on the platforms the contract pins exactly (`EXACT_VERSION_PLATFORMS`);
elsewhere the versions are still collected into the receipt, they are simply not
asserted. Whether macOS should pin exactly is a separate contract decision
(issue #63) and this tool must not pre-empt it.

`user_tools` are unaffected by that scoping: Herdr is an exact pinned release
artifact on both platforms and stays asserted everywhere.
