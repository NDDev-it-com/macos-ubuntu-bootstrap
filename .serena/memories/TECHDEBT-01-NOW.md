<!-- Memory Metadata
Last updated: 2026-07-07
Last verified: 2026-07-07
Last commit: a0e3eb4 feat: 0.2.3 terminal layer for macOS/Ubuntu + release checksum fix (#8)
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
- Terminal-layer boundaries (0.2.3): managed dotfile templates are never-clobber (a user-modified `~/.zshrc`/`~/.zshenv` is kept with a warning, not overwritten); the zshrc template neutralizes interactive features for AI agents before anything else; Ghostty is macOS-only; the Ubuntu terminal layer is a documented apt/installer subset, not full brew parity.
- No current bootstrap contract-version drift: `VERSION`, `config/rldyour-contract.json`, README baseline, installer pins, docs (`README.md`, `AGENTS.md`, `.claude/CLAUDE.md`, `docs/install.md`), and SECURITY current exact tag stay synchronized. `tests/test_bootstrap_smoke.py` now guards installer-pin/doc parity; future releases must keep these surfaces aligned before root runtime-baseline validation.

## Evidence
- path:.gitignore
- path:.serena/project.yml
- path:README.md
- path:AGENTS.md
- path:.claude/CLAUDE.md
- path:scripts/macos/install.sh
- path:scripts/ubuntu/install.sh
- commit:a0e3eb4

## Do Not Infer
- Do not infer full workstation installation success from plan-mode scripts; strict verification and optional runtime checks must run on the target machine.

## Update Triggers
- Update when ignore rules, instruction docs, Serena paths, installer layers, or bootstrap-only boundaries change.

## Validation Commands
- `git check-ignore -v .serena/.sync_marker`
- `git check-ignore -q .serena/memories/CORE-01-INDEX.md`
- `bash scripts/ci/validate.sh`
- `python3 ../../scripts/validate_serena_memory_schema.py --scope new-mac-or-ubuntu --strict-mode strict-all`

## Repair Procedure
- Restore durable memory tracking, keep runtime state ignored, align docs with scripts, then rerun validation commands.

## Update policy
Keep this memory focused on current operational boundaries and verified technical debt only.
