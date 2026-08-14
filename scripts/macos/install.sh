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

HOMEBREW_PKG_VERSION="6.0.17"
HOMEBREW_PKG_SHA256="70079078573ca0acafbb487c2442f806706a54bf973fe8390da0bd3ac1536d04"
HOMEBREW_INSTALLER_TEAM="927JGANW46"
HERDR_VERSION="0.8.0"
HERDR_MACOS_AARCH64_SHA256="d53a9f93fccfdfcc55632927bf51002f5add0aa7990bcdf508ffbd84ac658178"
HERDR_MACOS_AARCH64_URL="https://github.com/herdrdev/herdr/releases/download/v0.8.0/herdr-macos-aarch64"

# Source/LSP-only workstation baseline. No Docker, project build orchestration,
# test runner, or local project runtime. Homebrew's LLVM distribution is present
# only because it is the supported clangd provider; this policy never invokes
# its compiler/linker for project builds.
# jdtls and kotlin-language-server are deliberately absent: their Homebrew
# formulae depend on openjdk and openjdk@21, so installing them pulled the JDK
# this manifest forbids by name. The estate has no Java sources, and its only
# Kotlin lives in a Flutter Android app whose toolchain is out of scope here.
BREW_SOURCE_PACKAGES=(
  git curl ca-certificates node bun uv python
  shellcheck shfmt llvm go gopls rust rust-analyzer dart-sdk docker-language-server
  vscode-langservers-extracted taplo marksman markdown-oxide
  terraform-ls helm-ls cmake-language-server
  pyright basedpyright ruff ty
  oxlint biome osv-scanner gitleaks semgrep hadolint actionlint
  yamllint markdownlint-cli2 prettier
  ripgrep fd eza bat git-delta jq yq ast-grep
  starship atuin fzf zoxide carapace antidote zsh-completions
  gh lazygit yazi xh jaq jnv duckdb difftastic tmux
  # The reverse of the Ubuntu gap: these three were apt packages on
  # Ubuntu and in no macOS manifest, so their zshrc abbreviations were
  # dead on macOS instead.
  btop duf hexyl
)

# Registry-backed language servers, pinned to exact versions for reproducibility
# (RVR-P2-003). This is a subset of the Ubuntu BUN_LSP_PACKAGES (6 of 13); the
# remaining LSPs (vscode-langservers-extracted, @taplo/cli, @biomejs/biome,
# oxlint, markdownlint-cli2, prettier, @ansible/ansible-language-server) arrive
# via Homebrew formulae in BREW_SOURCE_PACKAGES below, where exact pins are not
# possible. The 6 shared entries below are kept version-aligned with Ubuntu.
BUN_LSP_PACKAGES=(
  "typescript@7.0.2"
  "@vtsls/language-server@0.3.0"
  "yaml-language-server@1.24.0"
  "bash-language-server@5.6.0"
  "dockerfile-language-server-nodejs@0.15.0"
  "gh-actions-language-server@0.0.3"
)

GUI_CASKS=(ghostty cmux google-chrome chatgpt claude rustdesk telegram)

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
  # A plan states the formula it will converge on; it does not ask Homebrew.
  # The guard used to fire only when brew was ABSENT, so on the machine this
  # installer actually targets -- where brew is always present -- a plan ran
  # `brew list` once per formula. That is an execution during a dry run, and
  # Homebrew materializes ~/Library/Caches/Homebrew/bootsnap on the first call,
  # so the plan wrote to the home directory it was only describing.
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] ensure Homebrew formula: ${formula}"
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
  # `dart-sdk` backs the Dart analysis server and the `dart mcp-server` transport
  # (ADR 0005). Homebrew cannot pin an exact patch, so unlike Ubuntu there is no
  # receipt here — but the telemetry opt-out is identical on both platforms and
  # shares one helper.
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] disable Dart telemetry reporting through 'dart --disable-analytics'"
  else
    local managed_dart
    managed_dart="$(brew --prefix dart-sdk)/bin/dart"
    rldyour::ensure_dart_telemetry_disabled "$managed_dart" || return 1
  fi
}

ensure_herdr() {
  rldyour::section "Ensure verified Herdr ${HERDR_VERSION}"
  local root="$HOME/.local/share/rldyour/herdr/${HERDR_VERSION}"
  local target="$root/herdr"
  local receipt="$root/.receipt"
  local launcher="$HOME/.local/bin/herdr"
  local marker="# Managed by macos-ubuntu-bootstrap: macos-herdr-runtime-v1"
  local current stage stage_root actual reported_version link_tmp
  local expected_receipt="$marker
version=${HERDR_VERSION}
sha256=${HERDR_MACOS_AARCH64_SHA256}
source=${HERDR_MACOS_AARCH64_URL}"

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] install verified ${HERDR_MACOS_AARCH64_URL} -> ${target}, publish receipt and managed launcher ${launcher}"
    return 0
  fi

  local system machine root_mode target_mode receipt_mode
  system="$(uname -s)" || {
    rldyour::log "error" "could not determine the operating system for Herdr installation"
    return 1
  }
  machine="$(uname -m)" || {
    rldyour::log "error" "could not determine the architecture for Herdr installation"
    return 1
  }
  if [ "$system" != Darwin ] || [ "$machine" != arm64 ]; then
    rldyour::log "error" "Herdr ${HERDR_VERSION} has no managed macOS artifact for ${system}/${machine}"
    return 1
  fi

  if [ -e "$launcher" ] || [ -L "$launcher" ]; then
    [ -L "$launcher" ] || {
      rldyour::log "error" "unmanaged Herdr launcher exists; preserved: ${launcher}"
      return 1
    }
    current="$(readlink "$launcher")"
    case "$current" in
      "$HOME/.local/share/rldyour/herdr/"*) ;;
      *)
        rldyour::log "error" "Herdr launcher points outside its managed namespace; preserved: ${launcher}"
        return 1
        ;;
    esac
  fi

  if [ -e "$root" ] || [ -L "$root" ]; then
    if [ ! -d "$root" ] || [ -L "$root" ]; then
      rldyour::log "error" "managed Herdr root has an unsupported shape; preserved: ${root}"
      return 1
    fi
    [ "$(find "$root" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)" = "$(printf '%s\n%s\n' "$receipt" "$target" | LC_ALL=C sort)" ] || {
      rldyour::log "error" "managed Herdr root contains missing or additional paths; preserved: ${root}"
      return 1
    }
    if [ ! -f "$target" ] || [ -L "$target" ] || [ ! -x "$target" ]; then
      rldyour::log "error" "managed Herdr target has an unsupported shape; preserved: ${target}"
      return 1
    fi
    if [ ! -f "$receipt" ] || [ -L "$receipt" ] || [ "$(cat "$receipt")" != "$expected_receipt" ]; then
      rldyour::log "error" "managed Herdr receipt is missing or divergent; preserved: ${root}"
      return 1
    fi
    actual="$(rldyour::sha256_file "$target")" || return 1
    [ "$actual" = "$HERDR_MACOS_AARCH64_SHA256" ] || {
      rldyour::log "error" "managed Herdr target checksum diverged; preserved: ${target}"
      return 1
    }
    root_mode="$(rldyour::file_mode "$root")" || return 1
    target_mode="$(rldyour::file_mode "$target")" || return 1
    receipt_mode="$(rldyour::file_mode "$receipt")" || return 1
    if [ "$root_mode" != 755 ] || [ "$target_mode" != 755 ] || [ "$receipt_mode" != 600 ]; then
      rldyour::log "error" "managed Herdr permissions diverged; preserved: ${root}"
      return 1
    fi
    reported_version="$("$target" --version 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -n 1)"
    [ "$reported_version" = "$HERDR_VERSION" ] || {
      rldyour::log "error" "managed Herdr reports ${reported_version:-no version}, expected ${HERDR_VERSION}; preserved: ${root}"
      return 1
    }
  else
    stage="$(mktemp -d)" || return 1
    stage_root="$stage/${HERDR_VERSION}"
    mkdir "$stage_root" || { rm -rf "$stage"; return 1; }
    chmod 0755 "$stage_root" || { rm -rf "$stage"; return 1; }
    if ! rldyour::download_verified_file \
      "$HERDR_MACOS_AARCH64_URL" "$HERDR_MACOS_AARCH64_SHA256" "$stage_root/herdr"; then
      rm -rf "$stage"
      rldyour::log "error" "official Herdr ${HERDR_VERSION} asset is unavailable or failed checksum verification"
      return 1
    fi
    actual="$(rldyour::sha256_file "$stage_root/herdr")" || { rm -rf "$stage"; return 1; }
    [ "$actual" = "$HERDR_MACOS_AARCH64_SHA256" ] || {
      rm -rf "$stage"
      rldyour::log "error" "downloaded Herdr checksum diverged before publication"
      return 1
    }
    chmod 0755 "$stage_root/herdr" || { rm -rf "$stage"; return 1; }
    reported_version="$("$stage_root/herdr" --version 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -n 1)"
    [ "$reported_version" = "$HERDR_VERSION" ] || {
      rm -rf "$stage"
      rldyour::log "error" "verified Herdr asset reports ${reported_version:-no version}, expected ${HERDR_VERSION}"
      return 1
    }
    printf '%s\n' "$expected_receipt" >"$stage_root/.receipt" || { rm -rf "$stage"; return 1; }
    chmod 0600 "$stage_root/.receipt" || { rm -rf "$stage"; return 1; }
    rldyour::_managed_tree_permissions validate "$stage_root" || { rm -rf "$stage"; return 1; }
    mkdir -p "${root%/*}" || { rm -rf "$stage"; return 1; }
    mv "$stage_root" "$root" || { rm -rf "$stage"; return 1; }
    rmdir "$stage" 2>/dev/null || rm -rf "$stage"
  fi

  mkdir -p "$HOME/.local/bin" || return 1
  link_tmp="$(mktemp "$HOME/.local/bin/.herdr-link.XXXXXX")" || return 1
  rm -f "$link_tmp"
  ln -s "$target" "$link_tmp" || return 1
  mv -f "$link_tmp" "$launcher" || { rm -f "$link_tmp"; return 1; }
  hash -r
  [ "$(command -v herdr)" = "$launcher" ] || {
    rldyour::log "error" "managed Herdr launcher does not win PATH resolution"
    return 1
  }
  rldyour::log "ok" "verified managed Herdr ${HERDR_VERSION}"
}

cask_app_path() {
  case "$1" in
    ghostty) printf '%s\n' "/Applications/Ghostty.app" ;;
    cmux) printf '%s\n' "/Applications/cmux.app" ;;
    chatgpt) printf '%s\n' "/Applications/ChatGPT.app" ;;
    claude) printf '%s\n' "/Applications/Claude.app" ;;
    google-chrome) printf '%s\n' "/Applications/Google Chrome.app" ;;
    rustdesk) printf '%s\n' "/Applications/RustDesk.app" ;;
    telegram) printf '%s\n' "/Applications/Telegram.app" ;;
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
  # Same contract as ensure_formula: no Homebrew invocation during a plan.
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] ensure Homebrew cask: ${cask}"
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

# Set when a cask could not be installed. Reported at the end of main.
GUI_LAYER_FAILED=0

install_gui_apps() {
  if [ "$GUI_ENABLED" -ne 1 ]; then
    rldyour::log "info" "GUI apps disabled by --no-gui"
    return 0
  fi
  rldyour::section "Install verified macOS GUI applications"
  local cask failed=0
  # Attempt every cask, then report. This loop used to call ensure_cask bare
  # under `set -e`, so one unavailable cask -- a Homebrew rename, a notarization
  # change, a network blip -- aborted the whole script and stranded every layer
  # behind it: language servers, AI CLIs, and verification. That is the same failure this repository already
  # fixed twice on Ubuntu; the optional layer must never be able to take the
  # required ones down with it.
  for cask in "${GUI_CASKS[@]}"; do
    if ! ensure_cask "$cask"; then
      rldyour::log "error" "cask failed: ${cask}"
      failed=$((failed + 1))
    fi
  done
  if [ "$failed" -gt 0 ]; then
    GUI_LAYER_FAILED=$failed
    rldyour::log "error" "${failed} GUI cask(s) failed; later layers were still attempted"
  fi
  rldyour::log "info" "Installed the workstation GUI application set."
}

install_ai_runtimes() { rldyour::install_vendor_ai_clis; }

install_bun_lsps() {
  rldyour::section "Install registry-backed language servers"
  local entry name version
  for entry in "${BUN_LSP_PACKAGES[@]}"; do
    name="${entry%@*}"
    version="${entry##*@}"
    # Reproducible: skip only when the EXACT pinned version is already installed;
    # otherwise install the pin so a stale/divergent version is corrected.
    if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
      # `bun pm ls -g` creates ~/.bun/install/global before it can answer, so a
      # plan may not ask. State the pin the apply will converge on.
      rldyour::log "info" "[DRY-RUN] ensure pinned Bun source tool: ${entry}"
      continue
    fi
    if bun pm ls -g 2>/dev/null | grep -Fq "${name}@${version}"; then
      rldyour::log "ok" "pinned Bun source tool present: ${entry}"
    else
      rldyour::run bun add -g --ignore-scripts "$entry"
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
    # The active harness set that cmux integrates is codex only, per the
    # one-owner-per-harness policy (RVR-P1-004).
    # shellcheck disable=SC2043
    for agent in codex; do
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
    RLDYOUR_GUI_ENABLED="$GUI_ENABLED" \
      bash "$SCRIPT_DIR/verify.sh" --strict
  fi
}

main() {
  local mode_label
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
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    mode_label=dry-run
  else
    mode_label=apply
  fi
  rldyour::log "info" "mode: ${mode_label}; gui: $GUI_ENABLED; policy: $LOCAL_EXECUTION_POLICY"

  if [ "$SKIP_SYSTEM" -eq 0 ]; then
    ensure_homebrew
    rldyour::ensure_path
    if command -v brew >/dev/null 2>&1 || [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      install_source_packages
      ensure_herdr
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

  [ "$SKIP_LSPS" -eq 1 ] || install_bun_lsps

  configure_cmux_hooks

  # Install vendor CLIs after the platform toolchain is available.
  [ "$SKIP_AI" -eq 1 ] || install_ai_runtimes
  if [ "$GUI_LAYER_FAILED" -ne 0 ]; then
    rldyour::log "error" "${GUI_LAYER_FAILED} GUI cask(s) failed; every other layer was still attempted"
    return 1
  fi
  verify_apply
  rldyour::log "info" "Run 'bash scripts/auth-handoff.sh' for user-controlled sign-in steps."
}

# Guard so the main flow only runs when executed directly, not when sourced.
# Mirrors scripts/ubuntu/install.sh and scripts/ubuntu/server.sh so macOS
# install.sh is safe to source from tests.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
