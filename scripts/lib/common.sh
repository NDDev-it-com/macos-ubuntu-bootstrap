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
    "$HOME/go/bin"
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

# --- CloakBrowser privacy-first Chromium (owner standard) ---------------------
# CloakBrowser is a stealth-hardened Chromium (source-level fingerprint patches)
# used as the DEFAULT browser backend for every rldyour browser provider so that
# terminal browser automation (Webwright / Playwright CLI / Chrome DevTools MCP)
# runs through one privacy-hardened, low-trace engine. The free-tier binary
# (Chromium v146 line) is signature-verified (Ed25519) by the wrapper before use;
# Pro (v148+) is activated only by an owner-supplied CLOAKBROWSER_LICENSE_KEY read
# from ~/.zshenv.secrets, never committed. Platform-agnostic (macOS + Linux).
rldyour::_cloak_home() {
  printf '%s' "${CLOAKBROWSER_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/rldyour/cloakbrowser}"
}

# Install the CloakBrowser wrapper into an isolated venv, download + verify the
# pinned free-tier Chromium binary, and publish two managed launchers on PATH:
#   cloak-chromium          -> resolves and execs the real versioned binary
#                              (never a symlink: the .app resolves Frameworks via
#                              @executable_path, so the absolute real path is
#                              required for renderer subprocesses to start)
#   cloak-chromium-stealth  -> cloak-chromium + default stealth args (manual runs)
rldyour::install_cloakbrowser() {
  local strict="${RLDYOUR_STRICT:-0}"
  local dry_run="${RLDYOUR_DRY_RUN:-1}"
  local pin="${CLOAKBROWSER_PIN:-0.4.8}"
  local bin_dir="${RLDYOUR_BIN_DIR:-$HOME/.local/bin}"
  local home cache
  home="$(rldyour::_cloak_home)"
  cache="${CLOAKBROWSER_CACHE_DIR:-$home/cache}"

  rldyour::section "Install CloakBrowser (privacy-first Chromium, pinned ${pin})"
  if ! command -v uv >/dev/null 2>&1; then
    if [ "$strict" -eq 1 ]; then
      rldyour::log "error" "uv is required to install the CloakBrowser wrapper"
      return 1
    fi
    rldyour::log "warn" "uv unavailable; skipping CloakBrowser"
    return 0
  fi

  if [ "$dry_run" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] uv venv ${home}/.venv"
    rldyour::log "info" "[DRY-RUN] uv pip install cloakbrowser==${pin} (isolated venv)"
    rldyour::log "info" "[DRY-RUN] cloakbrowser.ensure_binary() -> download + Ed25519-verify free Chromium into ${cache}"
    rldyour::log "info" "[DRY-RUN] install launchers ${bin_dir}/cloak-chromium and ${bin_dir}/cloak-chromium-stealth"
    return 0
  fi

  mkdir -p "$home" "$bin_dir"
  if [ ! -x "$home/.venv/bin/python" ]; then
    uv venv "$home/.venv" >/dev/null 2>&1 || { rldyour::log "warn" "CloakBrowser venv creation failed (best-effort)"; return 0; }
  fi
  if ! uv pip install --python "$home/.venv/bin/python" "cloakbrowser==${pin}" >/dev/null 2>&1; then
    rldyour::log "warn" "CloakBrowser wrapper install failed (best-effort)"
    return 0
  fi
  if ! CLOAKBROWSER_CACHE_DIR="$cache" "$home/.venv/bin/python" -c "import cloakbrowser; print(cloakbrowser.ensure_binary())" >/dev/null 2>&1; then
    rldyour::log "warn" "CloakBrowser binary download/verify failed (best-effort; check network)"
  fi

  local fp
  case "$(uname -s)" in Darwin) fp="macos" ;; *) fp="linux" ;; esac

  cat > "$bin_dir/cloak-chromium" <<RESOLVE
#!/usr/bin/env bash
# Managed by rldyour-new-mac-or-ubuntu. Resolve + exec the CloakBrowser Chromium.
# The .app bundle resolves Frameworks via @executable_path, so exec the REAL
# versioned path (never a symlink to Contents/MacOS/Chromium).
set -euo pipefail
CB="\${CLOAKBROWSER_CACHE_DIR:-${cache}}"
bin="\$(/bin/ls -1d "\$CB"/chromium-*/Chromium.app/Contents/MacOS/Chromium "\$CB"/chromium-*/chrome 2>/dev/null | sort -V | tail -1)"
if [ -z "\${bin:-}" ] || [ ! -x "\$bin" ]; then
  echo "cloak-chromium: no CloakBrowser Chromium binary under \$CB (run bootstrap browser layer)" >&2
  exit 127
fi
exec "\$bin" "\$@"
RESOLVE
  chmod +x "$bin_dir/cloak-chromium"

  cat > "$bin_dir/cloak-chromium-stealth" <<STEALTH
#!/usr/bin/env bash
# Managed by rldyour-new-mac-or-ubuntu. CloakBrowser + default stealth args.
exec "${bin_dir}/cloak-chromium" \\
  --no-sandbox --fingerprint-platform="\${CLOAK_FP_PLATFORM:-${fp}}" \\
  --no-first-run --no-default-browser-check "\$@"
STEALTH
  chmod +x "$bin_dir/cloak-chromium-stealth"
  rldyour::log "ok" "CloakBrowser installed; launchers at ${bin_dir}/cloak-chromium[-stealth]"
}

# Install and load a managed background service that runs one headless
# CloakBrowser with a loopback CDP endpoint (127.0.0.1:9222). Every adapter's
# chrome-devtools-mcp connects with --browserUrl, keeping the committed adapter
# configs portable (no per-user absolute paths). launchd on macOS, systemd
# --user on Linux; KeepAlive so the endpoint is always available.
rldyour::install_cloakbrowser_daemon() {
  local dry_run="${RLDYOUR_DRY_RUN:-1}"
  local bin_dir="${RLDYOUR_BIN_DIR:-$HOME/.local/bin}"
  local port="${CLOAKBROWSER_CDP_PORT:-9222}"
  local home profile fp
  home="$(rldyour::_cloak_home)"
  profile="$home/daemon-profile"
  case "$(uname -s)" in Darwin) fp="macos" ;; *) fp="linux" ;; esac

  rldyour::section "Install CloakBrowser CDP daemon (127.0.0.1:${port})"
  if [ "$dry_run" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] managed headless CloakBrowser CDP service on 127.0.0.1:${port} (KeepAlive)"
    return 0
  fi
  mkdir -p "$profile"

  if [ "$fp" = "macos" ]; then
    local plist="$HOME/Library/LaunchAgents/com.rldyour.cloakbrowser.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.rldyour.cloakbrowser</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bin_dir}/cloak-chromium</string>
    <string>--headless=new</string>
    <string>--remote-debugging-address=127.0.0.1</string>
    <string>--remote-debugging-port=${port}</string>
    <string>--user-data-dir=${profile}</string>
    <string>--no-first-run</string>
    <string>--no-default-browser-check</string>
    <string>--fingerprint-platform=${fp}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>${home}/daemon.log</string>
  <key>StandardOutPath</key><string>${home}/daemon.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/com.rldyour.cloakbrowser" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1; then
      rldyour::log "ok" "CloakBrowser launchd service loaded (127.0.0.1:${port})"
    else
      rldyour::log "warn" "launchctl bootstrap failed; load manually: launchctl bootstrap gui/$(id -u) $plist"
    fi
  else
    local unit="$HOME/.config/systemd/user/rldyour-cloakbrowser.service"
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$unit" <<UNIT
[Unit]
Description=rldyour CloakBrowser headless CDP endpoint
After=default.target

[Service]
ExecStart=${bin_dir}/cloak-chromium --headless=new --remote-debugging-address=127.0.0.1 --remote-debugging-port=${port} --user-data-dir=${profile} --no-first-run --no-default-browser-check --fingerprint-platform=${fp}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
UNIT
    if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1; then
      # Enable lingering so the --user service starts at boot and survives with no
      # active login session -- required on a headless Ubuntu server. Best-effort:
      # needs privileges, and without it the daemon still runs while logged in.
      if command -v loginctl >/dev/null 2>&1 && ! loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -q '^yes$'; then
        if loginctl enable-linger "$(id -un)" >/dev/null 2>&1; then
          rldyour::log "ok" "enabled systemd linger for $(id -un) (boot-start on headless servers)"
        elif command -v sudo >/dev/null 2>&1 && sudo -n loginctl enable-linger "$(id -un)" >/dev/null 2>&1; then
          rldyour::log "ok" "enabled systemd linger for $(id -un) via sudo"
        else
          rldyour::log "warn" "could not enable linger; CloakBrowser daemon will not auto-start at boot on a headless server (run: loginctl enable-linger $(id -un))"
        fi
      fi
      if systemctl --user enable --now rldyour-cloakbrowser.service >/dev/null 2>&1; then
        rldyour::log "ok" "CloakBrowser systemd --user service enabled (127.0.0.1:${port})"
      else
        rldyour::log "warn" "systemd --user enable failed; start manually"
      fi
    else
      rldyour::log "warn" "systemd --user unavailable; start CloakBrowser CDP daemon manually"
    fi
  fi
}

# Install rtk (Rust Token Killer, Apache-2.0), the token-economy shell-output
# compressor the Claude and Codex adapters drive through their PreToolUse hooks
# / rules file. Pinned to RTK_VERSION. Also writes the machine-global rtk config
# with the exclude_commands baseline that protects hook-watched git commands and
# validator/JSON output (control-plane config/token-economy-policy.json, ADR 0004).
# Best-effort: the adapter hooks degrade to a no-op passthrough when rtk is
# absent, so a failed install never blocks the workstation. Skip with
# RLDYOUR_SKIP_RTK=1.
rldyour::install_rtk() {
  local strict="${RLDYOUR_STRICT:-0}"
  local dry_run="${RLDYOUR_DRY_RUN:-1}"
  local pin="${RTK_VERSION:-0.43.0}"
  local cfg_home cfg
  case "$(uname -s)" in
    Darwin) cfg_home="$HOME/Library/Application Support/rtk" ;;
    *) cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}/rtk" ;;
  esac
  cfg="$cfg_home/config.toml"

  rldyour::section "Install rtk token-economy CLI (pinned ${pin})"
  if [ "${RLDYOUR_SKIP_RTK:-0}" -ne 0 ]; then
    rldyour::log "warn" "rtk layer skipped by RLDYOUR_SKIP_RTK"
    return 0
  fi

  if [ "$dry_run" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] install rtk ${pin} (brew install rtk from homebrew-core, or rtk-ai/rtk install.sh -> ~/.local/bin)"
    rldyour::log "info" "[DRY-RUN] write ${cfg} with [hooks] exclude_commands baseline"
    return 0
  fi

  # crates.io 'rtk' is a different tool (Rust Type Kit); never `cargo install rtk`.
  if command -v rtk >/dev/null 2>&1; then
    rldyour::log "ok" "rtk already present ($(rtk --version 2>/dev/null | head -1))"
  elif command -v brew >/dev/null 2>&1; then
    if brew install rtk >/dev/null 2>&1; then
      rldyour::log "ok" "rtk installed via Homebrew"
    else
      rldyour::log "warn" "brew install rtk failed (best-effort; adapter hooks degrade to no-op)"
    fi
  elif command -v curl >/dev/null 2>&1; then
    if curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh >/dev/null 2>&1; then
      rldyour::log "ok" "rtk installed via install.sh (~/.local/bin)"
    else
      rldyour::log "warn" "rtk install.sh failed (best-effort)"
    fi
  else
    if [ "$strict" -eq 1 ]; then
      rldyour::log "error" "no brew or curl available to install rtk"
      return 1
    fi
    rldyour::log "warn" "no brew or curl available; skipping rtk (best-effort)"
  fi

  # Idempotent: write the exclude_commands baseline only when absent so an owner's
  # edits are never clobbered.
  if [ ! -f "$cfg" ]; then
    mkdir -p "$cfg_home"
    cat > "$cfg" <<'RTKCFG'
# Managed by rldyour-new-mac-or-ubuntu (token-economy standard; control-plane
# config/token-economy-policy.json / ADR 0004). Safe to edit.
[hooks]
# Never rewrite commands whose output other hooks match on or that scripts parse
# byte-for-byte: git subcommands watched by the rldyour-flow / rldyour-serena-mcp
# hooks, gh CI/api, and jq pipelines. Control-plane validators
# (python3 scripts/validate_*) are unknown command families to rtk and pass
# through unchanged.
exclude_commands = [
  "git commit",
  "git merge",
  "git rebase",
  "git cherry-pick",
  "git am",
  "git push",
  "gh workflow",
  "gh run",
  "gh actions",
  "gh api",
  "jq",
]

[tee]
mode = "failures"
RTKCFG
    rldyour::log "ok" "wrote rtk config with exclude_commands baseline: ${cfg}"
  else
    rldyour::log "info" "rtk config already present (kept): ${cfg}"
  fi
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

  # CloakBrowser is the DEFAULT privacy-first browser backend for every provider
  # below: its managed CDP daemon (127.0.0.1:9222) is what chrome-devtools-mcp
  # connects to via --browserUrl, and its launcher is the Webwright / Playwright
  # executable. Install it (and start the daemon) before the providers so the
  # endpoint is live when they first connect. Skip the whole CloakBrowser layer
  # with RLDYOUR_SKIP_CLOAKBROWSER=1 (falls back to each provider's own Chromium).
  if [ "${RLDYOUR_SKIP_CLOAKBROWSER:-0}" -eq 0 ]; then
    rldyour::install_cloakbrowser
    rldyour::install_cloakbrowser_daemon
    export AGENT_BROWSER_EXECUTABLE_PATH="${AGENT_BROWSER_EXECUTABLE_PATH:-${RLDYOUR_BIN_DIR:-$HOME/.local/bin}/cloak-chromium}"
  else
    rldyour::log "warn" "CloakBrowser layer skipped by RLDYOUR_SKIP_CLOAKBROWSER"
  fi

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

# --- Terminal layer (0.2.3) --------------------------------------------------

# Global git performance keys for agent-heavy repositories.
rldyour::ensure_git_perf() {
  rldyour::section "Configure git performance keys (global)"
  rldyour::run git config --global core.fsmonitor true
  rldyour::run git config --global core.untrackedCache true
  rldyour::run git config --global fetch.writeCommitGraph true
}

# git-delta as the human pager. Pagers never fire on pipes, so agents are
# unaffected; skipped entirely when delta is not on PATH (e.g. minimal server).
rldyour::ensure_git_delta_config() {
  rldyour::section "Configure git-delta pager (global)"
  if ! command -v delta >/dev/null 2>&1; then
    rldyour::log "warn" "delta not on PATH; skipping pager config"
    return 0
  fi
  rldyour::run git config --global core.pager delta
  rldyour::run git config --global interactive.diffFilter "delta --color-only"
  rldyour::run git config --global delta.navigate true
  rldyour::run git config --global delta.features "side-by-side line-numbers"
}

# Install one config template. Contract: create when absent; when present and
# identical -> ok; when present and different -> KEEP the user's file and
# point at the template. User edits are never clobbered.
rldyour::install_config_template() {
  local src="$1" dest="$2"
  if [ ! -f "$src" ]; then
    rldyour::log "warn" "template missing: $src"
    return 0
  fi
  if [ -f "$dest" ]; then
    if cmp -s "$src" "$dest"; then
      rldyour::log "ok" "$(basename "$dest") already current"
    else
      rldyour::log "warn" "$(basename "$dest") exists and differs -- kept as-is; template: $src"
    fi
    return 0
  fi
  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] install $src -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  rldyour::log "ok" "installed $(basename "$dest")"
}

rldyour::install_terminal_configs() {
  local tpl_dir="$1"
  rldyour::section "Install terminal shell configs (zsh-first, agent-gated)"
  rldyour::install_config_template "$tpl_dir/zshenv"          "$HOME/.zshenv"
  rldyour::install_config_template "$tpl_dir/zprofile"        "$HOME/.zprofile"
  rldyour::install_config_template "$tpl_dir/zshrc"           "$HOME/.zshrc"
  rldyour::install_config_template "$tpl_dir/zsh_plugins.txt" "$HOME/.zsh_plugins.txt"
  rldyour::install_config_template "$tpl_dir/starship.toml"   "$HOME/.config/starship.toml"
}
