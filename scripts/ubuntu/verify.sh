#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

rldyour::ubuntu_verify::contract_hash() {
  # python-surface: verifier-runtime-contract
  /usr/bin/python3 -I - "$REPO_ROOT/config/rldyour-contract.json" "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    contract = json.load(handle)
print(contract["runtime_support"][sys.argv[2]][sys.argv[3]])
PY
}

rldyour::ubuntu_verify::herdr_contract_value() {
  # python-surface: verifier-herdr-contract
  /usr/bin/python3 -I - "$REPO_ROOT/config/rldyour-contract.json" "$@" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    herdr = json.load(handle)["user_tools"]["herdr"]
if sys.argv[2] == "version" and len(sys.argv) == 3:
    print(herdr["version"])
elif sys.argv[2] == "sha256" and len(sys.argv) == 4:
    print(herdr["source"]["assets"][sys.argv[3]]["sha256"])
else:
    raise SystemExit(2)
PY
}

rldyour::ubuntu_verify::herdr_provenance() {
  local arch_key version sha root target
  version="$(rldyour::ubuntu_verify::herdr_contract_value version)"
  case "$(uname -m)" in
    x86_64|amd64) arch_key=linux-x86_64 ;;
    aarch64|arm64) arch_key=linux-aarch64 ;;
    *) rldyour::log "missing" "Herdr has no managed Ubuntu artifact for $(uname -m)"; return 1 ;;
  esac
  sha="$(rldyour::ubuntu_verify::herdr_contract_value sha256 "$arch_key")"
  root="$HOME/.local/share/rldyour/herdr/${version}"
  target="$root/herdr"
  rldyour::ubuntu_verify::runtime_receipt herdr "$version" "$sha" "$root" herdr || {
    rldyour::log "missing" "Herdr exact managed Ubuntu receipt"
    return 1
  }
  rldyour::ubuntu_verify::managed_link herdr "$target" || {
    rldyour::log "missing" "Herdr exact managed Ubuntu launcher"
    return 1
  }
  [ "$(command -v herdr)" = "$HOME/.local/bin/herdr" ] || {
    rldyour::log "missing" "managed Herdr launcher must win Ubuntu PATH resolution"
    return 1
  }
  [ "$(herdr --version 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -n 1)" = "$version" ] || {
    rldyour::log "missing" "Herdr exact managed Ubuntu version ${version}"
    return 1
  }
  rldyour::log "ok" "Herdr exact managed Ubuntu runtime ${version} (${arch_key})"
}

rldyour::ubuntu_verify::runtime_receipt() {
  local runtime=$1 version=$2 archive_sha256=$3 root=$4
  local receipt="$root/.rldyour-runtime-receipt" relative key expected
  shift 4

  [ ! -L "$root" ] && [ -d "$root" ] && [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  [ "$(grep -Fxc '# Managed by macos-ubuntu-bootstrap: ubuntu-runtime-v1' "$receipt")" -eq 1 ] || return 1
  [ "$(grep -Fxc "runtime=${runtime}" "$receipt")" -eq 1 ] || return 1
  [ "$(grep -Fxc "version=${version}" "$receipt")" -eq 1 ] || return 1
  [ "$(grep -Fxc "archive_sha256=${archive_sha256}" "$receipt")" -eq 1 ] || return 1
  for relative in "$@"; do
    [ -x "$root/$relative" ] || return 1
    key=${relative//\//_}
    [ "$(grep -c "^sha256_${key}=" "$receipt")" -eq 1 ] || return 1
    expected=$(sed -n "s/^sha256_${key}=//p" "$receipt")
    printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
    [ "$(rldyour::sha256_file "$root/$relative")" = "$expected" ] || return 1
  done
}

# The installed Chrome keyring must carry exactly one primary key, and it must
# be the fingerprint the contract declares. Named rather than inlined so a test
# can execute it against real keyrings instead of asserting on its source text.
rldyour::ubuntu_verify::chrome_key_trusted() {
  local keyring=$1 expected=$2 observed
  observed="$(rldyour::gpg_primary_fingerprint "$keyring")" || return 1
  [ "$observed" = "$expected" ]
}

rldyour::ubuntu_verify::managed_link() {
  local name=$1 expected=$2
  local path="$HOME/.local/bin/$name"
  [ -L "$path" ] && [ "$(readlink "$path")" = "$expected" ]
}

rldyour::ubuntu_verify::tool_host_provenance() {
  local arch node_sha uv_sha bun_sha node_root uv_root bun_root name
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) rldyour::log "error" "unsupported Ubuntu tool-host architecture"; return 1 ;;
  esac
  node_sha=$(rldyour::ubuntu_verify::contract_hash ubuntu_node_sha256 "$arch")
  uv_sha=$(rldyour::ubuntu_verify::contract_hash ubuntu_uv_sha256 "$arch")
  # Bun x64 has an AVX2-gated baseline variant with its own tracked hash.
  local bun_arch="$arch"
  if [ "$arch" = "x64" ] && ! rldyour::cpu_has_avx2; then bun_arch="x64-baseline"; fi
  bun_sha=$(rldyour::ubuntu_verify::contract_hash ubuntu_bun_sha256 "$bun_arch")
  node_root="$HOME/.local/share/rldyour/node/v24.19.0"
  uv_root="$HOME/.local/share/rldyour/uv/0.12.4"
  bun_root="$HOME/.local/share/rldyour/bun/1.3.14"

  rldyour::ubuntu_verify::runtime_receipt node 24.19.0 "$node_sha" "$node_root" \
    bin/node bin/npm bin/npx bin/corepack || return 1
  rldyour::ubuntu_verify::runtime_receipt uv 0.12.4 "$uv_sha" "$uv_root" uv uvx || return 1
  rldyour::ubuntu_verify::runtime_receipt bun 1.3.14 "$bun_sha" "$bun_root" bun || return 1
  # Only node is published to the managed PATH; npm/npx/corepack must NOT be
  # linked (uv and bun are the only package managers). Their integrity inside
  # the tarball is still covered by the runtime receipt checked above.
  rldyour::ubuntu_verify::managed_link node "$node_root/bin/node" || return 1
  rldyour::ubuntu_verify::managed_link uv "$uv_root/uv" || return 1
  rldyour::ubuntu_verify::managed_link uvx "$uv_root/uvx" || return 1
  rldyour::ubuntu_verify::managed_link bun "$bun_root/bun" || return 1
  rldyour::ubuntu_verify::managed_link bunx "$bun_root/bun" || return 1
  rldyour::log "ok" "Ubuntu Node.js, uv, and Bun receipts and managed links verified"
}

rldyour::ubuntu_verify::telegram_policy() {
  local launcher="$HOME/.local/bin/telegram-desktop"
  local namespace="$HOME/.local/share/rldyour/telegram"
  local policy="$HOME/.local/share/TelegramDesktop/externalupdater.d/macos-ubuntu-bootstrap"
  local marker="# Managed by macos-ubuntu-bootstrap: telegram-external-updater-v1"
  local desktop_id="org.telegram.desktop.desktop"
  local desktop_entry="$HOME/.local/share/applications/$desktop_id"
  local resolved row expected asset actual candidate
  local -a icon_assets=(
    "3fb1400c7dc9bbc3b5cb3ffedcbf4a9b09c53e28b57a7ff33a8a6b9048864090;$HOME/.local/share/icons/hicolor/256x256/apps/org.telegram.desktop.png"
    "a93380f2c7e6aae4d5fde8940020bd966e97ad8c4880f45c016edfef3f5193e1;$HOME/.local/share/icons/hicolor/symbolic/apps/org.telegram.desktop-symbolic.svg"
    "2b67ee19839dbbb9f57f2d7433fd6dc1059634d6d081c5e4c422c14f53fcfcc7;$HOME/.local/share/icons/hicolor/symbolic/apps/org.telegram.desktop-attention-symbolic.svg"
    "efa1439bd60b58db7b755f5d21be854ea686a0e1e2f1aa6e43bf35c083ee72fc;$HOME/.local/share/icons/hicolor/symbolic/apps/org.telegram.desktop-mute-symbolic.svg"
  )

  [ -L "$launcher" ] && [ -x "$launcher" ] || return 1
  case "$(readlink "$launcher")" in
    "$namespace"/*) ;;
    *) return 1 ;;
  esac
  resolved="$(readlink -f -- "$launcher")" || return 1
  [ -f "$policy" ] && [ ! -L "$policy" ] || return 1
  [ "$(wc -l <"$policy")" -eq 3 ] || return 1
  [ "$(grep -Fxc "$marker" "$policy")" -eq 1 ] || return 1
  [ "$(grep -Fxc "$launcher" "$policy")" -eq 1 ] || return 1
  [ "$(grep -Fxc "$resolved" "$policy")" -eq 1 ] || return 1

  if [ "$GUI_ENABLED" -eq 1 ]; then
    [ -f "$desktop_entry" ] && [ ! -L "$desktop_entry" ] || return 1
    cmp -s "$REPO_ROOT/templates/desktop/org.telegram.desktop.desktop" "$desktop_entry" || return 1
    [ ! -e "$HOME/.local/share/applications/telegram.desktop" ] &&
      [ ! -L "$HOME/.local/share/applications/telegram.desktop" ] || return 1
    for row in "${icon_assets[@]}"; do
      IFS=';' read -r expected asset <<<"$row"
      [ -f "$asset" ] && [ ! -L "$asset" ] || return 1
      actual="$(rldyour::sha256_file "$asset")" || return 1
      [ "$actual" = "$expected" ] || return 1
    done
    for candidate in \
      "$HOME/.local/share/applications"/org.telegram.desktop._*.desktop \
      "$HOME/.local/share/dbus-1/services"/org.telegram.desktop._*.service; do
      [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || return 1
    done
    for candidate in "$HOME/.local/share/applications"/userapp-*.desktop; do
      [ -e "$candidate" ] || [ -L "$candidate" ] || continue
      if grep -Eq '^Exec=(.*/)?telegram-desktop( |$)' "$candidate" 2>/dev/null; then
        return 1
      fi
    done
    if command -v xdg-mime >/dev/null 2>&1; then
      [ "$(xdg-mime query default x-scheme-handler/tg)" = "$desktop_id" ] || return 1
      [ "$(xdg-mime query default x-scheme-handler/tonsite)" = "$desktop_id" ] || return 1
    fi
  fi
}

STRICT=0
PROFILE="${RLDYOUR_PROFILE:-server}"
GUI_ENABLED="${RLDYOUR_GUI_ENABLED:-0}"

rldyour::ubuntu_verify::chrome_contract_fingerprint() {
  # python-surface: verifier-chrome-trust
  /usr/bin/python3 -I "$SCRIPT_DIR/../ci/shell_contract.py" chrome-runtime \
    --contract /usr/local/share/rldyour-bootstrap/rldyour-contract.json \
    --require-root-owned-contract \
    --source /etc/apt/sources.list --source /etc/apt/sources.list.d |
    jq -er 'select(.schema == "rldyour.shell-contract/v1" and .operation == "chrome-runtime") | .result.fingerprint'
}

DOCKER_MODE="${RLDYOUR_DOCKER_MODE:-rootful}"
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --help)
      echo "Usage: scripts/ubuntu/verify.sh [--strict]"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

rldyour::ensure_path
rldyour::section "Verify Ubuntu $PROFILE profile"
rldyour::ubuntu_verify::tool_host_provenance
rldyour::ubuntu_verify::herdr_provenance

# Every command this bootstrap publishes on every Ubuntu profile. A tool that is
# installed but never verified is a tool whose failed install is invisible --
# the defect this repository already closed once for cmake-language-server and
# which had quietly reopened for eleven more.
required_cmds=(
  git curl node bun uv python3 shellcheck shfmt clangd
  pyright pyright-langserver basedpyright ruff ty semgrep
  tsc vtsls yaml-language-server bash-language-server docker-langserver
  vscode-html-language-server vscode-css-language-server vscode-json-language-server taplo
  gh-actions-language-server ansible-language-server
  biome oxlint markdownlint-cli2 prettier
  starship atuin carapace
  cmake-language-server
  codex claude grok cx cl gk
)
for cmd in "${required_cmds[@]}"; do
  rldyour::require_cmd "$cmd" required
done
[ "$(node --version 2>/dev/null | head -n 1)" = "v24.19.0" ] || {
  rldyour::log "missing" "Node.js exact managed Ubuntu version 24.19.0"
  exit 1
}
[ "$(bun --version 2>/dev/null | head -n 1)" = "1.3.14" ] || {
  rldyour::log "missing" "Bun exact managed Ubuntu version 1.3.14"
  exit 1
}
uv --version 2>/dev/null | head -n 1 | grep -Eq '^uv 0\.12\.4([[:space:]]|$)' || {
  rldyour::log "missing" "uv exact managed Ubuntu version 0.12.4"
  exit 1
}
rldyour::verify_terminal_environment

if [ "$PROFILE" != "server" ]; then
  # Go and Rust are desktop/desktop-builds language-server hosts. The server
  # profile is `container-execution-only`, so their absence there is the policy.
  for cmd in go gopls rustc cargo rust-analyzer dart; do
    rldyour::require_cmd "$cmd" required
  done
  # Pinned source-analysis tools: the four CI-parity scanners, the Markdown
  # language server, the git pager that ensure_git_delta_config configures,
  # the structured YAML/AST utilities, and the four interactive tools the
  # zsh template binds aliases to. Every link published by a
  # PINNED_SOURCE_TOOLS row is verified on both profile branches; the pinned
  # tools install on every profile, so a tool missing here is a tool the
  # shell would silently do without.
  for cmd in gitleaks osv-scanner actionlint hadolint markdown-oxide delta yq ast-grep just age age-keygen \
    eza lazygit difft jaq; do
    rldyour::require_cmd "$cmd" required
  done
  # User-selected desktop tools (herdr, telegram). Installed by install_user_tools
  # using the same managed-symlink + receipt contract as pinned source tools; a
  # failed install must not stay invisible.
  rldyour::require_cmd herdr required
  if [ "$GUI_ENABLED" -eq 1 ]; then
    case "$(uname -m)" in
      x86_64|amd64)
        rldyour::require_cmd telegram-desktop required
        rldyour::ubuntu_verify::telegram_policy || {
          rldyour::log "missing" "Telegram updater isolation and XCB launcher contract"
          exit 1
        }
        ;;
      *) rldyour::log "info" "Telegram skipped: upstream publishes no $(uname -m) build" ;;
    esac
  fi
  [ "$(go version 2>/dev/null | awk '{ print $3 }')" = "go1.26.6" ] || {
    rldyour::log "missing" "Go exact managed Ubuntu version 1.26.6"
    exit 1
  }
  [ "$(rustc --version 2>/dev/null | awk '{ print $2 }')" = "1.97.1" ] || {
    rldyour::log "missing" "Rust exact managed Ubuntu version 1.97.1"
    exit 1
  }
  # Dart is the analysis-server host and the `dart-flutter` MCP transport. Both
  # the exact version and the mcp-server subcommand are proven: an SDK that
  # resolves but cannot serve MCP would leave the declared marketplace server
  # broken while verification passed.
  [ "$(dart --version 2>&1 | awk 'NR == 1 { print $4 }')" = "3.13.0" ] || {
    rldyour::log "missing" "Dart exact managed Ubuntu version 3.13.0"
    exit 1
  }
  dart mcp-server --version >/dev/null 2>&1 || {
    rldyour::log "missing" "'dart mcp-server' transport for the dart-flutter MCP server"
    exit 1
  }
  rldyour::observe_dart_telemetry_config
  if [ "$PROFILE" = "desktop" ]; then
    [ "$DOCKER_MODE" = "none" ] || { rldyour::log "error" "desktop Docker mode must be none"; exit 1; }
    if command -v docker >/dev/null 2>&1; then
      rldyour::log "warn" "unmanaged Docker is present; this desktop bootstrap neither uses nor removes it"
    else
      rldyour::log "ok" "desktop policy: Docker is absent"
    fi
  elif [ "$PROFILE" = "desktop-builds" ]; then
    [ "$DOCKER_MODE" = "rootful" ] || { rldyour::log "error" "desktop-builds Docker mode must be rootful"; exit 1; }
    command -v docker >/dev/null 2>&1 || { rldyour::log "missing" "docker is required for the desktop-builds profile"; exit 1; }
    rldyour::log "ok" "desktop-builds policy: Docker is present"
  fi
  if [ "$GUI_ENABLED" -eq 1 ]; then
    command -v google-chrome-stable >/dev/null 2>&1 || { rldyour::log "missing" "Google Chrome stable"; exit 1; }
    command -v rustdesk >/dev/null 2>&1 || { rldyour::log "missing" "RustDesk"; exit 1; }
    # The contract owns the expected fingerprint and the apt-source check; the
    # shared primitive owns key identity. Both lines of work are kept: the
    # checkpoint's contract-derived expectation, and main's repaired identity
    # check, which rejects a keyring carrying a second primary key.
    #
    # The `gpg --show-keys | awk` that used to follow was the #62 defect: its
    # escaped quotes reached awk verbatim inside a double-quoted command
    # substitution, so under `pipefail` the verifier aborted before checking
    # anything. chrome_key_trusted supersedes it and chrome_fingerprint_set_valid
    # with it -- that helper counted matching fingerprint lines, which accepts a
    # keyring whose *subkey* matches.
    chrome_expected_fingerprint="$(rldyour::ubuntu_verify::chrome_contract_fingerprint)" || {
      rldyour::log "missing" "valid Chrome source and trust contract"; exit 1;
    }
    rldyour::ubuntu_verify::chrome_key_trusted \
      /etc/apt/keyrings/rldyour-google-chrome.asc "$chrome_expected_fingerprint" || {
      rldyour::log "missing" "verified Google Chrome signing key"; exit 1;
    }
    if command -v firefox >/dev/null 2>&1 || { command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; }; then
      rldyour::log "missing" "Firefox must be absent from the Ubuntu GUI profile"
      exit 1
    fi
  fi
else
  rldyour::require_cmd herdr required
  for cmd in go gopls rustc cargo rust-analyzer dart; do
    rldyour::require_cmd "$cmd" required
  done
  for cmd in gitleaks osv-scanner actionlint hadolint markdown-oxide delta yq ast-grep just age age-keygen \
    eza lazygit difft jaq; do
    rldyour::require_cmd "$cmd" required
  done
  [ "$(go version 2>/dev/null | awk '{ print $3 }')" = "go1.26.6" ] || {
    rldyour::log "missing" "Go exact managed Ubuntu version 1.26.6"; exit 1;
  }
  [ "$(rustc --version 2>/dev/null | awk '{ print $2 }')" = "1.97.1" ] || {
    rldyour::log "missing" "Rust exact managed Ubuntu version 1.97.1"; exit 1;
  }
  [ "$(dart --version 2>&1 | awk 'NR == 1 { print $4 }')" = "3.13.0" ] || {
    rldyour::log "missing" "Dart exact managed Ubuntu version 3.13.0"; exit 1;
  }
  dart mcp-server --version >/dev/null 2>&1 || {
    rldyour::log "missing" "'dart mcp-server' transport for the dart-flutter MCP server"; exit 1;
  }
  rldyour::observe_dart_telemetry_config
  args=(--docker-mode "$DOCKER_MODE")
  [ "${RLDYOUR_SERVER_ENABLE_UFW:-0}" -eq 1 ] && args+=(--expect-ufw)
  [ "${RLDYOUR_SERVER_HARDEN_SSH:-0}" -eq 1 ] && args+=(--expect-ssh-hardening)
  [ "${RLDYOUR_SERVER_ENABLE_FAIL2BAN:-0}" -eq 1 ] && args+=(--expect-fail2ban)
  bash "$SCRIPT_DIR/verify-server.sh" "${args[@]}"
fi

# A device receipt written by a previous apply must still describe this device.
# device_integrity.py re-collects the state and compares it exactly, which is a
# different question from the one the checks above answer: they ask whether each
# declared thing is present and correct now, it asks whether anything changed
# since the state was recorded. A device that has never been applied by this
# repository has no receipt, and that is not a verification failure -- only a
# receipt that no longer matches is.
if [ "$STRICT" -eq 1 ]; then
  receipt="$HOME/.local/share/rldyour/device-receipt.json"
  if [ -f "$receipt" ]; then
    python3 "$REPO_ROOT/scripts/device_integrity.py" verify --receipt "$receipt" || {
      rldyour::log "missing" "device receipt no longer describes this device"
      exit 1
    }
    rldyour::log "ok" "device receipt verified"
  else
    rldyour::log "info" "no device receipt yet; apply writes one after strict verification"
  fi
fi

[ "$STRICT" -eq 0 ] || rldyour::log "ok" "strict Ubuntu verification passed"
