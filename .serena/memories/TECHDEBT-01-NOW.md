<!-- Memory Metadata
Last updated: 2026-07-10
Last verified: 2026-07-10
Last commit: c7fc734 fix(ci): remove unsupported actionlint input
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
- Keep bootstrap runtime ownership separate from adapter-native browser task routing.
- Keep README, AGENTS, and CLAUDE docs aligned with actual scripts and workflow names.

## Current State
- Durable Serena memory files are tracked; runtime-local Serena state remains ignored.
- The module owns installation and verification, not adapter-native MCP, command, skill, or task-routing surfaces.
- Managed shell integration edits only delimited source blocks, backs up pre-existing files, and verifies a fresh login shell. Interactive aliases activate only when their target executable exists.
- ZCode remains an explicit integrity handoff because upstream publishes no checksum/signature manifest. Ubuntu can install it only with an independently supplied SHA-256.
- Full apply evidence still requires representative Apple Silicon macOS and Ubuntu 24.04/26.04 hosts with launchd/systemd, real user sessions, and the chosen Docker mode. Container-only CI does not prove SSH reachability, UFW behavior, desktop app launch, or Docker daemon health.
- No current bootstrap contract/version drift: `VERSION`, contract, scripts, frozen locks, docs, SECURITY, and tests agree on release 0.3.4 and its exact runtime pins.

## Evidence
- path:.gitignore
- path:.serena/project.yml
- path:README.md
- path:AGENTS.md
- path:.claude/CLAUDE.md
- path:scripts/macos/install.sh
- path:scripts/ubuntu/install.sh
- path:scripts/lib/common.sh
- path:scripts/ubuntu/server.sh
- path:tests/test_transactional_runtime.py
- path:tests/test_ubuntu_server_safety.py
- commit:911265b
- commit:0ec6ec6
- commit:ec5416b
- commit:03419cc
- commit:c7fc734

## Do Not Infer
- Do not infer full workstation installation success from plan-mode scripts; strict verification and optional runtime checks must run on the target machine.

## Update Triggers
- Update when ignore rules, instruction docs, Serena paths, installer layers, or bootstrap-only boundaries change.

## Validation Commands
- `git check-ignore -v .serena/.sync_marker`
- `git check-ignore -q .serena/memories/CORE-01-INDEX.md`
- `bash scripts/ci/validate.sh`
- `python3 -m pytest -q`
- `shellcheck scripts/lib/common.sh scripts/ubuntu/server.sh scripts/ubuntu/verify-server.sh`
- `python3 ../../scripts/validate_serena_memory_schema.py --scope new-mac-or-ubuntu --strict-mode strict-all`

## Repair Procedure
- Restore durable memory tracking, keep runtime state ignored, align docs with scripts, then rerun validation commands.

## Update policy
Keep this memory focused on current operational boundaries and verified technical debt only.
