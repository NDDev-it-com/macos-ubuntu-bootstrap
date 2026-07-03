<!-- Memory Metadata
Last updated: 2026-07-04
Last verified: 2026-07-04
Last commit: acea1f0babd9b5b75b6bf3d0d507ae9e3be9f9b1 chore(serena): sync project knowledge after 0e8b8c5
Scope: .gitignore, .serena/project.yml, README.md, AGENTS.md, .claude/CLAUDE.md, scripts/**
Area: TECHDEBT
-->

# TECHDEBT-01-NOW

## Scope
Operational watchpoints and boundaries for the bootstrap module.

## Applies to
- `.gitignore`
- `.serena/project.yml`
- `.serena/memories/**`
- `README.md`
- `AGENTS.md`
- `.claude/CLAUDE.md`
- `scripts/**`

## Source of truth
- `.gitignore`: durable context and runtime-local ignore boundaries.
- `.serena/project.yml`: Serena module activation metadata.
- `README.md`: public module scope and repository-context contract.
- `AGENTS.md` and `.claude/CLAUDE.md`: CLI-specific instruction surfaces.
- `scripts/**`: actual bootstrap and verification behavior.

## Invariants
- Do not commit runtime markers, caches, diagnostics, traces, local env files, browser artifacts, credentials, or generated junk.
- Do not hide durable Serena memory files behind `.gitignore`.
- Keep bootstrap automation separate from browser/design/devtools workflow routing.
- Keep README, AGENTS, and CLAUDE docs aligned with actual scripts and workflow names.

## Current State
- Durable Serena memory files are tracked; runtime-local Serena state remains ignored.
- The module is intentionally bootstrap-only and does not expose MCP, browser, design, or native `ry-*` command surfaces.
- Ubuntu and macOS installers both include `marksman` in the LSP layer.

## Evidence
- path:.gitignore
- path:.serena/project.yml
- path:README.md
- path:AGENTS.md
- path:.claude/CLAUDE.md
- path:scripts/macos/install.sh
- path:scripts/ubuntu/install.sh
- commit:acea1f0babd9b5b75b6bf3d0d507ae9e3be9f9b1

## Do Not Infer
- Do not infer full workstation installation success from plan-mode scripts; strict verification and optional runtime checks must run on the target machine.

## Update Triggers
- Update when ignore rules, instruction docs, Serena paths, installer layers, or bootstrap-only boundaries change.

## Validation Commands
- `git check-ignore -v .serena/.sync_marker`
- `git check-ignore -q .serena/memories/CORE-01-INDEX.md`
- `bash scripts/ci/validate.sh`
- `python3 ../../../scripts/validate_serena_memory_schema.py --scope new-mac-or-ubuntu --strict-mode strict-all`

## Repair Procedure
- Restore durable memory tracking, keep runtime state ignored, align docs with scripts, then rerun validation commands.

## Update policy
Keep this memory focused on current operational boundaries and verified technical debt only.
