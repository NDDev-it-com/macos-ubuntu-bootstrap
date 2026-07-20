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
LOCAL_EXECUTION_POLICY="${RLDYOUR_LOCAL_EXECUTION_POLICY:-container-execution-only}"
HARDEN_SSH="${RLDYOUR_HARDEN_SSH:-0}"
ENABLE_UFW="${RLDYOUR_ENABLE_UFW:-0}"
WITH_FAIL2BAN="${RLDYOUR_WITH_FAIL2BAN:-0}"
# Login shell change is explicit opt-in only; never mutated silently.
SET_LOGIN_SHELL="${RLDYOUR_SET_LOGIN_SHELL:-0}"

# One owner per harness (RVR-P1-004): the active harness set is codex and zcode,
# each installed by its dedicated authoritative NDDev module via
# rldyour::install_selected_harnesses. Bootstrap pins no AI CLI versions here.
NODE_VERSION="24.18.0"
NODE_SHA256_X64="55aa7153f9d88f28d765fcdad5ae6945b5c0f98a36881703817e4c450fa76742"
NODE_SHA256_ARM64="58c9520501f6ae2b52d5b210444e24b9d0c029a58c5011b797bc1fe7105886f6"
UV_VERSION="0.11.29"
UV_SHA256_X64="04f8b82f5d47f0512dcd32c67a4a6f16a0ea27c81537c338fd0ad6b23cebe829"
UV_SHA256_ARM64="94500fb064ae3c971a873cba64d94694c50677e0a4dbf78735c80509e7429919"
BUN_VERSION="1.3.14"
BUN_SHA256_X64="951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f"
BUN_SHA256_X64_BASELINE="a063908ae08b7852ca10939bbdc6ceed3ddabce8fb9402dce83d65d73b36e6c7"
BUN_SHA256_ARM64="a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b"
# Prompt/history/completion pillars — parity with the macOS brew baseline
# (starship, atuin, carapace). Installed as pinned standalone artifacts, never
# via apt (stale) or a piped install script. Linux x64 + arm64 tarball SHA-256
# from each project's signed GitHub release checksum files.
STARSHIP_VERSION="1.26.0"
STARSHIP_SHA256_X64="321f0dd7af8340a5f2e6a8fec6538a04f617486f9ec70d878f91c09cd8deef22"
STARSHIP_SHA256_ARM64="dc30189378d2f2e287384e8a692d3f95ad1df64cf0e8c36aa9201516028aed6b"
ATUIN_VERSION="18.17.1"
ATUIN_SHA256_X64="72395cf7ae86b3698c04ba4a331773e7c4f027630bfd2b522bb14d4c80cb2410"
ATUIN_SHA256_ARM64="9412210a9cdd6d0ff7635693e940096d82b368628326d334d27a8ca0ba173b0f"
CARAPACE_VERSION="1.7.3"
CARAPACE_SHA256_X64="35ab52bfe7bdd8296d90c3687660bde80497599badde840ab615d2f421f5f053"
CARAPACE_SHA256_ARM64="b2456cb09d77004db87de2567d6d7588a61ceb4724522c463e2b1c1f87b4d4b9"

APT_SOURCE_PACKAGES=(
  ca-certificates curl gpg gnupg git jq python3 python3-venv
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
    server:container-execution-only:none:0|server:container-execution-only:rootful:0|server:container-execution-only:rootless:0) ;;
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
  # The server profile is a container-execution host: project builds/tests run
  # inside Docker, never on the host. It therefore installs no host build
  # toolchain (build-essential, pkg-config, language SDKs). Docker Engine is
  # provisioned separately by scripts/ubuntu/server.sh.
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
  local arch sha filename url archive stage destination parent
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
  # Node is a pinned runtime only. npm/npx/corepack ship inside the verified
  # tarball (their integrity is recorded in the receipt) but are deliberately
  # NOT published to the managed PATH: uv and bun are the only package managers.
  rldyour::ubuntu::preflight_managed_link node "$HOME/.local/share/rldyour/node"
  ensure_node_link node "$destination/bin/node"
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
    x86_64|amd64)
      # Standard Bun x64 requires AVX2; older CPUs need the baseline build.
      if rldyour::cpu_has_avx2; then
        arch="x64"; sha="$BUN_SHA256_X64"
      else
        arch="x64-baseline"; sha="$BUN_SHA256_X64_BASELINE"
        rldyour::log "info" "AVX2 absent; selecting Bun ${BUN_VERSION} x64-baseline artifact"
      fi
      ;;
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

# Shared installer for a single pinned, content-addressed standalone binary
# (starship/atuin/carapace). Mirrors ensure_uv/ensure_bun: download the tracked
# SHA-256 tarball, stage it, verify the reported version, write a runtime
# receipt, and publish exactly one managed PATH link. External PATH binaries are
# preserved but never trusted; an unmanaged/tampered destination is fail-closed.
rldyour::ubuntu::ensure_standalone_tool() {
  local name=$1 version=$2 url=$3 sha=$4 strip=$5 binrel=$6
  local destination parent archive stage namespace
  namespace="$HOME/.local/share/rldyour/${name}"
  destination="${namespace}/${version}"
  parent="$(dirname "$destination")"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] verify or install managed ${name} ${version} from the tracked SHA-256 artifact; external PATH binaries are not trusted"
    return 0
  fi
  mkdir -p "$HOME/.local/bin" "$parent"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! rldyour::ubuntu::validate_runtime_receipt \
      "$destination" "$name" "$version" "$sha" "$binrel" ||
      ! "$destination/$binrel" --version 2>/dev/null | grep -Fq "$version"; then
      rldyour::log "error" "unmanaged or tampered ${name} destination exists; preserved: $destination"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d "$parent/.${name}-${version}.tmp.XXXXXX")"
    trap 'rm -rf "$archive"; [ -z "${stage:-}" ] || rm -rf "$stage"' RETURN
    rldyour::download_verified_file "$url" "$sha" "$archive" || return 1
    tar -xzf "$archive" --strip-components="$strip" -C "$stage"
    [ -x "$stage/$binrel" ] || {
      rldyour::log "error" "staged ${name} artifact is missing ${binrel}"
      return 1
    }
    "$stage/$binrel" --version 2>/dev/null | grep -Fq "$version" || {
      rldyour::log "error" "staged ${name} artifact did not report ${version}"
      return 1
    }
    rldyour::ubuntu::write_runtime_receipt "$stage" "$name" "$version" "$sha" "$binrel" || return 1
    mv "$stage" "$destination"
    stage=""
    rm -f "$archive"
    trap - RETURN
  fi
  rldyour::ubuntu::preflight_managed_link "$name" "$namespace"
  ensure_managed_tool_link "$name" "$destination/$binrel" "$namespace"
  "$HOME/.local/bin/$name" --version 2>/dev/null | grep -Fq "$version"
}

ensure_starship() {
  rldyour::section "Ensure Starship ${STARSHIP_VERSION}"
  local triple sha
  case "$(uname -m)" in
    x86_64|amd64) triple="x86_64-unknown-linux-gnu"; sha="$STARSHIP_SHA256_X64" ;;
    aarch64|arm64) triple="aarch64-unknown-linux-musl"; sha="$STARSHIP_SHA256_ARM64" ;;
    *) rldyour::log "error" "Starship ${STARSHIP_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  rldyour::ubuntu::ensure_standalone_tool starship "$STARSHIP_VERSION" \
    "https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-${triple}.tar.gz" \
    "$sha" 0 starship
}

ensure_atuin() {
  rldyour::section "Ensure Atuin ${ATUIN_VERSION}"
  local triple sha
  case "$(uname -m)" in
    x86_64|amd64) triple="x86_64-unknown-linux-gnu"; sha="$ATUIN_SHA256_X64" ;;
    aarch64|arm64) triple="aarch64-unknown-linux-gnu"; sha="$ATUIN_SHA256_ARM64" ;;
    *) rldyour::log "error" "Atuin ${ATUIN_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  # atuin tarballs nest the binary under atuin-<triple>/; strip that leading dir.
  rldyour::ubuntu::ensure_standalone_tool atuin "$ATUIN_VERSION" \
    "https://github.com/atuinsh/atuin/releases/download/v${ATUIN_VERSION}/atuin-${triple}.tar.gz" \
    "$sha" 1 atuin
}

ensure_carapace() {
  rldyour::section "Ensure Carapace ${CARAPACE_VERSION}"
  local arch sha
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64"; sha="$CARAPACE_SHA256_X64" ;;
    aarch64|arm64) arch="arm64"; sha="$CARAPACE_SHA256_ARM64" ;;
    *) rldyour::log "error" "Carapace ${CARAPACE_VERSION} has no tracked artifact for $(uname -m)"; return 1 ;;
  esac
  rldyour::ubuntu::ensure_standalone_tool carapace "$CARAPACE_VERSION" \
    "https://github.com/carapace-sh/carapace-bin/releases/download/v${CARAPACE_VERSION}/carapace-bin_${CARAPACE_VERSION}_linux_${arch}.tar.gz" \
    "$sha" 0 carapace
}

# Optional, explicit-opt-in, reversible login-shell change. OFF by default; only
# runs when RLDYOUR_SET_LOGIN_SHELL=1. Ensures the real zsh binary is listed in
# /etc/shells, records the prior login shell for rollback, then chsh the owner.
ensure_login_shell() {
  [ "$SET_LOGIN_SHELL" -eq 1 ] || {
    rldyour::log "info" "login shell change disabled (set RLDYOUR_SET_LOGIN_SHELL=1 to opt in)"
    return 0
  }
  rldyour::section "Set zsh as the login shell (opt-in)"
  local zsh_bin owner prev_file current
  zsh_bin="$(command -v zsh 2>/dev/null || true)"
  [ -n "$zsh_bin" ] || {
    rldyour::log "error" "zsh not found; cannot set the login shell"
    return 1
  }
  # Refuse anything but a real, root-owned system zsh (never a $HOME shim).
  case "$zsh_bin" in
    /usr/bin/zsh|/bin/zsh|/usr/local/bin/zsh) ;;
    *)
      rldyour::log "error" "refusing to set an unexpected zsh path as login shell: $zsh_bin"
      return 1
      ;;
  esac
  owner="$(id -un)"
  prev_file="$HOME/.config/rldyour/previous-login-shell"
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] ensure ${zsh_bin} is in /etc/shells, record the prior login shell to ${prev_file}, then chsh -s ${zsh_bin} ${owner}"
    return 0
  fi
  if ! grep -Fxq "$zsh_bin" /etc/shells 2>/dev/null; then
    printf '%s\n' "$zsh_bin" | rldyour::ubuntu::as_root tee -a /etc/shells >/dev/null
  fi
  current="$(getent passwd "$owner" | awk -F: '{ print $7 }')"
  if [ "$current" = "$zsh_bin" ]; then
    rldyour::log "ok" "login shell already ${zsh_bin}"
    return 0
  fi
  mkdir -p "$(dirname "$prev_file")"
  if [ ! -f "$prev_file" ]; then
    printf '%s\n' "$current" >"$prev_file"
    chmod 0600 "$prev_file"
  fi
  rldyour::ubuntu::as_root chsh -s "$zsh_bin" "$owner" || {
    rldyour::log "error" "chsh failed; login shell unchanged"
    return 1
  }
  rldyour::log "ok" "login shell set to ${zsh_bin}; rollback: chsh -s \"\$(cat ${prev_file})\" ${owner}"
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
  # Delegate the active harness set (codex, zcode) to their authoritative NDDev
  # modules; no AI CLI is installed inline or through a bun/npm global path.
  rldyour::install_selected_harnesses
}

install_gui_apps() {
  if [ "$PROFILE" != "desktop" ] || [ "$GUI_ENABLED" -ne 1 ]; then
    rldyour::log "info" "GUI application layer disabled"
    return 0
  fi
  rldyour::section "Install verified Ubuntu GUI applications"
  apt_install fonts-jetbrains-mono || rldyour::log "warn" "fonts-jetbrains-mono unavailable"
  # The active harness set (codex, zcode) is owned by its GDS modules; the ZCode
  # desktop app is installed by nddev-zcode-app, not by this bootstrap.
  rldyour::log "info" "harness desktop apps are owned by their GDS modules; no GUI harness is installed here."
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
  ensure_starship
  ensure_atuin
  ensure_carapace
  rldyour::ensure_path
  install_python_source_tools
  rldyour::ensure_git_perf
  rldyour::ensure_git_delta_config
  rldyour::install_terminal_configs "$REPO_ROOT/templates/terminal"
  ensure_login_shell
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
