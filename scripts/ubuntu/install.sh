#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=server.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/server.sh"

RLDYOUR_DRY_RUN="${RLDYOUR_DRY_RUN:-1}"
PROFILE="${RLDYOUR_PROFILE:-server}"
SKIP_SYSTEM="${RLDYOUR_SKIP_SYSTEM:-0}"
SKIP_AI="${RLDYOUR_SKIP_AI:-0}"
SKIP_LSPS="${RLDYOUR_SKIP_LSPS:-0}"
SKIP_CHECKS="${RLDYOUR_SKIP_CHECKS:-0}"
GUI_ENABLED="${RLDYOUR_GUI_ENABLED:-0}"
DOCKER_MODE="${RLDYOUR_DOCKER_MODE:-rootful}"
LOCAL_EXECUTION_POLICY="${RLDYOUR_LOCAL_EXECUTION_POLICY:-server-build-runtime}"
HARDEN_SSH="${RLDYOUR_HARDEN_SSH:-0}"
ENABLE_UFW="${RLDYOUR_ENABLE_UFW:-0}"
WITH_FAIL2BAN="${RLDYOUR_WITH_FAIL2BAN:-0}"

CLAUDE_CODE_VERSION="2.1.206"
CODEX_VERSION="0.144.1"
OPENCODE_VERSION="1.17.18"
MIMOCODE_VERSION="0.1.5"
ANTIGRAVITY_VERSION="1.1.1"
ANTIGRAVITY_ARTIFACT_URL_X64="https://storage.googleapis.com/antigravity-public/antigravity-cli/1.1.1-6269367663591424/linux-x64/cli_linux_x64.tar.gz"
ANTIGRAVITY_ARTIFACT_SHA512_X64="fcebad8247e0453097e2b26d839371c88df040e6fb18fac3fd8072851194739cf4624041469b57f529bc9c2e1140a6ce4cd5e7144e64e6efc5605a9f10a862b7"
ANTIGRAVITY_ARTIFACT_URL_ARM64="https://storage.googleapis.com/antigravity-public/antigravity-cli/1.1.1-6269367663591424/linux-arm/cli_linux_arm64.tar.gz"
ANTIGRAVITY_ARTIFACT_SHA512_ARM64="6d3d89c7b88d4e22e2eef937ce731345299657ac7a14236a93a5f9dce67eb7251845ccc9804b0ab1881125ff6165311ce73c6933c1376ec3b966659a94753e60"
CLAUDE_DESKTOP_KEY_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE" # gitleaks:allow - public Anthropic apt signing-key fingerprint
ZCODE_VERSION="3.3.3"
NODE_VERSION="24.18.0"
NODE_SHA256_X64="55aa7153f9d88f28d765fcdad5ae6945b5c0f98a36881703817e4c450fa76742"
NODE_SHA256_ARM64="58c9520501f6ae2b52d5b210444e24b9d0c029a58c5011b797bc1fe7105886f6"
UV_VERSION="0.11.28"
UV_SHA256_X64="e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224"
UV_SHA256_ARM64="03e9fe0a81b0718d0bc84625de3885df6cc3f89a8b6af6121d6b9f6113fb6533"
BUN_VERSION="1.3.14"
BUN_SHA256_X64="951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f"
BUN_SHA256_ARM64="a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b"

APT_SOURCE_PACKAGES=(
  ca-certificates curl gpg gnupg git jq python3 python3-venv python3-pip
  shellcheck shfmt clangd zsh unzip xz-utils wget zip lsb-release yamllint
  fd-find bat fzf zoxide tmux btop duf hexyl gh ripgrep httpie miller
)

# Runtime libraries/fonts from the CloakBrowser v0.4.10 upstream Linux image.
# They support the mandatory downloaded Chromium binary; they are not a stock
# browser or a project runtime.
APT_CLOAK_RUNTIME_PACKAGES=(
  libnss3 libnspr4 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64
  libdbus-1-3 libdrm2 libxkbcommon0 libatspi2.0-0t64 libxcomposite1
  libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0
  libcairo2 libasound2t64 libx11-xcb1 libfontconfig1 libfreetype6 libx11-6
  libxcb1 libxext6 libxshmfence1 libglib2.0-0t64 libgtk-3-0t64
  libpangocairo-1.0-0 libcairo-gobject2 libgdk-pixbuf-2.0-0
  libxss1 libxtst6 fonts-liberation fonts-noto-color-emoji
  fonts-unifont fonts-freefont-ttf fonts-ipafont-gothic
  fonts-wqy-zenhei fonts-tlwg-loma-otf
)

BUN_LSP_PACKAGES=(
  typescript
  "@vtsls/language-server"
  yaml-language-server
  bash-language-server
  dockerfile-language-server-nodejs
  vscode-langservers-extracted
  "@taplo/cli"
  gh-actions-language-server
  biome
  oxlint
  markdownlint-cli2
  prettier
  "@ansible/language-server"
)

PYTHON_SOURCE_TOOLS=(pyright ruff ty cmake-language-server basedpyright semgrep)

usage() {
  cat <<'EOF'
Usage: scripts/ubuntu/install.sh

Internal Ubuntu 24.04/26.04 installer. Use scripts/bootstrap.sh so desktop,
server, GUI, Docker, hardening, and verification settings are composed safely.
EOF
}

rldyour::ubuntu::as_root() {
  if [ "$EUID" -eq 0 ]; then
    rldyour::run "$@"
  elif [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    # A plan only renders the future privilege boundary; sudo need not exist.
    rldyour::run sudo "$@"
  elif command -v sudo >/dev/null 2>&1; then
    rldyour::run sudo "$@"
  else
    rldyour::log "error" "Ubuntu apply requires root or sudo"
    return 1
  fi
}

apt_install() {
  rldyour::ubuntu::as_root env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends --no-upgrade "$@"
}

is_supported_ubuntu() {
  [ "$(uname -s)" = "Linux" ] && [ -r /etc/os-release ] || return 1
  (
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] && { [ "${VERSION_ID:-}" = "24.04" ] || [ "${VERSION_ID:-}" = "26.04" ]; }
  )
}

validate_target() {
  case "$PROFILE:$LOCAL_EXECUTION_POLICY:$DOCKER_MODE:$GUI_ENABLED" in
    desktop:source-lsp-only:none:0|desktop:source-lsp-only:none:1) ;;
    server:server-build-runtime:none:0|server:server-build-runtime:rootful:0|server:server-build-runtime:rootless:0) ;;
    *)
      rldyour::log "error" "invalid Ubuntu composition: profile=$PROFILE policy=$LOCAL_EXECUTION_POLICY docker=$DOCKER_MODE gui=$GUI_ENABLED"
      return 2
      ;;
  esac
  if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && ! is_supported_ubuntu; then
    rldyour::log "error" "apply is supported only on Ubuntu 24.04 or 26.04"
    return 2
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && [ "$EUID" -eq 0 ]; then
    rldyour::log "error" "full Ubuntu bootstrap must run as the non-root developer account that will own AI configs and the CloakBrowser user service"
    rldyour::log "error" "create/login to that account with sudo, then rerun; use scripts/ubuntu/server.sh separately for root-only baseline work"
    return 2
  fi
}

install_apt_baseline() {
  rldyour::section "Install Ubuntu package baseline"
  rldyour::ubuntu::as_root apt-get update
  apt_install software-properties-common \
    "${APT_SOURCE_PACKAGES[@]}" "${APT_CLOAK_RUNTIME_PACKAGES[@]}"
  if [ "$PROFILE" = "server" ]; then
    apt_install build-essential pkg-config
  fi
}

ensure_node_link() {
  local name="$1" source="$2" destination current
  destination="$HOME/.local/bin/$name"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -L "$destination" ]; then
      rldyour::log "error" "unmanaged Node launcher exists; preserved: $destination"
      return 1
    fi
    current="$(readlink "$destination")"
    case "$current" in
      "$HOME/.local/share/rldyour/node/"*) ;;
      *) rldyour::log "error" "unmanaged Node symlink exists; preserved: $destination"; return 1 ;;
    esac
  fi
  ln -sfn "$source" "$destination"
}

rldyour::ubuntu::preflight_managed_link() {
  local name=$1 namespace=$2 current
  local destination="$HOME/.local/bin/$name"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -L "$destination" ] || {
      rldyour::log "error" "unmanaged launcher exists; preserved: $destination"
      return 1
    }
    current=$(readlink "$destination")
    case "$current" in
      "$namespace"/*) ;;
      *)
        rldyour::log "error" "unmanaged launcher symlink exists; preserved: $destination"
        return 1
        ;;
    esac
  fi
}

ensure_managed_tool_link() {
  local name=$1 source=$2 namespace=$3 destination current
  destination="$HOME/.local/bin/$name"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -L "$destination" ]; then
      rldyour::log "error" "unmanaged tool launcher exists; preserved: $destination"
      return 1
    fi
    current="$(readlink "$destination")"
    case "$current" in
      "$namespace"/*) ;;
      *) rldyour::log "error" "unmanaged tool symlink exists; preserved: $destination"; return 1 ;;
    esac
  fi
  ln -sfn "$source" "$destination"
}

rldyour::ubuntu::write_runtime_receipt() {
  local root=$1 runtime=$2 version=$3 archive_sha256=$4
  local relative key
  shift 4
  {
    printf '%s\n' '# Managed by macos-ubuntu-bootstrap: ubuntu-runtime-v1'
    printf 'runtime=%s\nversion=%s\narchive_sha256=%s\n' "$runtime" "$version" "$archive_sha256"
    for relative in "$@"; do
      [ -x "$root/$relative" ] || return 1
      key=${relative//\//_}
      printf 'sha256_%s=%s\n' "$key" "$(rldyour::sha256_file "$root/$relative")"
    done
  } >"$root/.rldyour-runtime-receipt"
  chmod 0600 "$root/.rldyour-runtime-receipt"
}

rldyour::ubuntu::validate_runtime_receipt() {
  local root=$1 runtime=$2 version=$3 archive_sha256=$4
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

ensure_node() {
  rldyour::section "Ensure Node.js LTS ${NODE_VERSION}"
  local arch sha filename url archive stage destination command_name parent
  case "$(uname -m)" in
    x86_64|amd64) arch="x64"; sha="$NODE_SHA256_X64" ;;
    aarch64|arm64) arch="arm64"; sha="$NODE_SHA256_ARM64" ;;
    *) rldyour::log "error" "Node.js ${NODE_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  filename="node-v${NODE_VERSION}-linux-${arch}.tar.xz"
  url="https://nodejs.org/dist/v${NODE_VERSION}/${filename}"
  destination="$HOME/.local/share/rldyour/node/v${NODE_VERSION}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed Node.js ${NODE_VERSION} from the tracked SHA-256 artifact; external PATH binaries are preserved but never trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" node "$NODE_VERSION" "$sha" \
      bin/node bin/npm bin/npx bin/corepack ||
      [ "$("$destination/bin/node" --version 2>/dev/null)" != "v${NODE_VERSION}" ]; then
      rldyour::log "error" "unmanaged or tampered Node destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.node-${NODE_VERSION}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    rldyour::download_verified_file "$url" "$sha" "$archive" || return 1
    tar -xJf "$archive" --strip-components=1 -C "$stage"
    [ "$("$stage/bin/node" --version 2>/dev/null)" = "v${NODE_VERSION}" ] || {
      rldyour::log "error" "staged Node.js artifact did not report v${NODE_VERSION}"
      return 1
    }
    rldyour::ubuntu::write_runtime_receipt \
      "$stage" node "$NODE_VERSION" "$sha" \
      bin/node bin/npm bin/npx bin/corepack || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  for command_name in node npm npx corepack; do
    rldyour::ubuntu::preflight_managed_link "$command_name" "$HOME/.local/share/rldyour/node"
  done
  for command_name in node npm npx corepack; do
    ensure_node_link "$command_name" "$destination/bin/$command_name"
  done
  rldyour::ensure_path
  [ "$("$HOME/.local/bin/node" --version)" = "v${NODE_VERSION}" ] || {
    rldyour::log "error" "managed Node.js launcher did not resolve to ${NODE_VERSION}"
    return 1
  }
}

ensure_uv() {
  local arch sha triple archive stage destination url parent
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64"; sha="$UV_SHA256_X64" ;;
    aarch64|arm64) arch="aarch64"; sha="$UV_SHA256_ARM64" ;;
    *) rldyour::log "error" "uv ${UV_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  triple="${arch}-unknown-linux-gnu"
  destination="$HOME/.local/share/rldyour/uv/${UV_VERSION}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed uv ${UV_VERSION} from the tracked SHA-256 artifact; external PATH binaries are not trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" uv "$UV_VERSION" "$sha" uv uvx ||
      [ "$("$destination/uv" --version 2>/dev/null | awk '{ print $2 }')" != "$UV_VERSION" ]; then
      rldyour::log "error" "unmanaged or tampered uv destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.uv-${UV_VERSION}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    url="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${triple}.tar.gz"
    rldyour::download_verified_file "$url" "$sha" "$archive"
    tar -xzf "$archive" --strip-components=1 -C "$stage"
    [ "$("$stage/uv" --version 2>/dev/null | awk '{ print $2 }')" = "$UV_VERSION" ] || {
      rldyour::log "error" "staged uv artifact did not report ${UV_VERSION}"
      return 1
    }
    rldyour::ubuntu::write_runtime_receipt "$stage" uv "$UV_VERSION" "$sha" uv uvx || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  rldyour::ubuntu::preflight_managed_link uv "$HOME/.local/share/rldyour/uv"
  rldyour::ubuntu::preflight_managed_link uvx "$HOME/.local/share/rldyour/uv"
  ensure_managed_tool_link uv "$destination/uv" "$HOME/.local/share/rldyour/uv"
  ensure_managed_tool_link uvx "$destination/uvx" "$HOME/.local/share/rldyour/uv"
  "$HOME/.local/bin/uv" --version | grep -Fq "uv ${UV_VERSION}"
}

ensure_bun() {
  local arch sha archive stage destination url parent extract_dir
  case "$(uname -m)" in
    x86_64|amd64) arch="x64"; sha="$BUN_SHA256_X64" ;;
    aarch64|arm64) arch="aarch64"; sha="$BUN_SHA256_ARM64" ;;
    *) rldyour::log "error" "Bun ${BUN_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  destination="$HOME/.local/share/rldyour/bun/${BUN_VERSION}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed Bun ${BUN_VERSION} from the tracked SHA-256 artifact; external PATH binaries are not trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" bun "$BUN_VERSION" "$sha" bun ||
      [ "$("$destination/bun" --version 2>/dev/null)" != "$BUN_VERSION" ]; then
      rldyour::log "error" "unmanaged or tampered Bun destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.bun-${BUN_VERSION}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    url="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${arch}.zip"
    rldyour::download_verified_file "$url" "$sha" "$archive"
    extract_dir="$stage/extracted"
    mkdir "$extract_dir"
    unzip -q "$archive" -d "$extract_dir"
    mv "$extract_dir/bun-linux-${arch}/bun" "$stage/bun"
    rm -rf "$extract_dir"
    chmod 0755 "$stage/bun"
    [ "$("$stage/bun" --version 2>/dev/null)" = "$BUN_VERSION" ] || {
      rldyour::log "error" "staged Bun artifact did not report ${BUN_VERSION}"
      return 1
    }
    rldyour::ubuntu::write_runtime_receipt "$stage" bun "$BUN_VERSION" "$sha" bun || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  rldyour::ubuntu::preflight_managed_link bun "$HOME/.local/share/rldyour/bun"
  rldyour::ubuntu::preflight_managed_link bunx "$HOME/.local/share/rldyour/bun"
  ensure_managed_tool_link bun "$destination/bun" "$HOME/.local/share/rldyour/bun"
  ensure_managed_tool_link bunx "$destination/bun" "$HOME/.local/share/rldyour/bun"
  [ "$("$HOME/.local/bin/bun" --version)" = "$BUN_VERSION" ]
}

install_python_source_tools() {
  rldyour::section "Install isolated Python source-analysis tools"
  local package
  for package in "${PYTHON_SOURCE_TOOLS[@]}"; do
    if uv tool list 2>/dev/null | grep -Eq "^${package}([[:space:]]|$)"; then
      rldyour::log "ok" "preserving installed uv tool: ${package}"
    else
      rldyour::run uv tool install "$package"
    fi
  done
}

install_bun_lsps() {
  rldyour::section "Install registry-backed language servers and source checks"
  local package
  for package in "${BUN_LSP_PACKAGES[@]}"; do
    if bun pm ls -g 2>/dev/null | grep -Fq "${package}@"; then
      rldyour::log "ok" "preserving installed Bun source tool: ${package}"
    else
      rldyour::run bun add -g --ignore-scripts "$package"
    fi
  done
}

install_ai_runtimes() {
  rldyour::section "Install exact AI CLI versions"
  rldyour::install_ai_cli_bundle \
    "$CLAUDE_CODE_VERSION" "$CODEX_VERSION" \
    "$OPENCODE_VERSION" "$MIMOCODE_VERSION"
  local agy_url agy_sha512
  case "$(uname -m)" in
    x86_64|amd64)
      agy_url="$ANTIGRAVITY_ARTIFACT_URL_X64"
      agy_sha512="$ANTIGRAVITY_ARTIFACT_SHA512_X64"
      ;;
    aarch64|arm64)
      agy_url="$ANTIGRAVITY_ARTIFACT_URL_ARM64"
      agy_sha512="$ANTIGRAVITY_ARTIFACT_SHA512_ARM64"
      ;;
    *)
      rldyour::log "error" "Antigravity ${ANTIGRAVITY_VERSION} has no tracked artifact for $(uname -m)"
      return 1
      ;;
  esac
  rldyour::install_antigravity_artifact \
    "$ANTIGRAVITY_VERSION" "$agy_url" "$agy_sha512"
}

rldyour::ubuntu::single_primary_key_fingerprint() {
  gpg --batch --show-keys --with-colons "$1" | awk -F: '
    $1 == "pub" { primary_count++; awaiting_primary_fpr=1; next }
    $1 == "fpr" && awaiting_primary_fpr { primary_fpr=toupper($10); awaiting_primary_fpr=0 }
    END {
      if (primary_count != 1 || primary_fpr == "") exit 1
      print primary_fpr
    }
  '
}

install_claude_desktop() {
  if dpkg-query -W -f='${Status}' claude-desktop 2>/dev/null | grep -Fq "install ok installed"; then
    rldyour::log "ok" "Claude Desktop already installed"
    return 0
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify Anthropic apt key fingerprint and install claude-desktop"
    return 0
  fi
  local key_tmp source_tmp fingerprint existing_fingerprint key_path source_path
  key_tmp="$(mktemp)"; source_tmp="$(mktemp)"
  trap 'rm -f "$key_tmp" "$source_tmp"' RETURN
  key_path="/usr/share/keyrings/claude-desktop-archive-keyring.asc"
  source_path="/etc/apt/sources.list.d/claude-desktop.list"
  curl -fsSL https://downloads.claude.ai/claude-desktop/key.asc -o "$key_tmp"
  fingerprint="$(rldyour::ubuntu::single_primary_key_fingerprint "$key_tmp")" || {
    rldyour::log "error" "Claude Desktop key bundle must contain exactly one primary key"
    return 1
  }
  [ "$fingerprint" = "$CLAUDE_DESKTOP_KEY_FINGERPRINT" ] || {
    rm -f "$key_tmp" "$source_tmp"
    rldyour::log "error" "Claude Desktop signing-key fingerprint mismatch"
    return 1
  }
  printf '%s\n' "deb [signed-by=$key_path] https://downloads.claude.ai/claude-desktop/apt/stable stable main" >"$source_tmp"
  if [ -L "$key_path" ] || { [ -e "$key_path" ] && [ ! -f "$key_path" ]; }; then
    rldyour::log "error" "Claude Desktop apt key path is not a regular file; preserved: $key_path"
    return 1
  elif [ -f "$key_path" ]; then
    existing_fingerprint="$(rldyour::ubuntu::single_primary_key_fingerprint "$key_path")" || {
      rldyour::log "error" "existing Claude Desktop key bundle contains multiple or invalid primary keys"
      return 1
    }
    [ "$existing_fingerprint" = "$CLAUDE_DESKTOP_KEY_FINGERPRINT" ] || {
      rldyour::log "error" "existing Claude Desktop apt key fingerprint differs; preserved: $key_path"
      return 1
    }
  else
    rldyour::ubuntu::as_root install -m 0644 "$key_tmp" "$key_path"
  fi
  if [ -L "$source_path" ] || { [ -e "$source_path" ] && [ ! -f "$source_path" ]; }; then
    rldyour::log "error" "Claude Desktop apt definition is not a regular file; preserved: $source_path"
    return 1
  elif [ -f "$source_path" ]; then
    rldyour::ubuntu::as_root cmp -s "$source_tmp" "$source_path" || {
      rldyour::log "error" "unmanaged Claude Desktop apt definition differs; preserved: $source_path"
      return 1
    }
  else
    rldyour::ubuntu::as_root install -m 0644 "$source_tmp" "$source_path"
  fi
  rldyour::ubuntu::as_root apt-get update
  rldyour::ubuntu::as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y claude-desktop
  rm -f "$key_tmp" "$source_tmp"
  trap - RETURN
}

install_zcode_desktop() {
  if [ -z "${RLDYOUR_ZCODE_SHA256:-}" ]; then
    rldyour::log "warn" "ZCode ${ZCODE_VERSION} is not auto-installed: upstream publishes no checksum manifest. Set a separately verified RLDYOUR_ZCODE_SHA256 or use scripts/auth-handoff.sh."
    return 0
  fi
  local arch url deb
  case "$(dpkg --print-architecture)" in
    amd64) arch="x64" ;;
    arm64) arch="arm64" ;;
    *) rldyour::log "warn" "ZCode has no tracked package for this architecture"; return 0 ;;
  esac
  url="https://cdn-zcode.z.ai/zcode/electron/releases/${ZCODE_VERSION}/ZCode-${ZCODE_VERSION}-linux-${arch}.deb"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify supplied ZCode SHA-256 and install ${url##*/}"
    return 0
  fi
  deb="$(mktemp --suffix=.deb)"
  curl -fsSL "$url" -o "$deb"
  printf '%s  %s\n' "$RLDYOUR_ZCODE_SHA256" "$deb" | sha256sum --check --status || {
    rm -f "$deb"
    rldyour::log "error" "ZCode SHA-256 verification failed"
    return 1
  }
  rldyour::ubuntu::as_root apt-get install -y "$deb"
  rm -f "$deb"
}

install_gui_apps() {
  if [ "$PROFILE" != "desktop" ] || [ "$GUI_ENABLED" -ne 1 ]; then
    rldyour::log "info" "GUI application layer disabled"
    return 0
  fi
  rldyour::section "Install verified Ubuntu GUI applications"
  apt_install fonts-jetbrains-mono || rldyour::log "warn" "fonts-jetbrains-mono unavailable"
  install_claude_desktop
  install_zcode_desktop
  rldyour::log "info" "ChatGPT, Codex, and cmux have no supported Linux desktop build; managed CLIs are installed."
}

run_server_layer() {
  local resolved_user=""
  [ "$PROFILE" = "server" ] || return 0
  if [ "$SKIP_SYSTEM" -eq 1 ]; then
    return 0
  fi
  if ! is_supported_ubuntu; then
    if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] Ubuntu server layer: Docker=$DOCKER_MODE, UFW=$ENABLE_UFW, SSH hardening=$HARDEN_SSH, Fail2ban=$WITH_FAIL2BAN"
      return 0
    fi
    rldyour::log "error" "server layer requires Ubuntu 24.04 or 26.04"
    return 2
  fi
  local -a args=(--docker-mode "$DOCKER_MODE" --skip-verify)
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then args+=(--plan); else args+=(--apply); fi
  [ "$ENABLE_UFW" -eq 1 ] && args+=(--enable-ufw)
  if [ "$HARDEN_SSH" -eq 1 ]; then
    resolved_user=$(rldyour::ubuntu_server::resolve_ssh_user "${RLDYOUR_SERVER_SSH_USER:-}")
    export RLDYOUR_SERVER_SSH_USER=$resolved_user
    args+=(--harden-ssh --ssh-user "$resolved_user")
  fi
  [ "$WITH_FAIL2BAN" -eq 1 ] && args+=(--enable-fail2ban)
  rldyour::ubuntu_server::main "${args[@]}"
}

verify_apply() {
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "plan complete; verification runs only after apply"
  elif [ "$SKIP_CHECKS" -eq 0 ]; then
    RLDYOUR_PROFILE="$PROFILE" RLDYOUR_GUI_ENABLED="$GUI_ENABLED" \
      RLDYOUR_DOCKER_MODE="$DOCKER_MODE" RLDYOUR_BROWSER_REQUIRED=1 \
      RLDYOUR_SERVER_ENABLE_UFW="$ENABLE_UFW" \
      RLDYOUR_SERVER_HARDEN_SSH="$HARDEN_SSH" \
      RLDYOUR_SERVER_ENABLE_FAIL2BAN="$WITH_FAIL2BAN" \
      bash "$SCRIPT_DIR/verify.sh" --strict
  fi
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

rldyour::assert_root "$REPO_ROOT"
rldyour::ensure_path
validate_target
rldyour::section "macos-ubuntu-bootstrap (Ubuntu) installer"
rldyour::log "info" "mode: $([ "$RLDYOUR_DRY_RUN" -eq 1 ] && echo dry-run || echo apply); profile: $PROFILE; gui: $GUI_ENABLED; docker: $DOCKER_MODE; policy: $LOCAL_EXECUTION_POLICY"

if [ "$SKIP_SYSTEM" -eq 0 ]; then
  install_apt_baseline
  ensure_node
  ensure_uv
  ensure_bun
  rldyour::ensure_path
  install_python_source_tools
  rldyour::ensure_git_perf
  rldyour::ensure_git_delta_config
  rldyour::install_terminal_configs "$REPO_ROOT/templates/terminal"
else
  rldyour::log "warn" "system layer skipped by explicit recovery flag"
fi

[ "$SKIP_AI" -eq 1 ] || install_ai_runtimes
[ "$SKIP_LSPS" -eq 1 ] || install_bun_lsps
install_gui_apps
run_server_layer

# Mandatory on desktop, no-GUI desktop, and headless server profiles.
rldyour::install_browser_providers
rldyour::install_rtk
verify_apply
rldyour::log "info" "Run 'bash scripts/auth-handoff.sh' for user-controlled sign-in steps."
