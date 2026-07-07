<!-- Memory Metadata
Last updated: 2026-07-07
Last verified: 2026-07-07
Last commit: a0e3eb4 feat: 0.2.3 terminal layer for macOS/Ubuntu + release checksum fix (#8)
Scope: README.md, AGENTS.md, .claude/CLAUDE.md, .serena/project.yml, .serena/memories/**
Area: CORE
-->

# CORE-01-INDEX

## Scope
Durable Serena memory index for the `rldyour-new-mac-or-ubuntu` bootstrap module.

## Applies to
- `README.md`
- `AGENTS.md`
- `.claude/CLAUDE.md`
- `.serena/project.yml`
- `.serena/memories/**`

## Source of truth
- `README.md`: public module overview, dependency baseline, CI lanes, and release surfaces.
- `AGENTS.md`: Codex-facing module instructions.
- `.claude/CLAUDE.md`: Claude Code-facing module memory.
- `.serena/project.yml`: Serena activation metadata.
- `.serena/memories/**`: tracked durable memory files.

## Invariants
- `.serena/project.yml` and `.serena/memories/**` are source-tracked durable context.
- `.serena/cache/`, `.serena/project.local.yml`, runtime markers, diagnostics, and local state remain untracked.
- Memory names use the `AREA-01-SLUG.md` form.

## Current State
- This module has three tracked memories: `CORE-01-INDEX.md`, `RELEASE-01-VALIDATION.md`, and `TECHDEBT-01-NOW.md`.
- The module is a bootstrap adapter for macOS and Ubuntu dependency installation and verification, and since 0.2.3 it also owns the terminal layer (shell stack, TUI/CLI wave, and managed zsh/starship templates under `templates/terminal/`).
- The module does not own AI CLI runtime configuration surfaces; those remain in the sibling adapter modules.

## Evidence
- path:README.md
- path:AGENTS.md
- path:.claude/CLAUDE.md
- path:.serena/project.yml
- path:.serena/memories/RELEASE-01-VALIDATION.md
- path:.serena/memories/TECHDEBT-01-NOW.md
- commit:a0e3eb4

## Do Not Infer
- Do not infer current dependency versions, release state, GitHub settings, or CI status from this index; read the source files and live GitHub state.

## Update Triggers
- Update when memory files are added, renamed, split, deleted, or when module instruction/source-of-truth paths change.

## Validation Commands
- `python3 /Users/rldyourmnd/.codex/plugins/cache/rldyour-codex/rldyour-serena-mcp/local/scripts/serena_memory_state.py`
- `python3 ../../scripts/validate_serena_memory_schema.py --scope new-mac-or-ubuntu --strict-mode strict-all`
- `git ls-files .serena`

## Repair Procedure
- Re-read source-of-truth files, update only durable verified facts, keep runtime-local files ignored, then rerun the validation commands.

## Update policy
Keep this index synchronized with the memory file set and module instruction surfaces.
