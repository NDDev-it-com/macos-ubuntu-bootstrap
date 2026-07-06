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

CLAUDE_CODE_VERSION="2.1.201"
CODEX_VERSION="0.142.5"
OPENCODE_VERSION="1.17.13"
MIMOCODE_VERSION="0.1.4"
ANTIGRAVITY_INSTALL_SCRIPT="https://antigravity.google/cli/install.sh"

# The `pyright` package ships both `pyright` and `pyright-langserver` console
# scripts; there is no separate `pyright-langserver` distribution to install.
# `ruff` is intentionally NOT listed here: it is installed via the Homebrew
# `ruff` formula (see BREW_SYSTEM_PACKAGES) so its LSP server (`ruff server`) is
# available system-wide and there is a single source of truth for the version.
PYTHON_TOOLING_PACKAGES=(
  pyright
  pytest
)

# taplo is provided by Homebrew (BREW_SYSTEM_PACKAGES); it is not published as a
# bare npm `taplo` package, so it must not be bun-installed here.
# vscode-langservers-extracted is also installed via Homebrew (single source of
# truth for the HTML/CSS/JSON servers), so it is not bun-installed here.
# vtsls replaces typescript-language-server as the recommended TS/JS LSP (better
# feature parity with the VS Code TS extension; chosen by Zed and LazyVim).
BUN_LSP_PACKAGES=(
  typescript
  "@vtsls/language-server"
  yaml-language-server
  bash-language-server
  dockerfile-language-server-nodejs
  gh-actions-language-server
)

# Homebrew baseline: runtimes, LSPs that ship as brew formulas, and the
# quality-gate / formatter CLIs used by the agent verification layer.
BREW_SYSTEM_PACKAGES=(
  git
  curl
  ca-certificates
  go
  gopls
  shellcheck
  shfmt
  llvm
  cmake
  qt
  openjdk
  docker-language-server
  vscode-langservers-extracted
  taplo
  marksman
  markdown-oxide
  terraform-ls
  helm-ls
  cmake-language-server
  basedpyright
  ruff
  ty
  jdtls
  kotlin-language-server
  oxlint
  biome
  osv-scanner
  gitleaks
  semgrep
  hadolint
  actionlint
  yamllint
  markdownlint-cli2
  fd
  eza
  bat
  httpie
  dasel
  miller
  git-delta
  watchexec
  hyperfine
  just
  jq
  prettier
  pandoc
  kubeconform
  mise
  libxml2
  xmlstarlet
  r
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

# Link the keg-only `openjdk` formula so `java`/`javac` resolve on PATH without
# requiring the user to run `brew link` manually. Required by jdtls and the
# Kotlin language server.
ensure_java() {
  rldyour::section "Link keg-only OpenJDK (for Java/Kotlin LSPs)"
  if command -v java >/dev/null 2>&1; then
    rldyour::log "ok" "java already on PATH: $(java -version 2>&1 | head -n 1)"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    rldyour::log "warn" "brew unavailable; cannot link openjdk"
    return 0
  fi
  if brew list --formula openjdk >/dev/null 2>&1; then
    rldyour::run brew link --force --overwrite openjdk
  else
    rldyour::log "warn" "openjdk not installed via brew; skipping link"
  fi
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

ensure_clangd() {
  rldyour::section "Ensure clangd on PATH (llvm is keg-only)"
  if command -v clangd >/dev/null 2>&1; then
    rldyour::log "ok" "clangd already on PATH"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    rldyour::log "warn" "brew unavailable; cannot resolve keg-only clangd"
    return 0
  fi
  local keg
  keg="$(brew --prefix llvm 2>/dev/null)/bin/clangd"
  if [ -x "$keg" ]; then
    if [ "$RLDYOUR_DRY_RUN" -eq 0 ]; then
      mkdir -p "$HOME/.local/bin"
    fi
    rldyour::run ln -sf "$keg" "$HOME/.local/bin/clangd"
    rldyour::log "ok" "linked keg-only clangd -> ~/.local/bin/clangd"
  elif [ "$STRICT" -eq 1 ]; then
    rldyour::log "error" "clangd not found under $(brew --prefix llvm 2>/dev/null); install llvm first"
    exit 1
  else
    rldyour::log "warn" "clangd not found under llvm keg; ensure llvm is installed"
  fi
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

# Supabase's postgres-language-server ships as a Homebrew formula; the
# `postgres-lsp` crate on crates.io is an unrelated project and must not be
# used as a substitute.
ensure_postgres_language_server() {
  rldyour::section "Ensure Supabase postgres-language-server"
  if command -v postgres-language-server >/dev/null 2>&1; then
    rldyour::log "ok" "postgres-language-server already installed"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    rldyour::log "warn" "brew unavailable; cannot install postgres-language-server"
    return 0
  fi
  rldyour::run brew install postgres-language-server
}

# sqls (multi-DB SQL LSP) is installed via `go install`. Requires the Go
# toolchain to be on PATH (ensured by the system layer).
ensure_sqls() {
  rldyour::section "Ensure sqls (multi-DB SQL LSP)"
  if command -v sqls >/dev/null 2>&1; then
    rldyour::log "ok" "sqls already installed"
    return 0
  fi
  if ! command -v go >/dev/null 2>&1; then
    rldyour::log "warn" "go toolchain required for sqls; skipping"
    return 0
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] go install github.com/sqls-server/sqls@latest"
    return 0
  fi
  if go install github.com/sqls-server/sqls@latest; then
    rldyour::log "ok" "sqls installed via go install"
  else
    rldyour::log "warn" "sqls install failed (best-effort)"
  fi
}

# R language server is an R package installed into the local R library; it
# requires the R runtime (provided by the `r` formula in BREW_SYSTEM_PACKAGES).
ensure_r_languageserver() {
  rldyour::section "Ensure R languageserver"
  if ! command -v R >/dev/null 2>&1; then
    rldyour::log "warn" "R runtime required for languageserver; skipping"
    return 0
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] R -e install.packages('languageserver')"
    return 0
  fi
  if R -q -e 'library(languageserver)' >/dev/null 2>&1; then
    rldyour::log "ok" "R languageserver already installed"
    return 0
  fi
  if R -e 'ncpus <- parallel::detectCores(); ncpus <- if (is.na(ncpus) || ncpus < 1) 1 else ncpus; install.packages("languageserver", repos="https://cloud.r-project.org", Ncpus=ncpus)'; then
    rldyour::log "ok" "R languageserver installed"
  else
    rldyour::log "warn" "R languageserver install failed (best-effort)"
  fi
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
  ensure_java

  ensure_bun
  ensure_uv
  ensure_python3
  install_python_tooling
  ensure_rust
  install_dart
  ensure_clangd
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
  ensure_postgres_language_server
  ensure_sqls
  ensure_r_languageserver
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
