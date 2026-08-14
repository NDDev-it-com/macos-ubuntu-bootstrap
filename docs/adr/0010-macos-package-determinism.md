# ADR 0010: macOS package determinism, and what its provenance may claim

Status: accepted

## Context

`scripts/macos/install.sh` resolves its Homebrew set by bare name.
`BREW_SOURCE_PACKAGES` lists sixty-four formulae and `GUI_CASKS` seven casks,
and `ensure_formula`/`ensure_cask` install whatever the current metadata serves
and preserve a formula that is already installed. One release of this adapter
therefore yields different tool versions on two Macs depending on when each was
bootstrapped and what was on it beforehand.

That is a decision this repository had never actually taken. It had drifted into
it, and then documented the opposite: a provenance schema described a coherent
five-tuple per anchor —

```json
{"formula_revision": "…", "bottle_tag": "arm64_tahoe", "bottle_rebuild": 0,
 "bottle_sha256": "…", "executable_sha256": "…"}
```

— while the resolver flattened every variant to a set of `executable_sha256`
values and tested membership. `formula_revision`, `bottle_tag`, `bottle_rebuild`
and `bottle_sha256` were never read. A keg whose receipt recorded one rebuild
could be authorized by a hash belonging to another: the chain the schema
described was not the chain anything checked.

The failure was structural rather than incidental. `brew update` refreshes
`homebrew/core`, a formula rebuilds, its `executable_sha256` moves outside the
frozen set, and macOS clean validation fails. The reflex fix had already been
applied once — the shellcheck anchor carried two variants differing only by
`bottle_rebuild` 0 → 1 — and a third hash would restore green until the next
rebuild.

Two options were available and only one of them is honest.

## Decision

**The Homebrew set is intentionally rolling, and the provenance schema may claim
only what is verifiable locally.**

Every package this adapter installs on macOS belongs to exactly one determinism
class. `config/rldyour-contract.json` records the class per package under
`macos_package_determinism`, and tests bind that block to the installer's arrays
so a package cannot be added without classifying it.

| Class | Meaning | Members |
|---|---|---|
| `immutable-upstream-artifact` | Exact URL and digest tracked in this repository; Homebrew is not the source | Homebrew itself (`Homebrew.pkg`, plus the notarizing team), Herdr |
| `rolling-homebrew-formula` | Whatever `homebrew/core` currently serves; an already installed keg is preserved | the `BREW_SOURCE_PACKAGES` set |
| `rolling-homebrew-cask` | Whatever the cask currently serves | the `GUI_CASKS` set |
| `registry-pinned` | Exact version from a package registry, integrity from its own transparency contract | `BUN_LSP_PACKAGES`, the Codex npm tarball |

### Why rolling, and not exact

Pinning sixty-four formulae exactly is not a matter of writing sixty-four
versions down. Homebrew has no supported way to install an arbitrary older
formula version: it would require a pinned tap or vendored formula files per
package, re-pinned on every upstream rebuild, and it would fight
`ensure_formula`'s deliberate refusal to upgrade software the owner already has.
The result would be a large, brittle mechanism that still could not promise a
byte-identical Mac, because Homebrew's bottles are rebuilt against moving system
libraries.

The things that genuinely must be exact are already exact, and are already
outside Homebrew for that reason. Herdr is installed from a checksum-pinned
GitHub release asset specifically so that a Homebrew formula cannot be
substituted for it, even once its version catches up. Homebrew itself arrives as
a notarized `Homebrew.pkg` with a tracked digest and a verified signer team.

So the boundary is: **anything whose exact bytes matter is not a Homebrew
package.** What remains in Homebrew are developer tools where current is
preferable to frozen, and where a version floor is the property that actually
matters. `rldyour::require_cmd_min_version` expresses that floor.

### What the provenance schema may claim

A schema field that nothing reads is not documentation, it is decoration that
reads as a guarantee. The validation-path provenance may declare only facts a
resolver can independently establish on the machine it is running on:

- the Homebrew prefix, and that it is the expected one rather than a lookalike;
- the keg path, its ownership and its mode;
- that the resolved executable is a regular file inside that keg and not a
  symlink escaping it;
- the version the executable reports.

It may **not** declare `formula_revision`, `bottle_tag`, `bottle_rebuild` or
`bottle_sha256`. Those describe a build this repository does not control, cannot
re-derive from the installed keg, and does not pin — and every homebrew-core
rebuild moves them. They are removed from the schema rather than left unread.

`executable_sha256` is the specific field that made macOS validation red. Under
a rolling class it is not a pin at all: it changes whenever homebrew-core
rebuilds, so freezing it converts a normal upstream event into a red required
check. It is removed with the rest of the tuple. **A third
`executable_sha256` exception must not be added.** If the argument for adding one
ever seems strong, the thing being asked for is the exact class, and that is a
change to this record.

### Ubuntu is unaffected

Ubuntu pins exact artifacts with tracked per-architecture digests, and that stays
as it is. The two platforms genuinely differ, and the contract now says so rather
than implying a symmetry that does not exist. `scripts/device_integrity.py`
asserts the `ubuntu_*` version fields only on Linux for the same reason.

## Consequences

- Two Macs bootstrapped from one release may carry different patch versions of a
  Homebrew tool. That is now a declared property, not an accident, and
  `macos_package_determinism` is where a reader finds it.
- A macOS version floor is enforced with `require_cmd_min_version`; raising a
  floor is a deliberate act, because `ensure_formula` preserves an already
  installed keg and a raised floor will fail verification on a Mac this
  repository chose not to upgrade. The Dart floor is deliberately 3.12 while
  Ubuntu pins 3.13.0.
- A package added to `BREW_SOURCE_PACKAGES` or `GUI_CASKS` without a
  determinism class fails a test.
- Anyone wanting byte-identical Macs must move the package out of Homebrew into
  `immutable-upstream-artifact`, as Herdr already is. That is the supported path
  and it is per package, not a global switch.
