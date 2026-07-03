#!/usr/bin/env bash

set -euo pipefail

RLDYOUR_DRY_RUN="${RLDYOUR_DRY_RUN:-1}"

rldyour::log() {
  local level=$1
  shift
  printf '[%s] %s\n' "$level" "$*"
}

rldyour::run() {
  local -a cmd=("$@")
  local rendered=

  rendered=$(printf " %q" "${cmd[@]}")
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    printf '[DRY-RUN] %s\n' "${rendered# }"
    return 0
  fi
  "${cmd[@]}"
}

rldyour::require_cmd() {
  local name=$1
  local level=$2
  if command -v "$name" >/dev/null 2>&1; then
    rldyour::log "ok" "$name on PATH"
    return 0
  fi

  if [ "$level" = "required" ]; then
    rldyour::log "missing" "required command not found: $name"
    return 1
  fi

  rldyour::log "warn" "optional command not found: $name"
  return 0
}

rldyour::require_one_of_cmd() {
  local level=$1
  shift
  local names=("$@")
  local found_name=""

  for name in "${names[@]}"; do
    if command -v "$name" >/dev/null 2>&1; then
      rldyour::log "ok" "$name on PATH"
      found_name="$name"
      break
    fi
  done

  if [ -n "$found_name" ]; then
    return 0
  fi

  local alt="one of (${names[*]})"
  if [ "$level" = "required" ]; then
    rldyour::log "missing" "required command not found: $alt"
    return 1
  fi

  rldyour::log "warn" "optional command not found: $alt"
  return 0
}

rldyour::need_cmd() {
  local command_name=$1
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '%s\n' "$command_name"
    return 0
  fi
  return 1
}

rldyour::section() {
  printf '\n==> %s\n' "$*"
}

rldyour::require_file() {
  local path=$1
  if [ ! -f "$path" ]; then
    rldyour::log "missing" "required file: $path"
    return 1
  fi
  rldyour::log "ok" "found file: $path"
}

rldyour::require_cmd_min_version() {
  local command_name=$1
  local min_version=$2
  local version_cmd=${3:-"--version"}

  if ! command -v "$command_name" >/dev/null 2>&1; then
    rldyour::log "missing" "$command_name not found"
    return 1
  fi

  local actual_version
  actual_version=$("$command_name" "$version_cmd" 2>/dev/null | head -n 1 | sed 's/^v//; s/^[^0-9]*//')
  if [ -z "$actual_version" ]; then
    rldyour::log "warn" "could not detect version for $command_name; skipping numeric check"
    return 0
  fi

  local normalized_actual
  normalized_actual="$(printf '%s' "$actual_version" | sed 's/[[:space:]].*//')"

  if [ "$(printf '%s\n%s\n' "$min_version" "$normalized_actual" | sort -V | head -n 1)" != "$min_version" ]; then
    rldyour::log "warn" "$command_name version check: $normalized_actual (expected >= $min_version)"
    return 1
  fi

  rldyour::log "ok" "$command_name version OK: $normalized_actual"
  return 0
}

rldyour::assert_root() {
  local dir=$1
  if [ ! -f "$dir/config/rldyour-contract.json" ]; then
    rldyour::log "error" "not inside module root: missing config/rldyour-contract.json in $dir"
    return 1
  fi
  return 0
}

rldyour::has_root() {
  local script_dir=$1
  local root_dir
  root_dir="$(cd "$script_dir/../.." && pwd)"
  if [ ! -d "$root_dir" ]; then
    return 1
  fi
  printf '%s\n' "$root_dir"
}

rldyour::ensure_path() {
  local -a candidates=(
    "$HOME/.local/bin"
    "$HOME/.cargo/bin"
    "$HOME/.bun/bin"
    "$HOME/.rldyour/bin"
    "$HOME/.mimocode/bin"
  )
  for p in "${candidates[@]}"; do
    if [ -d "$p" ] && [[ ":$PATH:" != *":$p:"* ]]; then
      PATH="$p:$PATH"
    fi
  done
  export PATH
}

# Webwright is a pinned GitHub checkout provider. The steps mirror the
# superproject `scripts/install_webwright.sh` release-grade install and are kept
# best-effort so a slow clone or Chromium download never breaks the base layer.
rldyour::_install_webwright() {
  local repo=$1
  local pin=$2
  local home=$3
  mkdir -p "$(dirname "$home")" || return 1
  if [ ! -d "$home/.git" ]; then
    git clone "$repo" "$home" || return 1
  fi
  git -C "$home" fetch origin --tags --prune || return 1
  git -C "$home" checkout "$pin" || return 1
  python3 -m venv "$home/.venv" || return 1
  "$home/.venv/bin/pip" install -U pip || return 1
  "$home/.venv/bin/pip" install -e "$home" || return 1
  "$home/.venv/bin/python" -m playwright install chromium || return 1
}

# Install the pinned browser providers used by the AI CLI config adapters:
# Chrome DevTools MCP and Playwright CLI (deterministic bun globals, required)
# plus Microsoft Webwright (pinned checkout, best-effort). Shared across macOS
# and Ubuntu because the browser layer is platform-agnostic. Honors
# RLDYOUR_DRY_RUN and RLDYOUR_STRICT and pinned version env overrides.
rldyour::install_browser_providers() {
  local strict="${RLDYOUR_STRICT:-0}"
  local dry_run="${RLDYOUR_DRY_RUN:-1}"
  local chrome_version="${CHROME_DEVTOOLS_MCP_VERSION:-1.5.0}"
  local playwright_version="${PLAYWRIGHT_CLI_VERSION:-0.1.15}"
  local webwright_pin="${WEBWRIGHT_PIN:-4a46f282ec37f27d6003cc498a977939d62d9015}"
  local webwright_repo="${WEBWRIGHT_REPOSITORY:-https://github.com/microsoft/Webwright.git}"
  local webwright_home="${WEBWRIGHT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/rldyour/webwright/Microsoft-Webwright}"

  rldyour::section "Install browser providers (pinned)"
  if ! command -v bun >/dev/null 2>&1; then
    if [ "$strict" -eq 1 ]; then
      rldyour::log "error" "bun is required for browser provider install"
      return 1
    fi
    rldyour::log "warn" "skip browser providers until bun is available"
    return 0
  fi

  if command -v chrome-devtools-mcp >/dev/null 2>&1; then
    rldyour::log "ok" "chrome-devtools-mcp already present"
  else
    rldyour::run bun add -g "chrome-devtools-mcp@${chrome_version}"
  fi

  if command -v playwright-cli >/dev/null 2>&1; then
    rldyour::log "ok" "playwright-cli already present"
  else
    rldyour::run bun add -g "@playwright/cli@${playwright_version}"
  fi

  # Skills install runs from the user home so it never writes runtime artifacts
  # into this module tree; best-effort because CLI layouts can change.
  if [ "$dry_run" -eq 0 ] && command -v playwright-cli >/dev/null 2>&1; then
    if ! (cd "$HOME" && playwright-cli install --skills >/dev/null 2>&1); then
      rldyour::log "warn" "playwright-cli skills install skipped (best-effort)"
    fi
  fi

  if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    rldyour::log "warn" "git and python3 required for Webwright; skipped"
    return 0
  fi
  if [ "$dry_run" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] webwright pinned checkout ${webwright_pin} -> ${webwright_home}"
    return 0
  fi
  if rldyour::_install_webwright "$webwright_repo" "$webwright_pin" "$webwright_home"; then
    rldyour::log "ok" "Webwright provider installed (${webwright_pin})"
  else
    rldyour::log "warn" "Webwright provider install skipped (best-effort)"
  fi
}
