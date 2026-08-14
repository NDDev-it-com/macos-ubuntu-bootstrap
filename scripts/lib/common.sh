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

rldyour::sha256_file() {
  local path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{ print $1 }'
  else
    rldyour::log "error" "sha256sum or shasum is required for artifact verification"
    return 1
  fi
}

# Print the single primary-key fingerprint of a keyring, uppercased.
#
# This is the one implementation of vendor-key identity in the repository. The
# same awk program used to be copied into the Chrome installer, the Chrome
# verifier, the Docker installer, and the Docker verifier; the verifier copy was
# written inside a double-quoted command substitution, so its escaped quotes
# reached awk verbatim and the program never parsed. Under `set -o pipefail`
# that aborted strict Ubuntu GUI verification on every device, in every state.
#
# Fails closed when the keyring is missing, is not a regular file, cannot be
# parsed, or holds anything other than exactly one primary key. A keyring
# carrying a second primary key is not the vendor identity the caller asked
# about, even when one of its fingerprints happens to match.
rldyour::gpg_primary_fingerprint() {
  local keyring=${1:?keyring path is required}
  [ -f "$keyring" ] && [ ! -L "$keyring" ] || return 1
  gpg --batch --show-keys --with-colons "$keyring" 2>/dev/null |
    awk -F: '
      $1 == "pub" { primary_count++; awaiting_primary_fpr = 1; next }
      $1 == "fpr" && awaiting_primary_fpr {
        primary_fpr = toupper($10)
        awaiting_primary_fpr = 0
      }
      END {
        if (primary_count != 1 || primary_fpr == "") exit 1
        print primary_fpr
      }
    '
}

# True when the current x86-64 CPU advertises AVX2. The standard Bun x64 build
# requires AVX2; older CPUs must use the bun-linux-x64-baseline artifact or they
# fail with SIGILL. Non-x86 architectures are not gated by this check.
rldyour::cpu_has_avx2() {
  grep -Eq '(^|[[:space:]])avx2([[:space:]]|$)' /proc/cpuinfo 2>/dev/null
}

rldyour::download_verified_file() {
  local url=$1
  local expected_sha256=$2
  local destination=$3
  local actual_sha256

  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "$url" --output "$destination" || return 1
  actual_sha256="$(rldyour::sha256_file "$destination")" || return 1
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    rldyour::log "error" "SHA-256 mismatch for ${url}: expected ${expected_sha256}, got ${actual_sha256}"
    return 1
  fi
}

rldyour::sha512_file() {
  local path=$1
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$path" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "$path" | awk '{ print $1 }'
  else
    rldyour::log "error" "sha512sum or shasum is required for artifact verification"
    return 1
  fi
}

rldyour::download_verified_sha512_file() {
  local url=$1
  local expected_sha512=$2
  local destination=$3
  local actual_sha512

  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "$url" --output "$destination" || return 1
  actual_sha512="$(rldyour::sha512_file "$destination")" || return 1
  if [ "$actual_sha512" != "$expected_sha512" ]; then
    rldyour::log "error" "SHA-512 mismatch for pinned artifact: ${url}"
    return 1
  fi
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
    # Some tools report their version on stderr. The Ubuntu Dart path reads both
    # streams for exactly that reason; this one discarded stderr and then passed
    # the check anyway, so a Dart that only answers on stderr satisfied a
    # minimum-version gate without its version ever being compared.
    actual_version=$("$command_name" "$version_cmd" 2>&1 | head -n 1 | sed 's/^v//; s/^[^0-9]*//')
  fi
  if [ -z "$actual_version" ]; then
    # Fail closed. A verifier that cannot read a version has not verified it,
    # and every equivalent Ubuntu check is an exact comparison that exits
    # non-zero here. "Skipping the numeric check" made the macOS gate weaker
    # than the Ubuntu one for the same invariant.
    rldyour::log "missing" "could not detect version for $command_name (expected >= $min_version)"
    return 1
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
    # The Codex CLI installs into its own target and publishes no link into
    # the managed prefix, so this is the only place `codex` resolves from.
    "${RLDYOUR_CODEX_HOME:-$HOME/.codex}/bin"
    # Apple Silicon Homebrew. ensure_homebrew installs brew into /opt/homebrew
    # but the Homebrew installer only edits the login shell profile, never the
    # current process, so without this the macOS apply run cannot resolve `brew`
    # (or the dart/bun/node it just installed) right after installing it. The
    # dir guard makes this a no-op on Linux and on a pre-brew macOS pass.
    "/opt/homebrew/bin"
    "/opt/homebrew/sbin"
  )
  local prefix=""
  for p in "${candidates[@]}"; do
    if [ -d "$p" ]; then
      if [ -n "$prefix" ]; then
        prefix="$prefix:$p"
      else
        prefix="$p"
      fi
    fi
  done
  [ -z "$prefix" ] || PATH="$prefix:$PATH"
  export PATH
}

# Install or update a repository-owned file atomically. Existing files are
# changed only when they carry the supplied ownership marker.
rldyour::install_managed_file() {
  local dest=$1
  local marker=$2
  local mode=${3:-0644}
  local legacy_marker=${4:-}
  local explicitly_owned=${5:-0}
  local parent tmp

  parent="$(dirname "$dest")"
  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    cat >/dev/null
    rldyour::log "info" "[DRY-RUN] install managed file: ${dest}"
    return 0
  fi

  mkdir -p "$parent" || return 1
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod "$mode" "$tmp" || {
    rm -f "$tmp"
    return 1
  }

  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
    rm -f "$tmp"
    rldyour::log "error" "unmanaged path is not a regular file; preserved: ${dest}"
    return 1
  fi
  if [ -f "$dest" ]; then
    if grep -Fxq "$marker" "$dest"; then
      :
    elif [ -n "$legacy_marker" ] && grep -Fxq "$legacy_marker" "$dest"; then
      rldyour::log "info" "updating legacy repository-managed file: ${dest}"
    elif [ "$explicitly_owned" -eq 1 ]; then
      :
    else
      rm -f "$tmp"
      rldyour::log "error" "unmanaged file differs; preserved: ${dest}"
      return 1
    fi
  fi
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    chmod "$mode" "$dest" || return 1
    rldyour::log "ok" "managed file already current: ${dest}"
    return 0
  fi

  mv -f "$tmp" "$dest" || {
    rm -f "$tmp"
    return 1
  }
  rldyour::log "ok" "installed managed file: ${dest}"
}

# Official vendor installers are mutable URLs. The bootstrap downloads them to
# a temporary file and verifies the reviewed script digest before execution.
RLDYOUR_CLAUDE_INSTALLER_URL="https://claude.ai/install.sh"
RLDYOUR_CLAUDE_INSTALLER_SHA256="cde4f1702d3b1695f92b73d26888364e17bca476e17f0fd676484c951d36c125"
RLDYOUR_GROK_INSTALLER_URL="https://x.ai/cli/install.sh"
RLDYOUR_GROK_INSTALLER_SHA256="43d0943123edade1383a476a4f778674877acee7c1f98a00f094c4a0f7349321"
RLDYOUR_CODEX_VERSION="0.147.0"
RLDYOUR_CODEX_TARBALL="https://registry.npmjs.org/@openai/codex/-/codex-0.147.0.tgz"
RLDYOUR_CODEX_SHA512="1102c45de7001b6a6dc48ed4a41328d9347f81ae79f7afdcfceb1817fd0ba140e1e4900d67b2281aa97304459bb84550efa25e3c86ed4d6fe2842929d5aed9df"

rldyour::install_vendor_ai_clis() {
  rldyour::section "Install official AI CLIs (Codex, Claude Code, Grok Build)"
  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] install verified @openai/codex ${RLDYOUR_CODEX_VERSION} package"
    rldyour::log "info" "[DRY-RUN] execute reviewed Anthropic native installer after SHA-256 verification"
    rldyour::log "info" "[DRY-RUN] execute reviewed xAI native installer after SHA-256 verification"
  else
    local stage codex_tgz claude_script grok_script npm_bin
    stage="$(mktemp -d)" || return 1
    codex_tgz="$stage/codex.tgz"
    claude_script="$stage/claude-install.sh"
    grok_script="$stage/grok-install.sh"
    rldyour::download_verified_sha512_file "$RLDYOUR_CODEX_TARBALL" "$RLDYOUR_CODEX_SHA512" "$codex_tgz" || return 1
    npm_bin="$(command -v npm 2>/dev/null || true)"
    if [ -z "$npm_bin" ] && [ -x "$HOME/.local/share/rldyour/node/v24.19.0/bin/npm" ]; then
      npm_bin="$HOME/.local/share/rldyour/node/v24.19.0/bin/npm"
    fi
    [ -n "$npm_bin" ] || {
      rldyour::log "error" "npm is unavailable for the verified Codex package installation"
      return 1
    }
    "$npm_bin" install --global --prefix "$HOME/.local/share/rldyour/npm" "$codex_tgz" || return 1
    mkdir -p "$HOME/.local/bin" || return 1
    ln -sfn "$HOME/.local/share/rldyour/npm/bin/codex" "$HOME/.local/bin/codex" || return 1
    rldyour::download_verified_file "$RLDYOUR_CLAUDE_INSTALLER_URL" "$RLDYOUR_CLAUDE_INSTALLER_SHA256" "$claude_script" || return 1
    bash "$claude_script" stable || return 1
    rldyour::download_verified_file "$RLDYOUR_GROK_INSTALLER_URL" "$RLDYOUR_GROK_INSTALLER_SHA256" "$grok_script" || return 1
    bash "$grok_script" || return 1
  fi
  rldyour::install_ai_launchers
}

rldyour::install_ai_launchers() {
  local bin="$HOME/.local/bin"
  # install_managed_file is plan-aware, but this mkdir was not, so a plan
  # created ~/.local/bin on a machine it was only supposed to describe.
  [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ] || mkdir -p "$bin"
  rldyour::install_managed_file "$bin/cx" "# Managed by macos-ubuntu-bootstrap: ai-launcher-cx-v1" 0755 <<'EOF'
#!/bin/sh
# Managed by macos-ubuntu-bootstrap: ai-launcher-cx-v1
exec codex --dangerously-bypass-approvals-and-sandbox "$@"
EOF
  rldyour::install_managed_file "$bin/cl" "# Managed by macos-ubuntu-bootstrap: ai-launcher-cl-v1" 0755 <<'EOF'
#!/bin/sh
# Managed by macos-ubuntu-bootstrap: ai-launcher-cl-v1
exec claude --dangerously-skip-permissions "$@"
EOF
  rldyour::install_managed_file "$bin/gk" "# Managed by macos-ubuntu-bootstrap: ai-launcher-gk-v1" 0755 <<'EOF'
#!/bin/sh
# Managed by macos-ubuntu-bootstrap: ai-launcher-gk-v1
exec grok --permission-mode bypassPermissions --always-approve "$@"
EOF
}

rldyour::_isolated_python() {
  local python_bin=$1
  shift
  env -u PYTHONPATH -u PYTHONHOME "$python_bin" -I "$@"
}

# Print a normalized octal permission mode for one existing path. BSD stat and
# GNU stat assign incompatible meanings to `-f`, so select the supported host
# contract before invoking either syntax. The kernel probe is isolated from
# shell function/PATH overrides used by cross-platform installer tests.
rldyour::_kernel_name() {
  rldyour::_isolated_python python3 - <<'PY'
import os

print(os.uname().sysname)
PY
}

rldyour::file_mode() {
  local path=${1:?file mode path is required}
  local kernel raw normalized

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    rldyour::log "error" "cannot inspect permissions of missing path: ${path}" >&2
    return 1
  fi
  kernel="$(rldyour::_kernel_name)" || {
    rldyour::log "error" "could not determine host kernel for permission inspection" >&2
    return 1
  }
  case "$kernel" in
    Darwin)
      raw="$(stat -f '%Lp' "$path")" || {
        rldyour::log "error" "BSD stat failed to inspect permissions: ${path}" >&2
        return 1
      }
      ;;
    Linux)
      raw="$(stat -c '%a' -- "$path")" || {
        rldyour::log "error" "GNU stat failed to inspect permissions: ${path}" >&2
        return 1
      }
      ;;
    *)
      rldyour::log "error" "unsupported host kernel for permission inspection: ${kernel:-empty}" >&2
      return 1
      ;;
  esac
  if ! [[ "$raw" =~ ^[0-7]{3,4}$ ]]; then
    rldyour::log "error" "${kernel} stat returned malformed permission mode for ${path}: ${raw:-empty}" >&2
    return 1
  fi
  printf -v normalized '%03o' "$((8#$raw))" || return 1
  printf '%s\n' "$normalized"
}

rldyour::ensure_dart_telemetry_disabled() {
  local binary=$1
  if [ ! -x "$binary" ]; then
    rldyour::log "error" "Dart telemetry opt-out needs an executable dart: ${binary}"
    return 1
  fi
  # Dart's unified analytics becomes a no-op when CI is set and therefore does
  # not persist the owner opt-out. Clear only that process-local marker so the
  # official switch materializes state that remains valid outside CI.
  env -u CI "$binary" --disable-analytics >/dev/null 2>&1 || {
    rldyour::log "error" "'dart --disable-analytics' failed; Dart telemetry state is unknown"
    return 1
  }
  rldyour::log "ok" "Dart accepted the documented --disable-analytics command"
  rldyour::observe_dart_telemetry_config
}

rldyour::observe_dart_telemetry_config() {
  local config="$HOME/.dart-tool/dart-flutter-telemetry.config"
  if [ ! -e "$config" ]; then
    rldyour::log "info" "optional Dart telemetry config was not materialized; upstream may suppress analytics in CI"
    return 0
  fi
  if [ ! -f "$config" ] || [ -L "$config" ]; then
    rldyour::log "warn" "optional Dart telemetry config is not a regular non-symlink file: ${config}"
    return 0
  fi
  if grep -Fxq 'reporting=0' "$config" && ! grep -Fxq 'reporting=1' "$config"; then
    rldyour::log "ok" "optional Dart telemetry config reports disabled (${config})"
  else
    rldyour::log "warn" "optional Dart telemetry config does not unambiguously report disabled (${config})"
  fi
}

rldyour::_managed_tree_permissions() {
  local mode=$1 root=$2
  case "$mode" in normalize|validate) ;; *) return 2 ;; esac
  rldyour::_isolated_python python3 -I - "$mode" "$root" <<'PY'
import os
import pathlib
import stat
import sys

mode, raw_root = sys.argv[1:]
root = pathlib.Path(raw_root)
root_real = root.resolve(strict=True)
uid = os.getuid()


def inspect(path: pathlib.Path) -> None:
    metadata = path.lstat()
    if metadata.st_uid != uid:
        raise SystemExit(f"runtime path has a foreign owner: {path}")
    if stat.S_ISLNK(metadata.st_mode):
        try:
            path.resolve(strict=True).relative_to(root_real)
        except (FileNotFoundError, ValueError):
            raise SystemExit(f"runtime symlink escaped its content-addressed root: {path}")
        return
    if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)):
        raise SystemExit(f"runtime contains an unsupported file type: {path}")
    permissions = stat.S_IMODE(metadata.st_mode)
    if mode == "normalize" and permissions & 0o022:
        path.chmod(permissions & ~0o022)
        metadata = path.lstat()
    if metadata.st_mode & 0o022:
        raise SystemExit(f"runtime path is group/world-writable: {path}")


inspect(root)
for directory, directories, files in os.walk(root, followlinks=False):
    base = pathlib.Path(directory)
    for name in directories + files:
        inspect(base / name)
PY
}

# --- Terminal layer# --- Terminal layer ----------------------------------------------------------

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

# Add or refresh one small, owned source block while preserving every byte
# outside that block. Existing shell files are backed up before the first
# mutation. Symlinks and non-regular paths are never followed or replaced.
rldyour::_ensure_managed_shell_source() {
  local dest=$1 dropin=$2 label=$3
  local begin="# >>> macos-ubuntu-bootstrap managed ${label} >>>"
  local end="# <<< macos-ubuntu-bootstrap managed ${label} <<<"
  local parent tmp backup_root

  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
    rldyour::log "error" "shell startup path is not a regular file; preserved: ${dest}"
    return 1
  fi
  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] ensure ${dest} sources ${dropin} through an owned block"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || {
    rldyour::log "error" "python3 is required to update shell source blocks safely"
    return 1
  }

  parent="$(dirname "$dest")"
  mkdir -p "$parent" || return 1
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
  if [ -f "$dest" ]; then
    cp -p "$dest" "$tmp" || { rm -f "$tmp"; return 1; }
  else
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if ! rldyour::_isolated_python python3 - "$dest" "$tmp" "$dropin" "$begin" "$end" <<'PY'
from pathlib import Path
import sys

dest = Path(sys.argv[1])
output = Path(sys.argv[2])
dropin, begin, end = sys.argv[3:]
source = dest.read_text(encoding="utf-8") if dest.exists() else ""
if source.count(begin) != source.count(end):
    raise SystemExit("unbalanced managed shell source markers")
if source.count(begin) > 1:
    raise SystemExit("duplicate managed shell source markers")

block = f'{begin}\nsource "$HOME/{dropin}"\n{end}'
if begin in source:
    start = source.index(begin)
    stop = source.index(end, start) + len(end)
    rendered = source[:start] + block + source[stop:]
else:
    separator = "" if not source else ("" if source.endswith("\n") else "\n")
    rendered = source + separator + block + "\n"
output.write_text(rendered, encoding="utf-8")
PY
  then
    rm -f "$tmp"
    rldyour::log "error" "managed shell source block is malformed; preserved: ${dest}"
    return 1
  fi

  if [ -f "$dest" ] && cmp -s "$dest" "$tmp"; then
    rm -f "$tmp"
    rldyour::log "ok" "managed shell source already current: ${dest}"
    return 0
  fi
  if [ -f "$dest" ]; then
    backup_root="$HOME/.local/share/rldyour/backups/shell/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$backup_root" || { rm -f "$tmp"; return 1; }
    chmod 0700 "$backup_root" || { rm -f "$tmp"; return 1; }
    cp -p "$dest" "$backup_root/$(basename "$dest")" || { rm -f "$tmp"; return 1; }
    rldyour::log "info" "backed up shell startup file: ${backup_root}/$(basename "$dest")"
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rldyour::log "ok" "installed managed shell source block: ${dest}"
}

rldyour::verify_terminal_environment() {
  local shell_dump expected_bin="$HOME/.local/bin"
  local -a required_cmds=(codex claude grok cx cl gk)
  command -v zsh >/dev/null 2>&1 || {
    rldyour::log "error" "zsh is required for managed terminal verification"
    return 1
  }
  shell_dump="$(RLDYOUR_VERIFY_CMDS="${required_cmds[*]}" zsh -l -c '
    printf "__RLDYOUR_PATH__=%s\n" "$PATH"
    for name in ${=RLDYOUR_VERIFY_CMDS}; do
      resolved="$(command -v "$name")" || exit 1
      printf "__RLDYOUR_CMD_%s__=%s\n" "$name" "$resolved"
    done
  ' 2>/dev/null)" || {
    rldyour::log "error" "fresh zsh login environment verification failed"
    return 1
  }
  rldyour::_isolated_python python3 - "$shell_dump" "$expected_bin" <<'PY'
import sys

values = {}
for line in sys.argv[1].splitlines():
    if line.startswith("__RLDYOUR_") and "=" in line:
        key, value = line.split("=", 1)
        values[key] = value
expected_bin = sys.argv[2]
required = {"__RLDYOUR_PATH__"}
required.update(f"__RLDYOUR_CMD_{name}__" for name in ("codex", "claude", "grok", "cx", "cl", "gk"))
commands = [
    key[len("__RLDYOUR_CMD_"):-len("__")]
    for key in values
    if key.startswith("__RLDYOUR_CMD_")
]
if not required <= values.keys():
    raise SystemExit("fresh zsh environment returned an incomplete contract")
path = values["__RLDYOUR_PATH__"]
if path.split(":", 1)[0] != expected_bin:
    raise SystemExit("managed user bin is not first on fresh zsh PATH")
for name in commands:
    resolved = values[f"__RLDYOUR_CMD_{name}__"]
    if not resolved.startswith(expected_bin + "/"):
        raise SystemExit(f"managed command resolved outside {expected_bin}: {resolved}")
PY
  rldyour::log "ok" "fresh zsh login environment resolves all managed AI commands"
}

# Keep Git's mutable service metadata out of executable terminal-plugin trees.
# The object store is bare by construction (there is no worktree for fsmonitor to
# watch), while `_publish_pinned_git_payload` below materializes only blob entries
# from the reviewed commit tree.  Runtime consumers therefore never traverse a
# `.git` directory, lock file, socket, hook, or other VCS implementation detail.
rldyour::_ensure_pinned_git_object_store() {
  local url=$1 sha=$2 store=$3 origin bare
  if [ -e "$store" ] || [ -L "$store" ]; then
    if [ -L "$store" ] || [ ! -d "$store" ]; then
      rldyour::log "error" "unmanaged path at pinned Git object store; preserved: ${store}"
      return 1
    fi
    bare="$(git --git-dir="$store" rev-parse --is-bare-repository 2>/dev/null || true)"
    # Read the stored canonical value, not `remote get-url`: the latter applies
    # the owner's url.*.insteadOf transport rewrite and can make an exact HTTPS
    # origin look like SSH without changing repository identity.
    origin="$(git --git-dir="$store" config --get remote.origin.url 2>/dev/null || true)"
    if [ "$bare" != true ] || [ "$origin" != "$url" ]; then
      rldyour::log "error" "pinned Git object store has unexpected identity; preserved: ${store}"
      return 1
    fi
    git --git-dir="$store" fetch --quiet --tags origin || {
      rldyour::log "error" "failed to fetch pinned Git objects for ${store}"
      return 1
    }
  else
    mkdir -p "${store%/*}" || return 1
    git -c core.fsmonitor=false clone --quiet --bare "$url" "$store" || {
      rldyour::log "error" "failed to clone pinned Git object store from ${url}"
      return 1
    }
  fi
  git --git-dir="$store" cat-file -e "${sha}^{commit}" 2>/dev/null || {
    rldyour::log "error" "pinned commit ${sha} is absent from ${store}"
    return 1
  }
  git --git-dir="$store" fsck --strict --no-dangling "$sha" >/dev/null 2>&1 || {
    rldyour::log "error" "pinned Git object store failed integrity verification: ${store}"
    return 1
  }
  rldyour::_managed_tree_permissions normalize "$store" || {
    rldyour::log "error" "could not normalize pinned Git object-store permissions: ${store}"
    return 1
  }
}

# Publish and verify the exact tracked payload of a pinned commit.  Git tree
# entries are the allow-list: missing, additional, byte-divergent, mode-divergent,
# or unsupported tracked entries fail closed.  The destination contains no Git
# metadata and an already-published destination is verified rather than repaired.
rldyour::_publish_pinned_git_payload() {
  local store=$1 sha=$2 destination=$3 source_root
  source_root=${4:-${store%/github.com/*}}
  rldyour::_isolated_python python3 -I - "$store" "$sha" "$destination" "$source_root" <<'PY'
import configparser
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

store, commit, raw_destination, raw_source_root = sys.argv[1:]
destination = pathlib.Path(raw_destination)
source_root = pathlib.Path(raw_source_root)
uid = os.getuid()


def git(git_store: str | pathlib.Path, *arguments: str) -> bytes:
    completed = subprocess.run(
        ["git", f"--git-dir={git_store}", *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        raise SystemExit(f"Git object read failed ({' '.join(arguments)}): {detail}")
    return completed.stdout


def normalize_object_store(git_store: pathlib.Path) -> None:
    for directory, directories, files in os.walk(git_store, followlinks=False):
        for raw_path in [pathlib.Path(directory), *(pathlib.Path(directory) / name for name in directories + files)]:
            metadata = raw_path.lstat()
            if metadata.st_uid != uid:
                raise SystemExit(f"pinned Git object store has a foreign owner: {raw_path}")
            if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)):
                raise SystemExit(f"pinned Git object store contains an unsupported file type: {raw_path}")
            permissions = stat.S_IMODE(metadata.st_mode)
            if permissions & 0o022:
                raw_path.chmod(permissions & ~0o022)


def ensure_submodule_store(url: str, pinned_commit: str) -> pathlib.Path:
    match = re.fullmatch(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?", url)
    if not match:
        raise SystemExit(f"tracked submodule uses an unsupported origin: {url}")
    owner, repository = match.groups()
    canonical_url = f"https://github.com/{owner}/{repository}"
    child_store = source_root / "github.com" / owner / f"{repository}.git"
    if child_store.exists() or child_store.is_symlink():
        if child_store.is_symlink() or not child_store.is_dir():
            raise SystemExit(f"unmanaged path at pinned submodule object store: {child_store}")
        bare = git(child_store, "rev-parse", "--is-bare-repository").decode().strip()
        # Compare stored identity; `remote get-url` applies user-global
        # url.*.insteadOf transport rewrites and is not an identity primitive.
        origin = git(child_store, "config", "--get", "remote.origin.url").decode().strip()
        if bare != "true" or origin.removesuffix(".git") != canonical_url:
            raise SystemExit(f"pinned submodule object store has unexpected identity: {child_store}")
        git(child_store, "fetch", "--quiet", "--tags", "origin")
    else:
        child_store.parent.mkdir(parents=True, exist_ok=True)
        completed = subprocess.run(
            ["git", "-c", "core.fsmonitor=false", "clone", "--quiet", "--bare", canonical_url, str(child_store)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode:
            detail = completed.stderr.decode("utf-8", "replace").strip()
            raise SystemExit(f"failed to clone pinned submodule object store {canonical_url}: {detail}")
    git(child_store, "cat-file", "-e", f"{pinned_commit}^{{commit}}")
    git(child_store, "fsck", "--strict", "--no-dangling", pinned_commit)
    normalize_object_store(child_store)
    return child_store


def submodule_origins(git_store: str | pathlib.Path, pinned_commit: str) -> dict[pathlib.PurePosixPath, str]:
    try:
        raw = git(git_store, "show", f"{pinned_commit}:.gitmodules")
    except SystemExit:
        return {}
    parser = configparser.RawConfigParser(interpolation=None)
    try:
        parser.read_string(raw.decode("utf-8"))
    except (UnicodeDecodeError, configparser.Error) as error:
        raise SystemExit("tracked .gitmodules is malformed or not UTF-8") from error
    origins: dict[pathlib.PurePosixPath, str] = {}
    for section in parser.sections():
        if not section.startswith('submodule "') or not section.endswith('"'):
            raise SystemExit(f"tracked .gitmodules contains an unsupported section: {section}")
        if not parser.has_option(section, "path") or not parser.has_option(section, "url"):
            raise SystemExit(f"tracked .gitmodules entry is incomplete: {section}")
        path = pathlib.PurePosixPath(parser.get(section, "path"))
        if (
            path.is_absolute()
            or not path.parts
            or any(part in {"", ".", ".."} or part.casefold() == ".git" for part in path.parts)
        ):
            raise SystemExit(f"tracked .gitmodules contains an unsafe path: {path}")
        if path in origins:
            raise SystemExit(f"tracked .gitmodules repeats a path: {path}")
        origins[path] = parser.get(section, "url")
    return origins


def parse_tree(
    git_store: str | pathlib.Path,
    pinned_commit: str,
    prefix: pathlib.PurePosixPath = pathlib.PurePosixPath(),
    ancestry: tuple[tuple[str, str], ...] = (),
) -> dict[pathlib.PurePosixPath, tuple[str, bytes]]:
    entries: dict[pathlib.PurePosixPath, tuple[str, bytes]] = {}
    identity = (str(pathlib.Path(git_store).resolve()), pinned_commit)
    if identity in ancestry:
        raise SystemExit("tracked submodule graph contains a cycle")
    raw = git(git_store, "ls-tree", "-rz", "--full-tree", pinned_commit)
    records: list[tuple[str, str, str, pathlib.PurePosixPath]] = []
    for record in raw.split(b"\0"):
        if not record:
            continue
        header, separator, raw_path = record.partition(b"\t")
        if not separator:
            raise SystemExit("pinned Git tree emitted a malformed entry")
        try:
            mode, kind, object_id = header.decode("ascii").split(" ")
            path = pathlib.PurePosixPath(raw_path.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as error:
            raise SystemExit("pinned Git tree contains an unsupported path or header") from error
        if (kind, mode) not in {
            ("blob", "100644"),
            ("blob", "100755"),
            ("blob", "120000"),
            ("commit", "160000"),
        }:
            raise SystemExit(
                f"pinned Git tree contains unsupported tracked entry: {mode} {kind} {path}"
            )
        if (
            path.is_absolute()
            or not path.parts
            or any(part in {"", ".", ".."} or part.casefold() == ".git" for part in path.parts)
        ):
            raise SystemExit(f"pinned Git tree contains an unsafe tracked path: {path}")
        records.append((mode, kind, object_id, path))
    origins = submodule_origins(git_store, pinned_commit) if any(mode == "160000" for mode, _, _, _ in records) else {}
    gitlinks = {path for mode, _, _, path in records if mode == "160000"}
    if set(origins) != gitlinks:
        raise SystemExit("tracked gitlinks and .gitmodules paths do not match exactly")
    for mode, _kind, object_id, path in records:
        published_path = prefix / path
        if mode == "160000":
            child_store = ensure_submodule_store(origins[path], object_id)
            child_entries = parse_tree(child_store, object_id, published_path, ancestry + (identity,))
            overlap = set(entries) & set(child_entries)
            if overlap:
                raise SystemExit(f"tracked submodule payload overlaps its parent: {min(overlap)}")
            entries.update(child_entries)
        else:
            if published_path in entries:
                raise SystemExit(f"pinned Git tree contains a duplicate tracked path: {published_path}")
            entries[published_path] = (mode, git(git_store, "cat-file", "blob", object_id))
    if not entries:
        raise SystemExit("pinned Git tree has no tracked payload")
    return entries


entries = parse_tree(store, commit)
expected_directories = {
    pathlib.PurePosixPath(*path.parts[:index])
    for path in entries
    for index in range(1, len(path.parts))
}


def safe_symlink_target(path: pathlib.PurePosixPath, payload: bytes) -> str:
    try:
        target = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SystemExit(f"tracked symlink target is not UTF-8: {path}") from error
    if not target or "\0" in target or pathlib.PurePosixPath(target).is_absolute():
        raise SystemExit(f"tracked symlink has an unsafe target: {path}")
    resolved = pathlib.PurePosixPath(path.parent, target)
    normalized: list[str] = []
    for part in resolved.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not normalized:
                raise SystemExit(f"tracked symlink escapes its payload root: {path}")
            normalized.pop()
        else:
            normalized.append(part)
    normalized_target = pathlib.PurePosixPath(*normalized)
    if normalized_target not in entries and normalized_target not in expected_directories:
        raise SystemExit(f"tracked symlink does not resolve to tracked payload: {path}")
    return target


def verify(root: pathlib.Path) -> None:
    if root.is_symlink() or not root.is_dir():
        raise SystemExit(f"tracked payload root is not a real directory: {root}")
    root_metadata = root.lstat()
    if root_metadata.st_uid != uid or stat.S_IMODE(root_metadata.st_mode) != 0o755:
        raise SystemExit(f"tracked payload root ownership or mode diverged: {root}")
    actual_files: set[pathlib.PurePosixPath] = set()
    actual_directories: set[pathlib.PurePosixPath] = set()
    for directory, directories, files in os.walk(root, followlinks=False):
        base = pathlib.Path(directory)
        relative_base = base.relative_to(root)
        for name in directories + files:
            item = base / name
            relative = pathlib.PurePosixPath(*(relative_base / name).parts)
            metadata = item.lstat()
            if metadata.st_uid != uid:
                raise SystemExit(f"tracked payload has a foreign owner: {item}")
            if stat.S_ISDIR(metadata.st_mode):
                actual_directories.add(relative)
                if stat.S_IMODE(metadata.st_mode) != 0o755:
                    raise SystemExit(f"tracked payload directory mode diverged: {item}")
            elif stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                actual_files.add(relative)
            else:
                raise SystemExit(f"tracked payload contains an unsupported file type: {item}")
    if actual_directories != expected_directories:
        raise SystemExit("tracked payload directory set is missing or contains additional paths")
    if actual_files != set(entries):
        raise SystemExit("tracked payload file set is missing or contains additional paths")
    for path, (mode, payload) in entries.items():
        item = root.joinpath(*path.parts)
        metadata = item.lstat()
        if mode == "120000":
            if not stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"tracked symlink semantics diverged: {item}")
            if os.readlink(item) != safe_symlink_target(path, payload):
                raise SystemExit(f"tracked symlink target diverged: {item}")
        else:
            expected_mode = 0o755 if mode == "100755" else 0o644
            if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != expected_mode:
                raise SystemExit(f"tracked file mode diverged: {item}")
            if item.read_bytes() != payload:
                raise SystemExit(f"tracked file bytes diverged: {item}")


if destination.exists() or destination.is_symlink():
    verify(destination)
    raise SystemExit(0)

destination.parent.mkdir(parents=True, exist_ok=True)
stage = pathlib.Path(tempfile.mkdtemp(prefix=f".{destination.name}.stage.", dir=destination.parent))
try:
    os.chmod(stage, 0o755)
    for directory in sorted(expected_directories, key=lambda item: (len(item.parts), item.parts)):
        target = stage.joinpath(*directory.parts)
        target.mkdir()
        target.chmod(0o755)
    for path, (mode, payload) in sorted(entries.items(), key=lambda item: item[0].parts):
        target = stage.joinpath(*path.parts)
        if mode == "120000":
            target.symlink_to(safe_symlink_target(path, payload))
        else:
            target.write_bytes(payload)
            target.chmod(0o755 if mode == "100755" else 0o644)
    verify(stage)
    os.replace(stage, destination)
finally:
    if stage.exists():
        shutil.rmtree(stage)
verify(destination)
PY
}

# Materialize an OFFLINE antidote plugin bundle shared by macOS and Ubuntu:
# ensure antidote is present, publish every plugin's tracked pinned payload into
# antidote's source home, then compile the static ~/.zsh_plugins.zsh that shell
# startup sources with zero network. Idempotent: a second run re-verifies pinned
# SHAs and never re-clones a clean, already-pinned repo.
rldyour::materialize_zsh_plugins() {
  local manifest="$HOME/.zsh_plugins.txt"
  # getantidote/antidote pinned commit for the plain-Ubuntu clone path.
  local antidote_pin="4913257e0ae3fee2a77e7189e526fe55b6ff9536"
  local antidote_home="${XDG_CACHE_HOME:-$HOME/.cache}/antidote"
  local source_root="${XDG_CACHE_HOME:-$HOME/.cache}/rldyour/git-objects"
  local antidote_zsh="" candidate line repo sha dir store bundle tmp
  local -a antidote_candidates=(
    /opt/homebrew/opt/antidote/share/antidote/antidote.zsh
    /usr/local/opt/antidote/share/antidote/antidote.zsh
    /home/linuxbrew/.linuxbrew/opt/antidote/share/antidote/antidote.zsh
    "$HOME/.antidote/antidote.zsh"
  )

  rldyour::section "Materialize offline antidote plugin bundle"

  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] ensure antidote (brew, else publish getantidote/antidote@${antidote_pin} tracked payload to \$HOME/.antidote), publish every pinned tracked plugin payload from ${manifest} into ${antidote_home}, then compile \$HOME/.zsh_plugins.zsh"
    return 0
  fi

  command -v git >/dev/null 2>&1 || {
    rldyour::log "error" "git is required to materialize the antidote plugin bundle"
    return 1
  }
  command -v zsh >/dev/null 2>&1 || {
    rldyour::log "error" "zsh is required to compile the antidote plugin bundle"
    return 1
  }
  [ -r "$manifest" ] || {
    rldyour::log "error" "plugin manifest is missing: ${manifest}"
    return 1
  }

  # 1. Ensure antidote.zsh is available: brew provides it on macOS/linuxbrew;
  #    otherwise publish getantidote/antidote's pinned tracked payload to $HOME/.antidote,
  #    matching the path templates/terminal/zshrc already probes.
  for candidate in "${antidote_candidates[@]}"; do
    if [ -r "$candidate" ]; then
      antidote_zsh="$candidate"
      break
    fi
  done
  if [ -z "$antidote_zsh" ]; then
    store="$source_root/github.com/getantidote/antidote.git"
    rldyour::_ensure_pinned_git_object_store \
      "https://github.com/getantidote/antidote" "$antidote_pin" "$store" || return 1
    rldyour::_publish_pinned_git_payload "$store" "$antidote_pin" "$HOME/.antidote" "$source_root" || return 1
    antidote_zsh="$HOME/.antidote/antidote.zsh"
    [ -r "$antidote_zsh" ] || {
      rldyour::log "error" "antidote tracked payload did not provide antidote.zsh: ${antidote_zsh}"
      return 1
    }
  fi

  # 2. Publish every plugin's tracked commit-tree payload into Antidote's
  #    full-style source home ($ANTIDOTE_HOME/github.com/<owner>/<repo>) so neither bundling nor
  #    shell startup ever reaches the network.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    repo="${line%%[[:space:]]*}"
    case "$repo" in */*) ;; *) continue ;; esac
    sha=""
    if [[ "$line" =~ pin[[:space:]]+([0-9a-f]{40}) ]]; then
      sha="${BASH_REMATCH[1]}"
    fi
    [ -n "$sha" ] || {
      rldyour::log "error" "plugin ${repo} has no pinned SHA in ${manifest}"
      return 1
    }
    dir="$antidote_home/github.com/$repo"
    store="$source_root/github.com/${repo}.git"
    rldyour::_ensure_pinned_git_object_store "https://github.com/$repo" "$sha" "$store" || return 1
    rldyour::_publish_pinned_git_payload "$store" "$sha" "$dir" "$source_root" || {
      rldyour::log "error" "pinned terminal-plugin payload failed verification: ${dir}"
      return 1
    }
  done < "$manifest"

  # 3. Compile the static bundle. Every tracked payload is present at its pinned SHA, so
  #    antidote sources them by path and never clones — the output is pure
  #    `source`/`fpath` lines that shell startup runs offline.
  bundle="$HOME/.zsh_plugins.zsh"
  tmp="$(mktemp "${bundle}.tmp.XXXXXX")" || return 1
  if ! ANTIDOTE_HOME="$antidote_home" \
      zsh -fc 'source "$1"; antidote bundle' antidote-bundle "$antidote_zsh" \
      < "$manifest" > "$tmp"; then
    rm -f "$tmp"
    rldyour::log "error" "antidote failed to compile the static plugin bundle"
    return 1
  fi
  [ -s "$tmp" ] || {
    rm -f "$tmp"
    rldyour::log "error" "compiled antidote bundle is empty"
    return 1
  }
  mv -f "$tmp" "$bundle" || { rm -f "$tmp"; return 1; }
  chmod 0644 "$bundle" 2>/dev/null || true
  rldyour::log "ok" "compiled offline antidote plugin bundle: ${bundle}"
}

rldyour::install_terminal_configs() {
  local tpl_dir="$1"
  rldyour::section "Install terminal shell configs (zsh-first, agent-gated)"
  rldyour::install_managed_file \
    "$HOME/.config/rldyour/zshenv" \
    "# Managed by macos-ubuntu-bootstrap: terminal-zshenv-v1" 0644 \
    <"$tpl_dir/zshenv"
  rldyour::install_managed_file \
    "$HOME/.config/rldyour/zprofile" \
    "# Managed by macos-ubuntu-bootstrap: terminal-zprofile-v1" 0644 \
    <"$tpl_dir/zprofile"
  rldyour::_ensure_managed_shell_source \
    "$HOME/.zshenv" ".config/rldyour/zshenv" "zshenv-v1"
  rldyour::_ensure_managed_shell_source \
    "$HOME/.zprofile" ".config/rldyour/zprofile" "zprofile-v1"
  rldyour::install_config_template "$tpl_dir/zshrc"           "$HOME/.zshrc"
  rldyour::install_config_template "$tpl_dir/zsh_plugins.txt" "$HOME/.zsh_plugins.txt"
  rldyour::install_config_template "$tpl_dir/starship.toml"   "$HOME/.config/starship.toml"
  rldyour::materialize_zsh_plugins
}
