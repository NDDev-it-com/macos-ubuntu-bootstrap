#!/usr/bin/env bash

set -euo pipefail

mode="${1:-show}"
if [ "$mode" = "--help" ] || [ "$mode" = "-h" ]; then
  cat <<'EOF'
Usage: scripts/auth-handoff.sh [show|check]

Prints the user-controlled sign-in steps left after bootstrap. It never reads,
prints, stores, or uploads credentials.
EOF
  exit 0
fi

if [ "$mode" = "check" ]; then
  failures=0
  check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      printf 'ok      %s\n' "$label"
    else
      printf 'pending %s\n' "$label"
      failures=$((failures + 1))
    fi
  }
  check "GitHub CLI" gh auth status
  check "Codex CLI" codex login status
  check "OpenCode CLI" opencode auth list
  if command -v claude >/dev/null 2>&1; then
    check "Claude Code" claude auth status
  else
    check "Claude Code" claude-code auth status
  fi
  # shellcheck disable=SC2016 # backticks are user-facing Markdown, not expansion
  printf '\nMiMoCode and Antigravity use interactive provider selection; launch `mimo` and `agy` to confirm them without exposing account data.\n'
  [ "$failures" -eq 0 ]
  exit
fi

[ "$mode" = "show" ] || { echo "unknown mode: $mode" >&2; exit 2; }

cat <<'EOF'
Authentication handoff (no credentials are managed by this repository)

1. GitHub CLI
   Run: gh auth login
   Then: gh auth status
   Repository secrets: GitHub repository → Settings → Secrets and variables → Actions
   Deployment approvals: GitHub repository → Settings → Environments
   Commit signing: GitHub account → Settings → SSH and GPG keys → New SSH key →
   Signing Key; register only the public key (for example ~/.ssh/id_ed25519.pub).

2. Codex CLI / OpenAI
   Desktop: codex login
   Headless server: codex login --device-auth
   Status: codex login status
   API keys, only when intentionally used: https://platform.openai.com/api-keys

3. Claude Code
   Run: claude auth login
   On SSH, press `c`, open the printed OAuth URL on a trusted desktop, then
   paste the returned code into the original terminal.

4. OpenCode
   Run: opencode auth login
   Inspect configured providers: opencode auth list
   Provider guide: https://opencode.ai/docs/providers

5. MiMoCode
   Run: mimo
   Select Xiaomi OAuth, anonymous MiMo Auto, Claude credential import, or an
   intentional OpenAI-compatible provider. No static headless OAuth URL is
   documented upstream.

6. Antigravity CLI
   Run: agy
   Select Google OAuth or a Google Cloud project. On SSH the CLI prints a URL
   and waits for the returned authorization code.

7. Desktop applications (GUI profiles only)
   ChatGPT/Codex: open ChatGPT.app and sign in with the intended ChatGPT account.
   Claude Desktop: open Claude.app / claude-desktop and sign in.
   ZCode: https://zcode.z.ai/en/docs/install
   ZCode is manual by default because upstream publishes no checksum manifest.

8. Browser automation
   No browser provider login is required. Verify the mandatory local boundary:
   cloakbrowser-cdp-health
   Browser agents must use http://127.0.0.1:9222 through the managed wrappers;
   embedded or stock browsers are not an allowed fallback.

9. cmux (macOS GUI profile)
   After all CLIs are on PATH: cmux hooks setup

Run `bash scripts/auth-handoff.sh check` for non-secret CLI status probes.
EOF
