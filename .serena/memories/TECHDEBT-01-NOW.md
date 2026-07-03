<!-- Memory Metadata
Last updated: 2026-07-04
Last commit: 0e8b8c5 chore(serena): allow durable project memories to be tracked
Scope: .gitignore, .serena/project.yml, README.md, AGENTS.md, .claude/CLAUDE.md
Area: TECHDEBT
-->

# TECHDEBT-01-NOW

## Purpose

Record current operational watchpoints that future changes must preserve.

## Source Of Truth

- `.gitignore`: durable Serena paths and runtime-local ignore boundaries.
- `.serena/project.yml`: Serena project configuration for the module.
- `README.md`: public module scope and repository-context contract.
- `AGENTS.md`: Codex-facing source-of-truth and workflow rules.
- `.claude/CLAUDE.md`: Claude Code-facing module memory.

## Entry Points

- `git status --short --branch`: inspect whether durable context or runtime markers are dirty.
- `git check-ignore -v .serena/.sync_marker`: confirm runtime marker files are ignored.
- `git check-ignore -q .serena/memories/CORE-01-INDEX.md`: should return non-zero for durable memory files.

## Current Behavior

The module intentionally keeps bootstrap automation separate from browser/design/devtools runtime routing. README states browser/design/devtools workflows are provided by other super-repo modules.

The module uses tracked instruction docs (`AGENTS.md`, `.claude/CLAUDE.md`) and now allows tracked Serena memory files. Runtime Serena markers and local state remain ignored.

## Contracts And Data

- `.serena/project.yml` is durable activation metadata and should be trackable.
- `.serena/memories/**` is durable fact-only project knowledge and should be trackable.
- `.serena/cache/`, `.serena/project.local.yml`, `.serena/.sync_marker`, `.serena/.serena_sync_state.json`, and other runtime-local marker/state files are not source artifacts.

## Invariants

- Do not commit runtime markers, local project files, caches, browser artifacts, credentials, or diagnostic residue.
- Do not let `.gitignore` hide durable Serena memories from git.
- Keep README, AGENTS, and CLAUDE docs aligned with actual scripts and workflow names.

## Change Rules

- If `.gitignore` changes, verify durable Serena files are addable and runtime marker files remain ignored.
- If README changes only documentation, sync memories only for durable contract changes, not for formatting-only churn.

## Verification

- `git ls-files .serena`: durable Serena files should appear after sync commits.
- `git status --short --branch`: should be clean after sync/commit.
- `python3 /Users/rldyourmnd/.codex/plugins/cache/rldyour-codex/rldyour-serena-mcp/local/scripts/serena_memory_state.py`: should report current memory sync state.
