<!-- Memory Metadata
Last updated: 2026-07-10
Last verified: 2026-07-10
Last commit: 9f8f97792500a7af4787448a1478fbe5c9ca12cc chore(release): new-mac-or-ubuntu 0.3.9 (other)
Scope: CLI runtime and package baselines
Area: RUNTIME
-->

# Runtime Baselines

## Scope
CLI runtime and package baselines

## Current source of truth
- `path:README.md`
- `path:scripts/lib/common.sh`
- `path:config/rldyour-contract.json`

## Last verified
- date: 2026-07-10
- commit: `9f8f97792500a7af4787448a1478fbe5c9ca12cc`
- checked by: native Codex launcher convergence

## Facts
- Current runtime pins and supported platforms are derived from config/rldyour-contract.json, frozen locks, installer scripts, and verification scripts.
- Managed Codex wrappers execute the frozen platform-native binary directly and
  clear npm/Bun/pnpm package-manager provenance so diagnostics and update paths
  cannot escape into another global prefix.

## Evidence
- `commit:25e5b7bbf07ca90192022ac8fb9f300d443b9410`
- `commit:9f8f97792500a7af4787448a1478fbe5c9ca12cc`
- `path:README.md`
- `path:scripts/lib/common.sh`
- `path:config/rldyour-contract.json`

## Known pitfalls
- Treat this memory as derived context. Current code, configuration, runtime output, and GitHub state override stale memory text.

## Update policy
Update after verified changes to the referenced source-of-truth files.

## Delete / merge policy
- Delete or merge only when the referenced source-of-truth files no longer support this memory and the replacement memory preserves the durable facts.

## Applies to

- The scope and source-of-truth paths declared in this memory.

## Source of truth

- The `Current source of truth` entries above, plus current code, configuration, tests, git state, and live GitHub state where this memory references live release or repository surfaces.

## Invariants

- Current code, configuration, tests, validators, git state, and live GitHub state override this memory whenever they disagree.

## Current State

- Treat the `Facts` section as the current durable state. Do not treat historical evidence, superseded notes, or previous release entries as current.

## Do Not Infer

- Do not infer runtime versions, product versions, commits, permissions, release state, security posture, or tool behavior from this memory without checking the source of truth.

## Update Triggers

- Update after verified changes to the source-of-truth files, runtime baselines, release tuple, validation gates, live release state, or durable agent-workflow contracts.

## Validation Commands

- Run the rldyour control-plane Serena memory validators in strict mode: `validate_serena_memory_schema` (`--strict-mode strict-all`) and `validate_serena_memory_semantics` (`--strict-current-facts --strict-metadata-dates --strict-evidence-commits`).

## Repair Procedure

1. Re-read the source-of-truth files listed above.
2. Update only verified current facts; move stale facts into historical evidence.
3. Rerun the validation commands until green.
