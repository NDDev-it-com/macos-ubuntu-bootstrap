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
SKIP_CHECKS="${RLDYOUR_SKIP_CHECKS:-0}"
GUI_ENABLED="${RLDYOUR_GUI_ENABLED:-1}"
LOCAL_EXECUTION_POLICY="${RLDYOUR_LOCAL_EXECUTION_POLICY:-source-lsp-only}"

CLAUDE_CODE_VERSION="2.1.206"
CODEX_VERSION="0.144.1"
OPENCODE_VERSION="1.17.18"
MIMOCODE_VERSION="0.1.5"
ANTIGRAVITY_VERSION="1.1.1"
ANTIGRAVITY_ARTIFACT_URL="https://storage.googleapis.com/antigravity-public/antigravity-cli/1.1.1-6269367663591424/darwin-arm/cli_mac_arm64.tar.gz"
ANTIGRAVITY_ARTIFACT_SHA512="2993c4b43d2703cf796848e1a02b71e2e0588387d8dc2424435207eedbbc2097251ca0ba321b99d364358f7e6e98df1ac1757c1f5edaca8d53abaa26123e7f49"
HOMEBREW_PKG_VERSION="6.0.9"
HOMEBREW_PKG_SHA256="525599bd2dcbda29857120234336b0103ad5283a3dc8511f72066eeb917abd3c"
HOMEBREW_INSTALLER_TEAM="927JGANW46"

# Source/LSP-only workstation baseline. No Docker, project build orchestration,
# test runner, or local project runtime. Homebrew's LLVM distribution is present
# only because it is the supported clangd provider; this policy never invokes
# its compiler/linker for project builds.
BREW_SOURCE_PACKAGES=(
  git curl ca-certificates node bun uv python
  shellcheck shfmt llvm gopls docker-language-server
  vscode-langservers-extracted taplo marksman markdown-oxide
  terraform-ls helm-ls cmake-language-server
  pyright basedpyright ruff ty jdtls kotlin-language-server
  oxlint biome osv-scanner gitleaks semgrep hadolint actionlint
  yamllint markdownlint-cli2 prettier
  ripgrep fd eza bat git-delta jq yq ast-grep
  starship atuin fzf zoxide carapace antidote zsh-completions
  gh lazygit yazi xh jaq jnv duckdb difftastic tmux
)

BUN_LSP_PACKAGES=(
  typescript
  "@vtsls/language-server"
  yaml-language-server
  bash-language-server
  dockerfile-language-server-nodejs
  gh-actions-language-server
)

GUI_CASKS=(ghostty cmux chatgpt codex-app claude)

usage() {
  cat <<'EOF'
Usage: scripts/macos/install.sh

Internal macOS Apple Silicon installer. Use scripts/bootstrap.sh so profile,
GUI, safety, and verification settings are composed consistently.
EOF
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    rldyour::log "ok" "Homebrew already installed"
    return 0
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] download notarized Homebrew ${HOMEBREW_PKG_VERSION} package, verify tracked SHA-256 and Apple installer signature, then install"
    return 0
  fi
  local installer signature
  installer="$(mktemp -d)/Homebrew.pkg"
  trap 'rm -rf "$(dirname "$installer")"' RETURN
  rldyour::download_verified_file \
    "https://github.com/Homebrew/brew/releases/download/${HOMEBREW_PKG_VERSION}/Homebrew.pkg" \
    "$HOMEBREW_PKG_SHA256" "$installer"
  signature="$(/usr/sbin/pkgutil --check-signature "$installer" 2>&1)" || {
    rldyour::log "error" "Homebrew installer signature validation failed"
    return 1
  }
  printf '%s\n' "$signature" | grep -Fq "$HOMEBREW_INSTALLER_TEAM" || {
    rldyour::log "error" "Homebrew installer signer team mismatch"
    return 1
  }
  /usr/sbin/spctl --assess --type install --verbose=2 "$installer" >/dev/null 2>&1 || {
    rldyour::log "error" "Homebrew package failed Gatekeeper/notarization assessment"
    return 1
  }
  sudo /usr/sbin/installer -pkg "$installer" -target /
  rm -rf "$(dirname "$installer")"
  trap - RETURN
}

ensure_formula() {
  local formula="$1"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ] && ! command -v brew >/dev/null 2>&1; then
    rldyour::log "info" "[DRY-RUN] brew install ${formula}"
    return 0
  fi
  if brew list --formula "$formula" >/dev/null 2>&1; then
    rldyour::log "ok" "preserving installed Homebrew formula: $formula"
  else
    rldyour::run brew install "$formula"
  fi
}

install_source_packages() {
  rldyour::section "Install source/LSP-only Homebrew baseline"
  local formula
  for formula in "${BREW_SOURCE_PACKAGES[@]}"; do
    ensure_formula "$formula"
  done
}

cask_app_path() {
  case "$1" in
    ghostty) printf '%s\n' "/Applications/Ghostty.app" ;;
    cmux) printf '%s\n' "/Applications/cmux.app" ;;
    chatgpt) printf '%s\n' "/Applications/ChatGPT.app" ;;
    codex-app) printf '%s\n' "/Applications/Codex.app" ;;
    claude) printf '%s\n' "/Applications/Claude.app" ;;
    *) return 1 ;;
  esac
}

verify_existing_cask_app() {
  local cask="$1"
  local app_path="$2"
  [ -d "$app_path" ] || {
    rldyour::log "error" "existing cask destination is not an app bundle: $app_path"
    return 1
  }
  /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || {
    rldyour::log "error" "existing unmanaged app failed code-signature verification: $app_path"
    return 1
  }
  /usr/sbin/spctl --assess --type execute "$app_path" >/dev/null 2>&1 || {
    rldyour::log "error" "existing unmanaged app failed Gatekeeper assessment: $app_path"
    return 1
  }
  rldyour::log "ok" "preserving signed and notarized unmanaged cask destination for $cask: $app_path"
}

ensure_cask() {
  local cask="$1"
  local app_path=""
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ] && ! command -v brew >/dev/null 2>&1; then
    rldyour::log "info" "[DRY-RUN] brew install --cask ${cask}"
    return 0
  fi
  if brew list --cask "$cask" >/dev/null 2>&1; then
    rldyour::log "ok" "preserving installed Homebrew cask: $cask"
    return 0
  fi
  app_path="$(cask_app_path "$cask" || true)"
  if [ -n "$app_path" ] && [ -e "$app_path" ]; then
    verify_existing_cask_app "$cask" "$app_path"
    return 0
  fi
  rldyour::run brew install --cask "$cask"
}

install_gui_apps() {
  if [ "$GUI_ENABLED" -ne 1 ]; then
    rldyour::log "info" "GUI apps disabled by --no-gui"
    return 0
  fi
  rldyour::section "Install verified macOS GUI applications"
  local cask
  for cask in "${GUI_CASKS[@]}"; do
    ensure_cask "$cask"
  done
  rldyour::log "info" "ChatGPT and Codex are installed as separate supported OpenAI desktop applications."
  rldyour::log "warn" "ZCode is not auto-installed because upstream publishes no checksum/signature manifest; see scripts/auth-handoff.sh."
}

install_ai_runtimes() {
  rldyour::section "Install exact AI CLI versions"
  rldyour::install_ai_cli_bundle \
    "$CLAUDE_CODE_VERSION" "$CODEX_VERSION" \
    "$OPENCODE_VERSION" "$MIMOCODE_VERSION"

  rldyour::install_antigravity_artifact \
    "$ANTIGRAVITY_VERSION" \
    "$ANTIGRAVITY_ARTIFACT_URL" \
    "$ANTIGRAVITY_ARTIFACT_SHA512"
}

install_bun_lsps() {
  rldyour::section "Install registry-backed language servers"
  local package
  for package in "${BUN_LSP_PACKAGES[@]}"; do
    if bun pm ls -g 2>/dev/null | grep -Fq "${package}@"; then
      rldyour::log "ok" "preserving installed Bun source tool: ${package}"
    else
      rldyour::run bun add -g --ignore-scripts "$package"
    fi
  done
}

configure_cmux_hooks() {
  [ "$GUI_ENABLED" -eq 1 ] || return 0
  if command -v cmux >/dev/null 2>&1; then
    # Keep bootstrap non-interactive and scoped to owner-standard agents. The
    # generic setup command prompts for every detected integration and can
    # create unrelated configuration on an otherwise clean host.
    local agent
    for agent in codex opencode antigravity; do
      rldyour::run cmux hooks "$agent" install --yes
    done
  else
    rldyour::log "info" "cmux hooks will be configured after cmux first appears on PATH"
  fi
}

verify_apply() {
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "plan complete; verification runs only after apply"
  elif [ "$SKIP_CHECKS" -eq 0 ]; then
    RLDYOUR_GUI_ENABLED="$GUI_ENABLED" RLDYOUR_BROWSER_REQUIRED=1 \
      bash "$SCRIPT_DIR/verify.sh" --strict
  fi
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

rldyour::assert_root "$REPO_ROOT"
rldyour::ensure_path
[ "$LOCAL_EXECUTION_POLICY" = "source-lsp-only" ] || {
  rldyour::log "error" "macOS must use source-lsp-only policy"
  exit 2
}
if [ "$RLDYOUR_DRY_RUN" -eq 0 ]; then
  if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    rldyour::log "error" "supported macOS apply target is Apple Silicon (arm64)"
    exit 2
  fi
fi

rldyour::section "macos-ubuntu-bootstrap (macOS) installer"
rldyour::log "info" "mode: $([ "$RLDYOUR_DRY_RUN" -eq 1 ] && echo dry-run || echo apply); gui: $GUI_ENABLED; policy: $LOCAL_EXECUTION_POLICY"

if [ "$SKIP_SYSTEM" -eq 0 ]; then
  ensure_homebrew
  rldyour::ensure_path
  if command -v brew >/dev/null 2>&1 || [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    install_source_packages
    install_gui_apps
  elif [ "$STRICT" -eq 1 ]; then
    rldyour::log "error" "Homebrew unavailable after installation"
    exit 1
  fi
  rldyour::ensure_git_perf
  rldyour::ensure_git_delta_config
  rldyour::install_terminal_configs "$REPO_ROOT/templates/terminal"
else
  rldyour::log "warn" "system layer skipped by explicit recovery flag"
fi

[ "$SKIP_AI" -eq 1 ] || install_ai_runtimes
[ "$SKIP_LSPS" -eq 1 ] || install_bun_lsps

# Mandatory on GUI and no-GUI profiles. No skip/fallback path exists.
rldyour::install_browser_providers
rldyour::install_rtk
configure_cmux_hooks
verify_apply
rldyour::log "info" "Run 'bash scripts/auth-handoff.sh' for user-controlled sign-in steps."
