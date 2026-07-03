<!-- Memory Metadata
Last updated: 2026-07-04
Last commit: 0e8b8c5 chore(serena): allow durable project memories to be tracked
Scope: README.md, .gitignore, .serena/project.yml, .serena/memories/**
Area: CORE
-->

# CORE-01-INDEX

## Purpose

Index durable Serena knowledge for the `rldyour-new-mac-or-ubuntu` module.

## Source Of Truth

- `README.md`: public module overview, baseline table, install/update commands, CI lanes, release/rollback and support surfaces.
- `AGENTS.md`: Codex-facing project rules and source-of-truth paths.
- `.claude/CLAUDE.md`: Claude Code-facing project memory for this module.
- `.serena/project.yml`: Serena project activation metadata for this bash-focused module.
- `.serena/memories/**`: tracked durable Serena knowledge.
- `.gitignore`: keeps Serena runtime files ignored while allowing durable project/memory files.

## Entry Points

- `CORE-01-INDEX.md`: start here to choose the relevant memory.
- `RELEASE-01-VALIDATION.md`: release, CI, validation, baseline, and public README contract.
- `TECHDEBT-01-NOW.md`: current operational watchpoints and no-secret/no-runtime-artifact boundaries.

## Current Behavior

This module had no pre-existing Serena memory set before commit `9addbd7`; commit `0e8b8c5` made `.serena/project.yml` and `.serena/memories/**` trackable so the sync pass can commit the module's first memory index and topic memories.

## Contracts And Data

Memory files use the `AREA-01-SLUG.md` naming form and the standard metadata block with `Last updated`, `Last commit`, `Scope`, and `Area`.

## Invariants

- `.serena/project.yml` and `.serena/memories/**` are durable project context and should remain trackable.
- Runtime-local Serena files such as `.serena/cache/`, `.serena/project.local.yml`, `.serena/.sync_marker`, and `.serena/.serena_sync_state.json` must remain untracked.

## Change Rules

- Add a new numbered memory only for durable facts that improve future implementation confidence.
- Update this index whenever a memory file is added, renamed, split, or removed.

## Verification

- `git ls-files .serena`: proves which durable Serena files are tracked.
- `python3 /Users/rldyourmnd/.codex/plugins/cache/rldyour-codex/rldyour-serena-mcp/local/scripts/serena_memory_state.py`: reports whether memory state acknowledges the current HEAD.
