#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

RLDYOUR_DRY_RUN="${RLDYOUR_DRY_RUN:-1}"
STRICT="${RLDYOUR_STRICT:-0}"
SKIP_SYSTEM="${RLDYOUR_SKIP_SYSTEM:-0}"
SKIP_AI="${RLDYOUR_SKIP_AI:-0}"
SKIP_LSPS="${RLDYOUR_SKIP_LSPS:-0}"
SKIP_BROWSER="${RLDYOUR_SKIP_BROWSER:-0}"
SKIP_CHECKS="${RLDYOUR_SKIP_CHECKS:-0}"

CLAUDE_CODE_VERSION="2.1.199"
CODEX_VERSION="0.142.5"
OPENCODE_VERSION="1.17.13"
MIMOCODE_VERSION="0.1.4"
ANTIGRAVITY_INSTALL_SCRIPT="https://antigravity.google/cli/install.sh"

PYTHON_TOOLING_PACKAGES=(
  pyright-langserver
  pyright
  ruff
  pytest
)

BUN_LSP_PACKAGES=(
  typescript
  typescript-language-server
  yaml-language-server
  bash-language-server
  dockerfile-language-server-nodejs
  vscode-langservers-extracted
  taplo
)

BREW_SYSTEM_PACKAGES=(
  git
  curl
  ca-certificates
  go
  gopls
  shellcheck
  llvm
  cmake
  docker-language-server
  vscode-langservers-extracted
  taplo
  marksman
)

usage() {
  cat <<'EOF'
Usage: scripts/macos/install.sh

Entrypoint for macOS profile. This script is usually executed via
scripts/bootstrap.sh. It defaults to dry-run mode and supports strict checks
and skip flags.
EOF
}

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then
    rldyour::log "ok" "Homebrew already installed"
    return 0
  fi

  rldyour::log "warn" "Homebrew not found"
  rldyour::run bash -c "/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
}

ensure_node() {
  rldyour::section "Ensure Node.js runtime (>=22)"
  if command -v node >/dev/null 2>&1; then
    if rldyour::require_cmd_min_version node 22 "--version"; then
      rldyour::log "ok" "node already satisfies minimum version: $(node --version)"
      return 0
    fi
    rldyour::log "warn" "node version does not meet minimum; reinstalling from Homebrew"
  fi

  rldyour::run brew install node
}

install_brew_packages() {
  rldyour::section "Install Homebrew packages"
  for package in "${BREW_SYSTEM_PACKAGES[@]}"; do
    if brew list --formula "$package" >/dev/null 2>&1; then
      rldyour::log "ok" "$package already installed"
    else
      rldyour::run brew install "$package"
    fi
  done
}

ensure_uv() {
  rldyour::section "Install uv toolchain"
  if command -v uv >/dev/null 2>&1; then
    rldyour::log "ok" "uv already installed: $(uv --version)"
    return 0
  fi
  rldyour::run bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
}

ensure_bun() {
  rldyour::section "Install bun runtime"
  if command -v bun >/dev/null 2>&1; then
    rldyour::log "ok" "bun already installed: $(bun --version)"
    return 0
  fi
  rldyour::run bash -c "curl -fsSL https://bun.sh/install | bash"
}

ensure_python3() {
  rldyour::section "Ensure Python 3"
  if command -v python3 >/dev/null 2>&1; then
    rldyour::log "ok" "python3 already available: $(python3 --version)"
    return 0
  fi
  rldyour::run brew install python@3.12
}

ensure_rust() {
  rldyour::section "Install Rust toolchain"
  if command -v rustup >/dev/null 2>&1; then
    rldyour::log "ok" "rustup already installed"
  else
    rldyour::run bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
  fi

  if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && [ -f "$HOME/.cargo/env" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 0 ]; then
    if command -v rustup >/dev/null 2>&1; then
      rldyour::run rustup component add rust-src rust-analyzer
    elif [ "$STRICT" -eq 1 ]; then
      rldyour::log "error" "rustup unavailable after bootstrap"
      exit 1
    fi
  fi
}

install_dart() {
  rldyour::section "Install Dart (SDK)"
  if command -v dart >/dev/null 2>&1; then
    rldyour::log "ok" "dart already installed"
    return 0
  fi

  rldyour::run brew tap dart-lang/dart
  rldyour::run brew install dart-lang/dart/dart
}

install_python_tooling() {
  rldyour::section "Install Python tooling"
  if ! command -v uv >/dev/null 2>&1; then
    if [ "$STRICT" -eq 1 ]; then
      rldyour::log "error" "uv required for Python tooling install"
      exit 1
    fi
    rldyour::log "warn" "skip Python tooling until uv is available"
    return 0
  fi

  for pkg in "${PYTHON_TOOLING_PACKAGES[@]}"; do
    if uv tool list | grep -q "^$pkg"; then
      rldyour::log "ok" "$pkg already managed by uv"
    else
      rldyour::run uv tool install --upgrade "$pkg"
    fi
  done
}

install_ai_runtimes() {
  rldyour::section "Install AI runtimes (pinned)"
  if ! command -v bun >/dev/null 2>&1; then
    if [ "$STRICT" -eq 1 ]; then
      rldyour::log "error" "bun is required for AI runtime install"
      exit 1
    fi
    rldyour::log "warn" "skip AI runtime install until bun is available"
    return 0
  fi

  if command -v claude-code >/dev/null 2>&1; then
    rldyour::log "ok" "claude-code already present"
  elif command -v claude >/dev/null 2>&1; then
    rldyour::log "ok" "claude already present (treated as claude-code-compatible entrypoint)"
  else
    rldyour::run bun add -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
  fi

  if ! command -v codex >/dev/null 2>&1; then
    rldyour::run bun add -g "@openai/codex@${CODEX_VERSION}"
  else
    rldyour::log "ok" "codex already present"
  fi

  if ! command -v opencode >/dev/null 2>&1; then
    rldyour::run bun add -g "opencode-ai@${OPENCODE_VERSION}"
  else
    rldyour::log "ok" "opencode already present"
  fi

  if ! command -v agy >/dev/null 2>&1; then
    rldyour::run bash -c "curl -fsSL ${ANTIGRAVITY_INSTALL_SCRIPT} | bash"
  else
    rldyour::log "ok" "antigravity agy already present"
  fi

  if ! command -v mimo >/dev/null 2>&1; then
    rldyour::run bun add -g "@mimo-ai/cli@${MIMOCODE_VERSION}"
  else
    rldyour::log "ok" "mimo already present"
  fi
}

install_lsp() {
  rldyour::section "Install LSP set"
  if ! command -v bun >/dev/null 2>&1; then
    if [ "$STRICT" -eq 1 ]; then
      rldyour::log "error" "bun required for LSP bootstrap"
      exit 1
    fi
    rldyour::log "warn" "skip LSP bootstrap without bun"
    return 0
  fi
  for pkg in "${BUN_LSP_PACKAGES[@]}"; do
    rldyour::run bun add -g "$pkg"
  done
}

run_post_checks() {
  rldyour::section "Post-checks"
  bash "$SCRIPT_DIR/verify.sh" --strict --skip-optional
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

rldyour::assert_root "$REPO_ROOT"
rldyour::ensure_path

rldyour::section "rldyour-new-mac-or-ubuntu (macOS) installer"
rldyour::log "info" "mode: $([ "$RLDYOUR_DRY_RUN" -eq 1 ] && echo dry-run || echo apply)"

if [ "$SKIP_SYSTEM" -eq 0 ]; then
  ensure_brew
  rldyour::ensure_path
  if command -v brew >/dev/null 2>&1; then
    install_brew_packages
  elif [ "$STRICT" -eq 1 ]; then
    rldyour::log "error" "Homebrew required for macOS system baseline"
    exit 1
  fi
  ensure_node

  ensure_bun
  ensure_uv
  ensure_python3
  install_python_tooling
  ensure_rust
  install_dart
else
  rldyour::log "warn" "system layer skipped by --skip-system"
fi

if [ "$SKIP_AI" -eq 0 ]; then
  install_ai_runtimes
else
  rldyour::log "warn" "AI runtimes skipped by --skip-ai"
fi

if [ "$SKIP_LSPS" -eq 0 ]; then
  install_lsp
else
  rldyour::log "warn" "LSP layer skipped by --skip-lsps"
fi

if [ "$SKIP_BROWSER" -eq 0 ]; then
  rldyour::install_browser_providers
else
  rldyour::log "warn" "browser tooling skipped by --skip-browser"
fi

if [ "$SKIP_CHECKS" -eq 0 ]; then
  run_post_checks
fi
