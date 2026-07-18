#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

rldyour::ubuntu_verify::contract_hash() {
  python3 - "$REPO_ROOT/config/rldyour-contract.json" "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    contract = json.load(handle)
print(contract["runtime_support"][sys.argv[2]][sys.argv[3]])
PY
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
  bun_sha=$(rldyour::ubuntu_verify::contract_hash ubuntu_bun_sha256 "$arch")
  node_root="$HOME/.local/share/rldyour/node/v24.18.0"
  uv_root="$HOME/.local/share/rldyour/uv/0.11.28"
  bun_root="$HOME/.local/share/rldyour/bun/1.3.14"

  rldyour::ubuntu_verify::runtime_receipt node 24.18.0 "$node_sha" "$node_root" \
    bin/node bin/npm bin/npx bin/corepack || return 1
  rldyour::ubuntu_verify::runtime_receipt uv 0.11.28 "$uv_sha" "$uv_root" uv uvx || return 1
  rldyour::ubuntu_verify::runtime_receipt bun 1.3.14 "$bun_sha" "$bun_root" bun || return 1
  for name in node npm npx corepack; do
    rldyour::ubuntu_verify::managed_link "$name" "$node_root/bin/$name" || return 1
  done
  rldyour::ubuntu_verify::managed_link uv "$uv_root/uv" || return 1
  rldyour::ubuntu_verify::managed_link uvx "$uv_root/uvx" || return 1
  rldyour::ubuntu_verify::managed_link bun "$bun_root/bun" || return 1
  rldyour::ubuntu_verify::managed_link bunx "$bun_root/bun" || return 1
  rldyour::log "ok" "Ubuntu Node.js, uv, and Bun receipts and managed links verified"
}

STRICT=0
PROFILE="${RLDYOUR_PROFILE:-server}"
GUI_ENABLED="${RLDYOUR_GUI_ENABLED:-0}"
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

required_cmds=(
  git curl node bun uv python3 shellcheck shfmt clangd
  pyright pyright-langserver basedpyright ruff
  tsc vtsls yaml-language-server bash-language-server docker-langserver
  vscode-html-language-server vscode-css-language-server vscode-json-language-server taplo
  claude codex opencode mimo agy rtk
  cloak-chromium cloakbrowser-cdp-health chrome-devtools-mcp playwright-cli
)
for cmd in "${required_cmds[@]}"; do
  rldyour::require_cmd "$cmd" required
done
[ "$(node --version 2>/dev/null | head -n 1)" = "v24.18.0" ] || {
  rldyour::log "missing" "Node.js exact managed Ubuntu version 24.18.0"
  exit 1
}
[ "$(bun --version 2>/dev/null | head -n 1)" = "1.3.14" ] || {
  rldyour::log "missing" "Bun exact managed Ubuntu version 1.3.14"
  exit 1
}
uv --version 2>/dev/null | head -n 1 | grep -Eq '^uv 0\.11\.28([[:space:]]|$)' || {
  rldyour::log "missing" "uv exact managed Ubuntu version 0.11.28"
  exit 1
}
[ "$(claude --version 2>/dev/null | head -n 1)" = "2.1.206 (Claude Code)" ] || {
  rldyour::log "missing" "Claude Code exact managed version 2.1.206"
  exit 1
}
[ "$(codex --version 2>/dev/null | head -n 1)" = "codex-cli 0.144.1" ] || {
  rldyour::log "missing" "Codex exact managed version 0.144.1"
  exit 1
}
[ "$(opencode --version 2>/dev/null | head -n 1)" = "1.17.18" ] || {
  rldyour::log "missing" "OpenCode exact managed version 1.17.18"
  exit 1
}
[ "$(mimo --version 2>/dev/null | head -n 1)" = "0.1.5" ] || {
  rldyour::log "missing" "MiMoCode exact managed version 0.1.5"
  exit 1
}
[ "$(agy --version 2>/dev/null | head -n 1)" = "1.1.1" ] || {
  rldyour::log "missing" "agy exact managed version 1.1.1"
  exit 1
}
rtk --version 2>/dev/null | head -n 1 | grep -Eq '^rtk[[:space:]]+0\.43\.0([[:space:]]|$)' || {
  rldyour::log "missing" "rtk exact managed version 0.43.0"
  exit 1
}
cloakbrowser-cdp-health
chrome-devtools-mcp --version | grep -Fq "1.5.0"
playwright-cli --version | grep -Fq "0.1.17"
"$SCRIPT_DIR/../verify-browser-runtime.sh" --json
rldyour::verify_terminal_environment

if [ "$PROFILE" = "desktop" ]; then
  [ "$DOCKER_MODE" = "none" ] || { rldyour::log "error" "desktop Docker mode must be none"; exit 1; }
  if command -v docker >/dev/null 2>&1; then
    rldyour::log "warn" "unmanaged Docker is present; this desktop bootstrap neither uses nor removes it"
  else
    rldyour::log "ok" "desktop policy: Docker is absent"
  fi
  if [ "$GUI_ENABLED" -eq 1 ]; then
    dpkg-query -W -f='${Status}' claude-desktop 2>/dev/null | grep -Fq "install ok installed" || {
      rldyour::log "missing" "Claude Desktop package"
      exit 1
    }
  fi
else
  args=(--docker-mode "$DOCKER_MODE")
  [ "${RLDYOUR_SERVER_ENABLE_UFW:-0}" -eq 1 ] && args+=(--expect-ufw)
  [ "${RLDYOUR_SERVER_HARDEN_SSH:-0}" -eq 1 ] && args+=(--expect-ssh-hardening)
  [ "${RLDYOUR_SERVER_ENABLE_FAIL2BAN:-0}" -eq 1 ] && args+=(--expect-fail2ban)
  bash "$SCRIPT_DIR/verify-server.sh" "${args[@]}"
fi

[ "$STRICT" -eq 0 ] || rldyour::log "ok" "strict Ubuntu verification passed"
