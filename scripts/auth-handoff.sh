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
  # shellcheck disable=SC2016 # backticks are user-facing Markdown, not expansion
  printf '\nThe codex and zcode harnesses are owned by their GDS modules; launch `codex` and `zcode` to confirm sign-in without exposing account data.\n'
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

2. Codex CLI / OpenAI (harness owned by the nddev-codex-app GDS module)
   Desktop: codex login
   Headless server: codex login --device-auth
   Status: codex login status
   API keys, only when intentionally used: https://platform.openai.com/api-keys

3. ZCode CLI (harness owned by the nddev-zcode-app GDS module)
   Run: zcode
   Z.ai account OAuth is the default provider; sign in on first launch.
   Install and setup guide: https://zcode.z.ai/en/docs/install

4. Desktop applications (GUI profiles only)
   ChatGPT: open ChatGPT.app and sign in with the intended ChatGPT account.
   Codex app (macOS): open Codex.app and sign in with the intended ChatGPT account.
   Codex app guide: https://openai.com/index/introducing-the-codex-app/

5. Browser automation
   No browser provider login is required. Verify the mandatory local boundary:
   cloakbrowser-cdp-health
   bash scripts/verify-browser-runtime.sh
   Browser agents must use http://127.0.0.1:9222 through the managed Playwright
   CLI or Chrome DevTools MCP wrappers. Webwright is retired fail-closed;
   embedded or stock browsers are not an allowed fallback.

6. cmux (macOS GUI profile)
   After all CLIs are on PATH, if bootstrap could not configure cmux:
     cmux hooks codex install --yes

Run `bash scripts/auth-handoff.sh check` for non-secret CLI status probes.
EOF
