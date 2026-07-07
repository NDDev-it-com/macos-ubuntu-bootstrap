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

CLAUDE_CODE_VERSION="2.1.202"
CODEX_VERSION="0.142.5"
OPENCODE_VERSION="1.17.14"
MIMOCODE_VERSION="0.1.4"
ANTIGRAVITY_INSTALL_SCRIPT="https://antigravity.google/cli/install.sh"
MARKSMAN_VERSION="${MARKSMAN_VERSION:-2026-02-08}"
MARKSMAN_REPOSITORY="${MARKSMAN_REPOSITORY:-artempyanykh/marksman}"

# The `pyright` package ships both `pyright` and `pyright-langserver` console
# scripts; there is no separate `pyright-langserver` distribution to install.
PYTHON_TOOLING_PACKAGES=(
  pyright
  ruff
  pytest
)

# taplo ships as the npm `@taplo/cli` package (bare `taplo` is unpublished);
# marksman is not on npm and is installed from its pinned GitHub release below.
# vtsls replaces typescript-language-server as the recommended TS/JS LSP.
BUN_LSP_PACKAGES=(
  typescript
  "@vtsls/language-server"
  yaml-language-server
  bash-language-server
  dockerfile-language-server-nodejs
  vscode-langservers-extracted
  "@taplo/cli"
  gh-actions-language-server
)

# Bun-global quality-gate and formatter CLIs that are not well packaged via apt.
# These extend the LSP/runtime baseline with multi-language linting and SAST.
BUN_QUALITY_PACKAGES=(
  biome
  oxlint
  markdownlint-cli2
  prettier
  "@ansible/language-server"
)

APT_SYSTEM_PACKAGES=(
  ca-certificates
  build-essential
  curl
  gpg
  git
  jq
  python3
  python3-pip
  shellcheck
  shfmt
  clang
  clangd
  cmake
  golang-go
  unzip
  wget
  zip
  gnupg
  lsb-release
  yamllint
  pandoc
  fd-find
  bat
  xmlstarlet
  libxml2-utils
  # terminal layer (0.2.3): apt-available subset
  fzf
  zoxide
  tmux
  btop
  duf
  hexyl
  gh
)

APT_GOPLS_PACKAGE="gopls"

usage() {
  cat <<'EOF'
Usage: scripts/ubuntu/install.sh

Entrypoint for Ubuntu/server profile. This script is usually executed via
scripts/bootstrap.sh. It defaults to dry-run mode and supports strict checks
and skip flags.
EOF
}

apt_with_retries() {
  local -a cmd=(sudo -E DEBIAN_FRONTEND=noninteractive apt-get "$@")
  rldyour::run "${cmd[@]}"
}

ensure_apt_repo_updates() {
  rldyour::run sudo apt-get update
}

ensure_apt_packages() {
  rldyour::section "Install baseline apt packages"
  apt_with_retries install -y "${APT_SYSTEM_PACKAGES[@]}"
}

# `eza` is in Debian 13 / Ubuntu 24.10+ archives but not in older LTS ones;
# treat it as best-effort so the baseline never fails on supported LTS hosts.
ensure_eza() {
  rldyour::section "Ensure eza (best-effort on older LTS)"
  if command -v eza >/dev/null 2>&1; then
    rldyour::log "ok" "eza already installed"
    return 0
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] apt-get install -y eza"
    return 0
  fi
  if sudo -E DEBIAN_FRONTEND=noninteractive apt-get install -y eza; then
    rldyour::log "ok" "eza installed via apt"
  else
    rldyour::log "warn" "eza not available in this apt archive; skipping (best-effort)"
  fi
}


# Terminal layer (0.2.3): official installers for tools without reliable
# apt packages on supported LTS; every step is dry-run aware and idempotent.
ensure_starship() {
  rldyour::section "Ensure starship prompt"
  if command -v starship >/dev/null 2>&1; then
    rldyour::log "ok" "starship already installed"
    return 0
  fi
  rldyour::run bash -c "curl -sS https://starship.rs/install.sh | sh -s -- -y"
}

ensure_atuin() {
  rldyour::section "Ensure atuin history"
  if command -v atuin >/dev/null 2>&1; then
    rldyour::log "ok" "atuin already installed"
    return 0
  fi
  rldyour::run bash -c "curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh"
}

ensure_xh() {
  rldyour::section "Ensure xh HTTP client"
  if command -v xh >/dev/null 2>&1; then
    rldyour::log "ok" "xh already installed"
    return 0
  fi
  rldyour::run bash -c "curl -sfL https://raw.githubusercontent.com/ducaale/xh/master/install.sh | sh"
}

ensure_antidote_clone() {
  rldyour::section "Ensure antidote plugin manager (git clone)"
  if [ -d "$HOME/.antidote" ]; then
    rldyour::log "ok" "antidote already cloned"
    return 0
  fi
  rldyour::run git clone --depth=1 https://github.com/mattmc3/antidote.git "$HOME/.antidote"
}

ensure_node() {
  rldyour::section "Ensure Node.js (>=22)"
  if command -v node >/dev/null 2>&1; then
    if rldyour::require_cmd_min_version node 22 "--version"; then
      rldyour::log "ok" "node already available: $(node --version)"
      return 0
    fi
  fi
  rldyour::run bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
  rldyour::run sudo apt-get install -y nodejs
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
    rldyour::run rustup component add rust-src rust-analyzer
  fi
}

ensure_dart() {
  rldyour::section "Install Dart (SDK)"
  if command -v dart >/dev/null 2>&1; then
    rldyour::log "ok" "dart already installed"
    return 0
  fi

  rldyour::run bash -c "sudo mkdir -p /usr/share/keyrings"
  rldyour::run bash -c "curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor | sudo tee /usr/share/keyrings/dart-archive-keyring.gpg > /dev/null"
  rldyour::run bash -c "echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/dart-archive-keyring.gpg] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main\" | sudo tee /etc/apt/sources.list.d/dart_stable.list"
  rldyour::run sudo apt-get update
  rldyour::run sudo apt-get install -y dart
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

install_python_tooling() {
  rldyour::section "Install Python tooling"
  if ! command -v uv >/dev/null 2>&1; then
    if [ "$STRICT" -eq 1 ]; then
      rldyour::log "error" "uv is required for Python tooling"
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

install_go_lsp() {
  rldyour::section "Install Go language server"
  if command -v gopls >/dev/null 2>&1; then
    rldyour::log "ok" "gopls already available"
    return 0
  fi
  rldyour::run sudo apt-get install -y "$APT_GOPLS_PACKAGE"
}

# Install the extended Homebrew/Go/R-packaged LSPs that mirror the macOS
# baseline: Supabase postgres-language-server, sqls (multi-DB), and the R
# languageserver. Each is best-effort on Ubuntu because the runtime may not yet
# be present when this runs in plan mode.
ensure_extended_lsps() {
  rldyour::section "Install extended SQL / R LSPs (best-effort)"

  if command -v sqls >/dev/null 2>&1; then
    rldyour::log "ok" "sqls already installed"
  elif command -v go >/dev/null 2>&1; then
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] go install github.com/sqls-server/sqls@latest"
    else
      rldyour::run go install github.com/sqls-server/sqls@latest
    fi
  else
    rldyour::log "warn" "go required for sqls; skipping"
  fi

  if command -v R >/dev/null 2>&1; then
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] R install.packages('languageserver')"
    elif R -q -e 'library(languageserver)' >/dev/null 2>&1; then
      rldyour::log "ok" "R languageserver already installed"
    else
      rldyour::run R -e 'ncpus <- parallel::detectCores(); ncpus <- if (is.na(ncpus) || ncpus < 1) 1 else ncpus; install.packages("languageserver", repos="https://cloud.r-project.org", Ncpus=ncpus)'
    fi
  else
    rldyour::log "warn" "R runtime required for languageserver; skipping"
  fi
}

# Install bun-global quality-gate CLIs that are not packaged via apt on Ubuntu.
install_quality_packages() {
  rldyour::section "Install bun-global quality CLIs"
  if ! command -v bun >/dev/null 2>&1; then
    rldyour::log "warn" "bun required for quality CLIs; skipping"
    return 0
  fi
  for pkg in "${BUN_QUALITY_PACKAGES[@]}"; do
    rldyour::run bun add -g "$pkg"
  done
}

# Install the SAST/secret/dependency scanners that verify.sh requires but apt
# does not ship. Each scanner is installed via the channel its upstream publishes
# (uv tool, pipx, go install, or the official install script). All best-effort:
# a missing channel only logs a warning and does not abort the bootstrap.
install_security_scanners() {
  rldyour::section "Install security/quality scanners (verify.sh required)"

  # basedpyright ships as a Python wheel; uv tool gives an isolated install.
  if command -v basedpyright >/dev/null 2>&1; then
    rldyour::log "ok" "basedpyright already on PATH"
  elif command -v uv >/dev/null 2>&1; then
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] uv tool install basedpyright"
    else
      rldyour::run uv tool install basedpyright
    fi
  else
    rldyour::log "warn" "uv required for basedpyright; skipping"
  fi

  # osv-scanner ships a binary install script from Google.
  if command -v osv-scanner >/dev/null 2>&1; then
    rldyour::log "ok" "osv-scanner already on PATH"
  else
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] osv-scanner install script"
    else
      mkdir -p "$HOME/.local/bin"
      rldyour::run bash -c "curl -sSfL https://raw.githubusercontent.com/google/osv-scanner/main/install.sh | bash -s -- -b $HOME/.local/bin"
    fi
  fi

  # gitleaks ships a binary install script from GitHub.
  if command -v gitleaks >/dev/null 2>&1; then
    rldyour::log "ok" "gitleaks already on PATH"
  else
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] gitleaks install script"
    else
      mkdir -p "$HOME/.local/bin"
      rldyour::run bash -c "curl -sSfL https://raw.githubusercontent.com/gitleaks/gitleaks/master/install.sh | bash -s -- -b $HOME/.local/bin"
    fi
  fi

  # semgrep ships as a Python wheel.
  if command -v semgrep >/dev/null 2>&1; then
    rldyour::log "ok" "semgrep already on PATH"
  elif command -v pip3 >/dev/null 2>&1; then
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] pip3 install --user semgrep"
    else
      rldyour::run pip3 install --user semgrep
    fi
  else
    rldyour::log "warn" "pip3 required for semgrep; skipping"
  fi

  # hadolint ships a static binary on GitHub.
  if command -v hadolint >/dev/null 2>&1; then
    rldyour::log "ok" "hadolint already on PATH"
  else
    local arch asset
    case "$(uname -m)" in
      x86_64 | amd64) arch="x86_64" ;;
      aarch64 | arm64) arch="arm64" ;;
      *)
        rldyour::log "warn" "unsupported arch for hadolint; skipping"
        arch=""
        ;;
    esac
    if [ -n "$arch" ]; then
      if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
        rldyour::log "info" "[DRY-RUN] hadolint binary -> ~/.local/bin"
      else
        asset="hadolint-Linux-${arch}"
        mkdir -p "$HOME/.local/bin"
        if curl -fsSL "https://github.com/hadolint/hadolint/releases/latest/download/${asset}" -o "$HOME/.local/bin/hadolint"; then
          chmod +x "$HOME/.local/bin/hadolint"
          rldyour::log "ok" "hadolint installed -> ~/.local/bin/hadolint"
        else
          rldyour::log "warn" "hadolint download failed (best-effort)"
        fi
      fi
    fi
  fi

  # actionlint ships a binary install script from rhysd.
  if command -v actionlint >/dev/null 2>&1; then
    rldyour::log "ok" "actionlint already on PATH"
  else
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] actionlint install script"
    else
      mkdir -p "$HOME/.local/bin"
      rldyour::run bash -c "curl -sSfL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash | bash -s -- -o $HOME/.local/bin/actionlint"
    fi
  fi
}

# Install the JDK and R runtime baselines required by jdtls/Kotlin LSP and the R
# language server respectively. Ubuntu has good apt coverage for both.
ensure_java_and_r() {
  rldyour::section "Ensure JDK and R runtimes"
  if command -v java >/dev/null 2>&1; then
    rldyour::log "ok" "java already available: $(java -version 2>&1 | head -n 1)"
  else
    rldyour::run sudo apt-get install -y default-jdk
  fi
  if command -v R >/dev/null 2>&1; then
    rldyour::log "ok" "R already available: $(R --version 2>&1 | head -n 1)"
  else
    rldyour::run sudo apt-get install -y r-base
  fi
}

# Install cargo-hosted LSPs that have no apt/bun equivalent. gitlab-ci-ls is a
# static Rust binary distributed via crates.io. Supabase postgres-language-server
# is intentionally NOT installed here: on Ubuntu there is no apt/crate channel,
# and verify.sh treats it as optional on this platform.
ensure_cargo_lsps() {
  rldyour::section "Install cargo-hosted LSPs (best-effort)"
  if ! command -v cargo >/dev/null 2>&1; then
    rldyour::log "warn" "cargo required for cargo-hosted LSPs; skipping"
    return 0
  fi
  if command -v gitlab-ci-ls >/dev/null 2>&1; then
    rldyour::log "ok" "gitlab-ci-ls already installed"
  else
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] cargo install gitlab-ci-ls"
    else
      rldyour::run cargo install gitlab-ci-ls
    fi
  fi
}

ensure_marksman() {
  rldyour::section "Install marksman markdown LSP (pinned GitHub release)"
  if command -v marksman >/dev/null 2>&1; then
    rldyour::log "ok" "marksman already available"
    return 0
  fi
  local arch asset dest
  case "$(uname -m)" in
    x86_64 | amd64) arch="x64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      rldyour::log "warn" "unknown arch $(uname -m); skipping marksman"
      return 0
      ;;
  esac
  asset="marksman-linux-${arch}"
  dest="$HOME/.local/bin/marksman"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] download ${MARKSMAN_REPOSITORY}@${MARKSMAN_VERSION} ${asset} -> ${dest}"
    return 0
  fi
  mkdir -p "$HOME/.local/bin"
  if curl -fsSL "https://github.com/${MARKSMAN_REPOSITORY}/releases/download/${MARKSMAN_VERSION}/${asset}" -o "$dest"; then
    chmod +x "$dest"
    rldyour::log "ok" "marksman ${MARKSMAN_VERSION} installed -> ${dest}"
  elif [ "$STRICT" -eq 1 ]; then
    rldyour::log "error" "marksman download failed"
    exit 1
  else
    rldyour::log "warn" "marksman install skipped (best-effort)"
  fi
}

install_lsp() {
  rldyour::section "Install LSP set"
  if ! command -v bun >/dev/null 2>&1; then
    if [ "$STRICT" -eq 1 ]; then
      rldyour::log "error" "bun required for language-server bootstrap"
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

rldyour::section "rldyour-new-mac-or-ubuntu (Ubuntu) installer"
rldyour::log "info" "mode: $([ "$RLDYOUR_DRY_RUN" -eq 1 ] && echo dry-run || echo apply)"

if [ "$SKIP_SYSTEM" -eq 0 ]; then
  ensure_apt_repo_updates
  apt_with_retries install -y software-properties-common
  apt_with_retries install -y ca-certificates
  ensure_apt_packages
  ensure_eza
  ensure_starship
  ensure_atuin
  ensure_xh
  ensure_antidote_clone
  rldyour::ensure_git_perf
  rldyour::ensure_git_delta_config
  rldyour::install_terminal_configs "$REPO_ROOT/templates/terminal"
  ensure_node
  ensure_uv
  ensure_bun
  rldyour::ensure_path
  install_python_tooling
  ensure_rust
  ensure_dart
  install_go_lsp
  ensure_marksman
  ensure_java_and_r
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
  install_quality_packages
  install_security_scanners
  ensure_extended_lsps
  ensure_cargo_lsps
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
