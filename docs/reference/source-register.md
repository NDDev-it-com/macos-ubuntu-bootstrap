# Verified dependency source register

`config/rldyour-contract.json` is the machine-readable authority for dependency
identity. This page records the human-auditable source decision; privileged
installers consume a root-owned copy of that contract and verifiers parse it
independently rather than carrying a second trust-root literal.

## Unprivileged CI validation-tool trust

`config/rldyour-contract.json#ci_validation.managed_package_anchors` is the
single provider-neutral allowlist for developer/CI validation executables that
are not supplied by a root-owned system path. A declaration binds the provider,
package identity, exact version, anchored installation root, receipt/provenance
metadata, executable-relative path, and version output. Content-addressed
bundles additionally bind receipt and executable SHA-256; each Homebrew
provenance variant binds an exact homebrew/core formula revision, bottle tag,
rebuild number, bottle SHA-256 and resulting installed executable SHA-256.
The resolver also binds the installed versioned-keg receipt and captures and
revalidates identity around a bounded version probe. Validation reads these
exact local artifacts directly; it never
invokes Homebrew, consults ambient `HOME`/`PATH`, updates metadata or uses the
network.

The ShellCheck 0.11.0 variants were reconciled on 2026-08-13 against the
official `Homebrew/homebrew-core` formula revisions
`4a47db2a60995b1e7a5a0024b7406de197647c15` (rebuild 0) and
`11b85b79adabddf823a733445e86b9ad2e9b0141` (rebuild 1). The current
`arm64_tahoe` bottle digest is
`102f7f385855df8eabf5c9017b8d729a02a5ccca810aa23e3ae700a46226ab70`;
the older preserved installed leaf and current bottle-derived installed leaf
are separate explicit variants rather than an unordered hash exception.
Ripgrep 15.2.0 is bound to formula revision
`666e305a8f602401e66a29c2198a4139b52629ee` and its current
`arm64_tahoe` bottle. There is no repository generator or second inventory for
these values: the JSON contract is the sole generated-provenance input and all
tests/resolvers consume or independently validate that structure.

The Homebrew global prefix and `bin`/`Cellar` namespaces may be writable by the
package-manager owner or group. That exception does not extend to an undeclared
formula, a different keg/version, an escaping alias, mixed ownership, or a
group/world-writable versioned subtree. Ambient higher-precedence shadows fail
closed. System tools use the separate root-owned/non-group-writable trust class.
These rules apply only to unprivileged validation tooling and never relax the
root-owned source and parent-chain checks of the Ubuntu privileged helper.

## Ubuntu Chrome signing identity and privilege protocol

Verified 2026-08-13 against Google's official
[Linux software repositories](https://www.google.com/linuxrepositories/): the
active public signing fingerprint and key URL stored under the Chrome apt-source
entry in `config/rldyour-contract.json` are the sole machine-readable trust
producer. The narrow root helper normalizes and requires one 40-hex fingerprint
from that root-owned contract, and independently rejects a downloaded key with
zero, multiple, or a different primary fingerprint. Callers cannot supply or
override the key URL, fingerprint, repository, keyring, package, or command.

The same Chrome entry owns the normalized accepted APT source identities. Both
the vendor form `/linux/chrome/deb` and the supported repolib form
`/linux/chrome-stable/deb` require exact HTTPS scheme, `dl.google.com` host,
stable suite, main component, amd64 architecture, and the managed root-owned
keyring. The isolated contract parser derives runtime matching from those
structured fields; it does not carry a second URL regex. Userinfo, ports,
queries, fragments, alternate schemes or hosts, lookalike paths, missing
signature binding, and malformed one-line/deb822 sources fail closed.

The elevation behavior follows the Ubuntu
[sudo manual](https://manpages.ubuntu.com/manpages/noble/man8/sudo.8.html):
interactive terminals use `sudo -v` once and all later checks use `sudo -n`.
The optional GUI path follows the upstream
[polkit architecture](https://polkit.pages.freedesktop.org/polkit/polkit.8.html)
and [pkexec contract](https://polkit.pages.freedesktop.org/polkit/pkexec.1.html).
PolicyKit binds the exact installed helper and its single desktop-GUI operation;
the helper additionally binds the pkexec process, caller UID, active session,
full executable ancestry, and receipt-owned contract. Hosted runners prove the
protocol and negative boundary but cannot prove an interactive GUI prompt.

The privileged Python boundary uses Ubuntu's system interpreter, not a project
virtual environment. Its declared minimum is Python 3.12 because Ubuntu 24.04
defaults to 3.12, while Ubuntu 26.04 defaults to 3.14. Embedded parsers and the
secure publisher therefore use only Python 3.12 syntax and standard-library
APIs, and CI executes their contract on both 3.12 and current 3.14. Sources:
[Ubuntu 24.04 release notes](https://documentation.ubuntu.com/release-notes/24.04/),
[Ubuntu 26.04 LTS summary](https://documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users/),
and the [Ubuntu system-Python contract](https://documentation.ubuntu.com/ubuntu-for-developers/howto/python-setup/).

The audited system-Python surfaces are:

| Surface | Invocation/owner |
|---|---|
| source contract and profile validation | two isolated snippets in `scripts/ubuntu/privilege.sh` |
| installed path/contract/pkexec identity | three isolated snippets in `scripts/ubuntu/privileged-helper.sh` |
| dirfd/no-follow publisher | `scripts/ubuntu/secure-publish.py` via `/usr/bin/python3 -I` |
| publication authority modes | `config/rldyour-contract.json#privilege.publication_authorities`; root-production remains strict, actor-sandbox is confined beneath an explicit private fd anchor |
| publication authority diagnostics | `config/rldyour-contract.json#privilege.authority_diagnostics`; bounded deterministic receipts expose only authority role, destination class, component index, expected/observed identity metadata, parent identity, and typed failure code—never destination component names. Directory replacement identity is device+inode+type; uid/gid/mode are rechecked independently as authority policy, while link count/size/timestamps are diagnostic-only operational metadata. |
| runtime and Herdr verification | two isolated parsers in `scripts/ubuntu/verify.sh` |
| Chrome source/fingerprint verification | exact-path isolated `scripts/ci/shell_contract.py chrome-runtime` CLI invoked by `scripts/ubuntu/verify.sh` against the installed root-owned contract |
| server network/CIDR validation | three isolated parsers in `scripts/ubuntu/server.sh` |

The Chrome runtime consumer returns typed exit 3 when no accepted installed
source exists or when its identity/binding is malformed. The verifier converts
that failure into `missing: valid Chrome source and trust contract`; it does not
maintain a second grep-based source vocabulary.

The exact IDs, paths and heredoc/script kinds live in
`privilege.system_python_surfaces`; stable `python-surface:` markers bind that
manifest to shell-aware structural inventory. Shared unprivileged Python
helpers in `scripts/lib/common.sh` and test fixtures are outside this root
authority manifest. No authority surface depends on third-party Python modules
or a mutable user interpreter.

`privilege.shell_control_flow` is the machine-readable semantic guard model for
the privileged shell boundary. It names each guard owner, predicate class,
failure exit and the operation that must occur only after validation. Tests
exercise the declared outcomes and reject weakened bounds or unsafe ordering;
they do not require one whitespace layout or `test` operator spelling. The
canonical production form is explicit `if`/`elif`/`else`, with no SC2015
suppression or `A && B || C` fallback semantics.

Repository parity checks use the single exact-path, isolated, non-executing CLI
at `scripts/ci/shell_contract.py`. Its versioned bounded JSON contract accepts one-line and
multiline indexed arrays, literal quoted or escaped words, comments,
continuations, whitespace, and empty arrays. It rejects duplicate, append,
indexed or scalar reassignment; unclosed or malformed syntax; shell operators;
and command, process, arithmetic, or parameter expansion. The same module owns
the marked isolated-Python inventory. This keeps contract verification
independent from runtime Bash evaluation while preserving exact element order
and duplicate visibility.

The JSON-to-consumer vocabulary is also centralized in that CLI:
`ubuntu-install-source-baseline` is the ordered `baseline` group;
`ubuntu-desktop-build` is the ordered `desktop_build` group;
`ubuntu-desktop-system` is ordered `baseline + desktop_build`; and
`ubuntu-desktop-gui-addon` adds only the fixed font package and the uniquely
declared Chrome package identity. Consequently `software-properties-common`
retains its exact JSON position after `miller` in every baseline consumer;
tests never prepend or otherwise reconstruct it independently.

Privilege authority mappings are unordered keyed identity sets: JSON ordering
does not grant authority, every identity must be unique within its owner key,
and structural inventory is compared after canonical keyed normalization.
Source order is semantic only for the explicitly named Ubuntu package-sequence
transformations and static shell arrays described above.

The test-only Bash function harness uses the same POSIX object distinction as
its cleanup contract: directory ownership is bound by held parent/stage file
descriptors and exact dev/inode/type/uid/gid/mode plus an enumerated entry set;
directory link counts are operational filesystem metadata and are not treated
as identity. Generated regular files additionally require one link, exact mode,
size, and inode identity. All removal is relative to held directory descriptors
and any unprovable or replaced object is preserved as typed residual debt. This
follows Python's documented [`dir_fd` and no-follow interfaces](https://docs.python.org/3/library/os.html#files-and-directories),
POSIX/Linux [`unlinkat`](https://man7.org/linux/man-pages/man2/unlinkat.2.html),
the Linux [`stat` contract](https://man7.org/linux/man-pages/man3/stat.3type.html),
and Apple's [`stat` contract](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/stat.2.html).

## Herdr 0.8.0

Verified 2026-08-13 against the official
[v0.8.0 release](https://github.com/herdrdev/herdr/releases/tag/v0.8.0), the
[GitHub releases feed](https://github.com/herdrdev/herdr/releases.atom), and the
[upstream update manifest](https://herdr.dev/latest.json). During hosted
Attempt 2 earlier that day, the stable Homebrew formula still installed 0.7.5;
it subsequently caught up to 0.8.0. That interval was normal downstream
packaging lag, not runner or network failure. A downstream formula cannot prove
the product's exact artifact identity even after its version catches up, so
bootstrap installs immutable upstream release assets directly:

The annotated `v0.8.0` tag object is
`857196dee1ce98df53efdd3f437aa2ac8a75b608` and resolves to commit
`346411fa21afd297f5ed3b3fa56f9e3fbf7654b7`. The upstream tag is unsigned, so
asset identity is fail-closed on the independently verified SHA-256 values below.

| Target | Official asset | SHA-256 |
|---|---|---|
| macOS Apple Silicon | `herdr-macos-aarch64` | `d53a9f93fccfdfcc55632927bf51002f5add0aa7990bcdf508ffbd84ac658178` |
| Linux x86_64 | `herdr-linux-x86_64` | `b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28` |
| Linux aarch64 | `herdr-linux-aarch64` | `f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87` |

The live upstream manifest is evidence for source discovery and update PRs only;
installation never resolves `latest` and uses only the exact tag URLs and hashes
stored in the contract. Bootstrap also never invokes `herdr update`; version
changes arrive through reviewed update PRs that refresh the tag, commit, asset
URLs, hashes, tests, and this register together.
