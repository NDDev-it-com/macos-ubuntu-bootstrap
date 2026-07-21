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

# Install or update a browser-stack-owned file atomically. Existing files are
# changed only when they carry the supplied ownership marker; unmanaged files
# are preserved and make the browser layer fail closed.
rldyour::_install_managed_browser_file() {
  local dest=$1
  local marker=$2
  local mode=${3:-0644}
  local legacy_marker=${4:-}
  local explicitly_owned=${5:-0}
  local parent tmp

  parent="$(dirname "$dest")"
  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    cat >/dev/null
    rldyour::log "info" "[DRY-RUN] install managed browser file: ${dest}"
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
    rldyour::log "error" "unmanaged browser path is not a regular file; preserved: ${dest}"
    return 1
  fi
  if [ -f "$dest" ]; then
    if grep -Fxq "$marker" "$dest"; then
      :
    elif [ -n "$legacy_marker" ] && grep -Fxq "$legacy_marker" "$dest"; then
      rldyour::log "info" "adopting legacy rldyour-managed browser file: ${dest}"
    elif [ "$explicitly_owned" -eq 1 ]; then
      :
    else
      rm -f "$tmp"
      rldyour::log "error" "unmanaged browser file differs; preserved: ${dest}"
      return 1
    fi
  fi
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    chmod "$mode" "$dest" || return 1
    rldyour::log "ok" "managed browser file already current: ${dest}"
    return 0
  fi

  mv -f "$tmp" "$dest" || {
    rm -f "$tmp"
    return 1
  }
  rldyour::log "ok" "installed managed browser file: ${dest}"
}

rldyour::_sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    rldyour::log "error" "sha256sum or shasum is required for runtime identity"
    return 1
  fi
}

# Derive a stable runtime identity from a logical version label and the exact
# repository-owned lock inputs. Absolute checkout paths are intentionally not
# part of the digest so identical inputs converge across devices.
rldyour::_runtime_content_id() {
  local label=$1
  shift
  local source_path

  for source_path in "$@"; do
    if [ ! -f "$source_path" ] || [ -L "$source_path" ]; then
      rldyour::log "error" "runtime identity input must be a regular non-symlink file: ${source_path}"
      return 1
    fi
  done
  {
    printf 'label\0%s\0' "$label"
    for source_path in "$@"; do
      printf 'file\0%s\0' "$(basename "$source_path")"
      cat -- "$source_path"
      printf '\0'
    done
  } | rldyour::_sha256_stream
}

rldyour::_isolated_python() {
  local python_bin=$1
  shift
  env -u PYTHONPATH -u PYTHONHOME "$python_bin" -I "$@"
}

rldyour::_managed_wrapper_replaceable() {
  local destination=$1 marker=$2
  if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
    return 0
  fi
  if [ -L "$destination" ] || [ ! -f "$destination" ] || \
    ! grep -Fxq "$marker" "$destination"; then
    rldyour::log "error" "unmanaged wrapper is preserved: ${destination}"
    return 1
  fi
}

# Publish a complete wrapper set only after every runtime has passed its probes.
# Each destination rename is atomic. If a later rename fails, the already-moved
# files are restored from same-filesystem backups before returning failure.
rldyour::_publish_managed_wrapper_set() {
  local stage=$1 destination_dir=$2 marker=$3
  shift 3
  local -a names=("$@")
  local name rollback_name source destination backup rollback_failed=0 all_current=1

  if [ ! -d "$stage" ] || [ -L "$stage" ]; then
    rldyour::log "error" "wrapper staging directory is invalid: ${stage}"
    return 1
  fi
  mkdir -p "$destination_dir" || return 1
  for name in "${names[@]}"; do
    source="$stage/$name"
    destination="$destination_dir/$name"
    if [ ! -f "$source" ] || [ -L "$source" ] || [ ! -x "$source" ] || \
      ! grep -Fxq "$marker" "$source"; then
      rldyour::log "error" "staged managed wrapper is invalid: ${source}"
      return 1
    fi
    rldyour::_managed_wrapper_replaceable "$destination" "$marker" || return 1
    if [ ! -f "$destination" ] || ! cmp -s "$source" "$destination"; then
      all_current=0
    fi
  done
  if [ "$all_current" -eq 1 ]; then
    for name in "${names[@]}"; do
      chmod 0755 "$destination_dir/$name" || return 1
    done
    rm -rf "$stage"
    rldyour::log "ok" "managed wrapper set already current: ${names[*]}"
    return 0
  fi

  backup="$(mktemp -d "${destination_dir}/.rldyour-wrapper-backup.XXXXXX")" || return 1
  for name in "${names[@]}"; do
    destination="$destination_dir/$name"
    if [ -f "$destination" ]; then
      cp -p "$destination" "$backup/$name" || {
        rm -rf "$backup"
        return 1
      }
    else
      : >"$backup/.absent-$name" || {
        rm -rf "$backup"
        return 1
      }
    fi
  done

  for name in "${names[@]}"; do
    if ! mv -f "$stage/$name" "$destination_dir/$name"; then
      for rollback_name in "${names[@]}"; do
        destination="$destination_dir/$rollback_name"
        if [ -f "$backup/$rollback_name" ]; then
          mv -f "$backup/$rollback_name" "$destination" || rollback_failed=1
        elif [ -f "$backup/.absent-$rollback_name" ]; then
          rm -f "$destination" || rollback_failed=1
        fi
      done
      rm -rf "$backup" "$stage"
      if [ "$rollback_failed" -ne 0 ]; then
        rldyour::log "error" "wrapper publication failed and rollback was incomplete"
      else
        rldyour::log "error" "wrapper publication failed; prior set restored"
      fi
      return 1
    fi
  done
  rm -rf "$backup" "$stage"
  rldyour::log "ok" "published managed wrapper set: ${names[*]}"
}

# One owner per harness (RVR-P1-004). The owner's active harness set is codex and
# zcode. Bootstrap no longer inline-installs any AI CLI and never installs a
# harness through a bun/npm global path or its own frozen bundle. Each harness is
# owned by its dedicated authoritative NDDev module. GDS device bootstrap
# materializes those module checkouts and passes their absolute paths in
# RLDYOUR_CODEX_MODULE and RLDYOUR_ZCODE_MODULE. A module owns its standalone
# artifacts; bootstrap only delegates to the module's own install lifecycle.
# Read a harness module pin (module_repo / module_commit) from the contract.
rldyour::_harness_module_pin() {
  local label=$1 key=$2 common_dir root_dir contract
  common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root_dir="$(cd "$common_dir/../.." && pwd)"
  contract="$root_dir/config/rldyour-contract.json"
  rldyour::_isolated_python python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["harnesses"][sys.argv[2]].get(sys.argv[3], ""))' \
    "$contract" "$label" "$key"
}

# Self-materialize the pinned public harness module (git clone at the exact
# contract commit) into a managed dir when no explicit module path is provided,
# so a clean OS -> bootstrap flow installs codex/zcode with zero manual steps.
# Additive: an explicit RLDYOUR_<H>_MODULE path still wins. Fail-closed.
rldyour::_materialize_harness_module() {
  local label=$1 dest=$2 entry=$3 repo commit
  repo="$(rldyour::_harness_module_pin "$label" module_repo)"
  commit="$(rldyour::_harness_module_pin "$label" module_commit)"
  if [ -z "$repo" ] || [ -z "$commit" ]; then
    rldyour::log "error" "${label} harness module pin is missing from the contract"
    return 1
  fi
  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] materialize ${label} module: git clone ${repo} @ ${commit} -> ${dest}"
    return 0
  fi
  rldyour::_ensure_pinned_git_checkout "$repo" "$commit" "$dest" || return 1
  [ -f "$dest/$entry" ] || {
    rldyour::log "error" "${label} module entrypoint missing after materialize: ${dest}/${entry}"
    return 1
  }
}

rldyour::_validate_harness_module() {
  local label=$1 dir=$2 entry=$3
  # Returns 2 when unset (caller skips), 0 when valid, 1 fail-closed.
  if [ -z "$dir" ]; then
    return 2
  fi
  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
    rldyour::log "error" "${label} module path is set but is not a readable directory: ${dir}"
    return 1
  fi
  if [ ! -f "$dir/$entry" ]; then
    rldyour::log "error" "${label} module entrypoint is missing: ${dir}/${entry}"
    return 1
  fi
  return 0
}

# Delegate the Codex harness to nddev-codex-app. The module installs the pinned
# official Codex CLI standalone release, switches its setup catalog, and installs
# the nddev-builder marketplace. The safe setup is the default; the unrestricted
# full-auto setup is selected only by the explicit owner flag
# RLDYOUR_CODEX_FULL_AUTO=1. install-builder runs AFTER the current-catalog
# install. RLDYOUR_DRY_RUN is respected: a dry run only logs the exact planned
# module commands and performs no install.
rldyour::install_codex_harness() {
  local module=${RLDYOUR_CODEX_MODULE:-}
  local entry="cli-tools/nddev_codex.py"
  local target="${RLDYOUR_CODEX_HOME:-$HOME/.codex}"
  local setup="safe" status

  rldyour::_validate_harness_module "codex" "$module" "$entry"
  status=$?
  if [ "$status" -eq 2 ]; then
    module="$HOME/.local/share/rldyour/harness-modules/nddev-codex-app"
    rldyour::log "info" "RLDYOUR_CODEX_MODULE unset; self-materializing the pinned codex module"
    rldyour::_materialize_harness_module codex "$module" "$entry" || return 1
  elif [ "$status" -ne 0 ]; then
    return 1
  fi

  if [ "${RLDYOUR_CODEX_FULL_AUTO:-0}" -eq 1 ]; then
    setup="full-auto"
    rldyour::log "warn" "codex full-auto setup selected by explicit owner flag RLDYOUR_CODEX_FULL_AUTO=1"
  fi
  rldyour::section "Delegate codex harness to nddev-codex-app (setup: ${setup})"
  # The module owns the standalone Codex CLI artifact under its explicit target;
  # never install codex via a bun/npm global. install-cli installs the pinned
  # official CLI, apply switches to the setup catalog entry, and install-builder
  # adds the nddev-builder marketplace after the catalog install.
  rldyour::run python3 "$module/$entry" install-cli --target "$target" || return 1
  rldyour::run python3 "$module/$entry" apply --setup "$setup" --target "$target" || return 1
  rldyour::run python3 "$module/$entry" install-builder --target "$target" || return 1
}

# Delegate the ZCode harness to nddev-zcode-app. The module owns the standalone
# ZCode desktop app + CLI artifacts and exposes its own plan/apply lifecycle, so
# it is invoked directly with --plan in a dry run (no writes) and --apply
# otherwise. bootstrap installs the pinned app + CLI; the install command builds
# the nddev-builder setup.
rldyour::install_zcode_harness() {
  local module=${RLDYOUR_ZCODE_MODULE:-}
  local entry="cli-tools/scripts/install.sh"
  local status flag

  rldyour::_validate_harness_module "zcode" "$module" "$entry"
  status=$?
  if [ "$status" -eq 2 ]; then
    module="$HOME/.local/share/rldyour/harness-modules/nddev-zcode-app"
    rldyour::log "info" "RLDYOUR_ZCODE_MODULE unset; self-materializing the pinned zcode module"
    rldyour::_materialize_harness_module zcode "$module" "$entry" || return 1
  elif [ "$status" -ne 0 ]; then
    return 1
  fi

  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then flag="--plan"; else flag="--apply"; fi
  rldyour::section "Delegate zcode harness to nddev-zcode-app (nddev-builder setup, ${flag})"
  if [ ! -f "$module/$entry" ]; then
    # Auto-materialized module is not present in dry-run; show the plan only.
    rldyour::log "info" "[DRY-RUN] zcode: bash ${module}/${entry} bootstrap ${flag}; install --setup nddev-builder ${flag}"
    return 0
  fi
  # never install zcode via a bun/npm global; the module owns its artifacts.
  rldyour::log "info" "zcode delegation: bash ${module}/${entry} bootstrap ${flag}"
  bash "$module/$entry" bootstrap "$flag" || {
    rldyour::log "error" "zcode module bootstrap (${flag}) failed"
    return 1
  }
  rldyour::log "info" "zcode delegation: bash ${module}/${entry} install --setup nddev-builder ${flag}"
  bash "$module/$entry" install --setup nddev-builder "$flag" || {
    rldyour::log "error" "zcode module nddev-builder setup (${flag}) failed"
    return 1
  }
}

# Install exactly the owner's active harness set (codex, zcode) by delegating to
# each harness's authoritative NDDev module. Bootstrap must still succeed as a
# standalone run when a module path is unset.
rldyour::install_selected_harnesses() {
  rldyour::section "Install selected harnesses (codex, zcode) via their GDS modules"
  rldyour::install_codex_harness || return 1
  rldyour::install_zcode_harness || return 1
}

# Recognize only the exact launchd/systemd files emitted by pre-marker releases.
# This permits a safe one-time upgrade without treating a service label or a
# human-readable Description field as proof of ownership.
rldyour::_is_legacy_cloak_service_file() {
  local kind=$1 dest=$2 bin_dir=$3 home=$4 profile=$5 fp=$6 port=$7
  rldyour::_isolated_python python3 - "$kind" "$dest" "$bin_dir" "$home" "$profile" "$fp" "$port" <<'PY'
import pathlib
import plistlib
import sys

kind, raw_path, bin_dir, home, profile, fp, port = sys.argv[1:]
path = pathlib.Path(raw_path)
if not path.is_file():
    raise SystemExit(1)

if kind == "launchd":
    expected = {
        "Label": "com.rldyour.cloakbrowser",
        "ProgramArguments": [
            f"{bin_dir}/cloak-chromium",
            "--headless=new",
            "--remote-debugging-address=127.0.0.1",
            f"--remote-debugging-port={port}",
            f"--user-data-dir={profile}",
            "--no-first-run",
            "--no-default-browser-check",
            f"--fingerprint-platform={fp}",
        ],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "StandardErrorPath": f"{home}/daemon.log",
        "StandardOutPath": f"{home}/daemon.log",
    }
    try:
        actual = plistlib.loads(path.read_bytes())
    except Exception:
        raise SystemExit(1)
    raise SystemExit(0 if actual == expected else 1)

if kind == "systemd":
    expected = f'''[Unit]
Description=rldyour CloakBrowser headless CDP endpoint
After=default.target

[Service]
ExecStart={bin_dir}/cloak-chromium --headless=new --remote-debugging-address=127.0.0.1 --remote-debugging-port={port} --user-data-dir={profile} --no-first-run --no-default-browser-check --fingerprint-platform={fp}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
'''
    raise SystemExit(0 if path.read_text(encoding="utf-8") == expected else 1)

raise SystemExit(1)
PY
}

# Legacy launchers are adopted only when their complete contents match a known
# template emitted by an earlier rldyour release. A shared comment substring is
# not sufficient ownership proof.
rldyour::_is_legacy_cloak_launcher_file() {
  local kind=$1 dest=$2 bin_dir=$3 cache=$4 fp=$5
  rldyour::_isolated_python python3 - "$kind" "$dest" "$bin_dir" "$cache" "$fp" <<'PY'
import pathlib
import sys

kind, raw_path, bin_dir, cache, fp = sys.argv[1:]
path = pathlib.Path(raw_path)
if not path.is_file() or path.is_symlink():
    raise SystemExit(1)
actual = path.read_text(encoding="utf-8")

if kind == "chromium":
    candidates = {
        '''#!/usr/bin/env bash
# Managed by rldyour: resolve and exec the CloakBrowser Chromium binary.
# The .app bundle resolves its Frameworks via @executable_path, so we must exec
# the REAL versioned path (never a symlink to the inner MacOS/Chromium).
set -euo pipefail
CB="${CLOAKBROWSER_CACHE_DIR:-$HOME/.local/share/rldyour/cloakbrowser/cache}"
bin="$(/bin/ls -1d "$CB"/chromium-*/Chromium.app/Contents/MacOS/Chromium 2>/dev/null | sort -V | tail -1)"
if [[ -z "${bin:-}" || ! -x "$bin" ]]; then
  echo "cloak-chromium: no CloakBrowser Chromium binary found under $CB" >&2
  exit 127
fi
exec "$bin" "$@"
''',
        f'''#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap. Resolve + exec the CloakBrowser Chromium.
# The .app bundle resolves Frameworks via @executable_path, so exec the REAL
# versioned path (never a symlink to Contents/MacOS/Chromium).
set -euo pipefail
CB="${{CLOAKBROWSER_CACHE_DIR:-{cache}}}"
bin="$(/bin/ls -1d "$CB"/chromium-*/Chromium.app/Contents/MacOS/Chromium "$CB"/chromium-*/chrome 2>/dev/null | sort -V | tail -1)"
if [ -z "${{bin:-}}" ] || [ ! -x "$bin" ]; then
  echo "cloak-chromium: no CloakBrowser Chromium binary under $CB (run bootstrap browser layer)" >&2
  exit 127
fi
exec "$bin" "$@"
''',
    }
elif kind == "stealth":
    candidates = {
        f'''#!/usr/bin/env bash
# Managed by rldyour: CloakBrowser Chromium + default stealth args (manual headless).
exec "$HOME/.local/bin/cloak-chromium" \\
  --no-sandbox --fingerprint-platform={fp} \\
  --no-first-run --no-default-browser-check "$@"
''',
        f'''#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap. CloakBrowser + default stealth args.
exec "{bin_dir}/cloak-chromium" \\
  --no-sandbox --fingerprint-platform="${{CLOAK_FP_PLATFORM:-{fp}}}" \\
  --no-first-run --no-default-browser-check "$@"
''',
    }
else:
    raise SystemExit(1)

raise SystemExit(0 if actual in candidates else 1)
PY
}

# Recognize the fail-closed launcher pair emitted by the current managed stack.
# This is used only to recover a transaction that already upgraded the wrappers
# before restoring an exact legacy home. The embedded absolute binary path and
# SHA-256 must still resolve inside the canonical CloakBrowser cache.
rldyour::_is_current_managed_cloak_launcher_set() {
  local bin_dir=$1 cache=$2 fp=$3 chromium stealth launcher raw_binary binary expected actual
  chromium="$bin_dir/cloak-chromium"
  stealth="$bin_dir/cloak-chromium-stealth"
  for launcher in "$chromium" "$stealth"; do
    [ -f "$launcher" ] && [ ! -L "$launcher" ] || return 1
    [ "$(grep -Fxc '# Managed by macos-ubuntu-bootstrap: browser-stack-v1' "$launcher")" -eq 1 ] || return 1
  done
  [ "$(grep -Fxc "CLOAKBROWSER_CACHE_DIR=\"${cache}\"" "$chromium")" -eq 1 ] || return 1
  [ "$(grep -c '^bin=' "$chromium")" -eq 1 ] || return 1
  raw_binary="$(sed -n 's/^bin=//p' "$chromium")"
  binary="$(rldyour::_isolated_python python3 -c \
    'import shlex, sys; parts = shlex.split(sys.argv[1]); sys.exit(1) if len(parts) != 1 else print(parts[0])' \
    "$raw_binary" 2>/dev/null)" || return 1
  case "$binary" in "$cache"/*) ;; *) return 1 ;; esac
  [ -x "$binary" ] || return 1
  # Match literal managed-wrapper shell variables.
  # shellcheck disable=SC2016
  expected="$(sed -n 's/^if \[ "\$actual_sha256" != "\([0-9a-f]\{64\}\)" \]; then$/\1/p' "$chromium")"
  printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
  actual="$(rldyour::sha256_file "$binary")" || return 1
  [ "$actual" = "$expected" ] || return 1
  # Require the literal final exec contract.
  # shellcheck disable=SC2016
  grep -Fxq 'exec "$bin" "$@"' "$chromium" || return 1
  rldyour::_isolated_python python3 - "$stealth" "$bin_dir" "$fp" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
bin_dir, fingerprint = sys.argv[2:]
expected = f'''#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
# CloakBrowser with safe default fingerprint flags. The Chromium sandbox stays on.
set -euo pipefail
exec "{bin_dir}/cloak-chromium" \\
  --fingerprint-platform="{fingerprint}" \\
  --no-first-run --no-default-browser-check "$@"
'''
raise SystemExit(0 if path.read_text(encoding="utf-8") == expected else 1)
PY
}

rldyour::_playwright_config_owner_valid() {
  local owner=$1
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  rldyour::_isolated_python python3 - "$owner" <<'PY'
import pathlib
import sys

expected = (
    b"# Managed by macos-ubuntu-bootstrap: browser-stack-v1\n"
    b"playwright-cli.json is owned by the managed browser stack.\n"
)
raise SystemExit(0 if pathlib.Path(sys.argv[1]).read_bytes() == expected else 1)
PY
}

# Webwright is retired fail-closed. The browser layer publishes only an exact
# disabled compatibility wrapper; no checkout, Python environment, or browser
# object from Webwright is installed or executed.

# --- CloakBrowser privacy-first Chromium (owner standard) ---------------------
# CloakBrowser is a stealth-hardened Chromium (source-level fingerprint patches)
# used as the DEFAULT browser backend for every active rldyour browser provider
# (Playwright CLI and Chrome DevTools MCP) through one privacy-hardened,
# low-trace engine. The free-tier binary
# (Chromium v146 line) is signature-verified (Ed25519) by the wrapper before use;
# An owner-supplied CLOAKBROWSER_LICENSE_KEY may unlock licensed behavior, but it
# never changes the platform-specific browser build pinned by this repository.
# Platform-agnostic (macOS + Linux).
rldyour::_cloak_home() {
  printf '%s' "$HOME/.local/share/rldyour/cloakbrowser"
}

# These upstream variables intentionally bypass or replace the official signed
# binary flow. They are valid CloakBrowser development features, but they are
# not valid in this production agent boundary. A Pro license remains allowed.
rldyour::_reject_cloak_trust_overrides() {
  local variable
  for variable in \
    CLOAKBROWSER_BINARY_PATH \
    CLOAKBROWSER_DOWNLOAD_URL \
    CLOAKBROWSER_SKIP_CHECKSUM \
    CLOAKBROWSER_VERSION \
    CLOAKBROWSER_WIDEVINE_CDM; do
    if printenv "$variable" >/dev/null 2>&1; then
      rldyour::log "error" "$variable is forbidden by the signed CloakBrowser trust policy"
      return 1
    fi
  done
}

rldyour::_install_cloak_runtime() {
  local pin=$1 home=$2 template_dir=$3 output_var=$4
  local project_source="$template_dir/cloakbrowser-pyproject.toml"
  local lock_source="$template_dir/cloakbrowser-uv.lock"
  local runtimes="$home/runtimes"
  local runtime_label content_id runtime_name destination runtime_marker stage="" installed_version

  runtime_label="cloakbrowser|version=${pin}|platform=$(uname -s)-$(uname -m)"
  content_id="$(rldyour::_runtime_content_id "$runtime_label" "$project_source" "$lock_source")" || return 1
  runtime_name="cloak-${pin}-${content_id}"
  destination="$runtimes/$runtime_name"
  runtime_marker="$destination/.rldyour-runtime"
  if [ -L "$runtimes" ] || { [ -e "$runtimes" ] && [ ! -d "$runtimes" ]; }; then
    rldyour::log "error" "CloakBrowser runtimes path is not a managed directory; preserved: ${runtimes}"
    return 1
  fi
  mkdir -p "$runtimes" || return 1
  chmod 0700 "$runtimes" || return 1
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -d "$destination" ]; }; then
    rldyour::log "error" "CloakBrowser runtime destination is invalid; preserved: ${destination}"
    return 1
  fi
  trap 'if [ -n "${stage:-}" ]; then rm -rf "$stage"; fi; trap - RETURN' RETURN
  if [ ! -d "$destination" ]; then
    stage="$(mktemp -d "$runtimes/.${runtime_name}.staging.XXXXXX")" || return 1
    chmod 0700 "$stage" || return 1
    install -m 0600 "$project_source" "$stage/pyproject.toml" || return 1
    install -m 0600 "$lock_source" "$stage/uv.lock" || return 1
    cat >"$stage/.rldyour-runtime" <<RUNTIME
# Managed by macos-ubuntu-bootstrap: cloakbrowser-runtime-v2
identity=${content_id}
cloakbrowser=${pin}
RUNTIME
    chmod 0600 "$stage/.rldyour-runtime" || return 1
    if ! env -u PYTHONPATH -u PYTHONHOME UV_PROJECT_ENVIRONMENT="$stage/.venv" uv sync \
      --frozen --no-dev --no-install-project --project "$stage" >/dev/null 2>&1; then
      rldyour::log "error" "frozen CloakBrowser staged runtime installation failed"
      return 1
    fi
    installed_version="$(rldyour::_isolated_python "$stage/.venv/bin/python" -c 'from importlib.metadata import version; import cloakbrowser; print(version("cloakbrowser"))' 2>/dev/null || true)"
    if [ "$installed_version" != "$pin" ]; then
      rldyour::log "error" "staged CloakBrowser version/import mismatch: expected ${pin}, got ${installed_version:-unknown}"
      return 1
    fi
    mv "$stage" "$destination" || return 1
    stage=""
  fi

  if [ ! -f "$runtime_marker" ] || [ -L "$runtime_marker" ] || \
    ! grep -Fxq "# Managed by macos-ubuntu-bootstrap: cloakbrowser-runtime-v2" "$runtime_marker" || \
    ! grep -Fxq "identity=${content_id}" "$runtime_marker" || \
    ! cmp -s "$project_source" "$destination/pyproject.toml" || \
    ! cmp -s "$lock_source" "$destination/uv.lock" || \
    [ ! -x "$destination/.venv/bin/python" ]; then
    rldyour::log "error" "content-addressed CloakBrowser runtime identity is invalid; preserved: ${destination}"
    return 1
  fi
  installed_version="$(rldyour::_isolated_python "$destination/.venv/bin/python" -c 'from importlib.metadata import version; import cloakbrowser; print(version("cloakbrowser"))' 2>/dev/null || true)"
  if [ "$installed_version" != "$pin" ]; then
    rldyour::log "error" "published CloakBrowser version/import mismatch: expected ${pin}, got ${installed_version:-unknown}"
    return 1
  fi
  printf -v "$output_var" '%s' "$destination"
  trap - RETURN
}

# Install the CloakBrowser wrapper into an isolated venv, download + verify the
# pinned free-tier Chromium binary, and publish two managed launchers on PATH:
#   cloak-chromium          -> resolves and execs the real versioned binary
#                              (never a symlink: the .app resolves Frameworks via
#                              @executable_path, so the absolute real path is
#                              required for renderer subprocesses to start)
#   cloak-chromium-stealth  -> cloak-chromium + default stealth args (manual runs)
rldyour::install_cloakbrowser() {
  local dry_run="${RLDYOUR_DRY_RUN:-1}"
  local runtime_output_var=${1:-}
  local binary_output_var=${2:-}
  local pin="0.4.12"
  local bin_dir="$HOME/.local/bin"
  local home cache marker_file receipt resolved_binary fp legacy_owned
  local browser_version common_dir root_dir template_dir runtime_home python_bin
  local resolved_binary_q resolved_sha256
  local receipt_path receipt_sha256 current_sha256 preserved_cache
  home="$(rldyour::_cloak_home)"
  cache="$home/cache"
  marker_file="$home/.rldyour-browser-stack"
  receipt="$home/.verified-binary"
  common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root_dir="$(cd "$common_dir/../.." && pwd)"
  template_dir="$root_dir/templates/browser"

  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) browser_version="145.0.7632.109.2" ;;
    Linux:x86_64|Linux:amd64) browser_version="146.0.7680.177.5" ;;
    Linux:aarch64|Linux:arm64) browser_version="146.0.7680.177.3" ;;
    *) browser_version="" ;;
  esac

  rldyour::section "Install CloakBrowser (privacy-first Chromium, pinned ${pin})"
  rldyour::_reject_cloak_trust_overrides || return 1
  if [ "${RLDYOUR_SKIP_CLOAKBROWSER:-0}" -ne 0 ]; then
    rldyour::log "error" "RLDYOUR_SKIP_CLOAKBROWSER is not supported: browser automation must fail closed through CloakBrowser"
    return 1
  fi
  if [ "$dry_run" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] require apply-time commands: uv, python3, curl"
    rldyour::log "info" "[DRY-RUN] build and probe a versioned CloakBrowser ${pin} runtime with isolated Python, then atomically publish it"
    rldyour::log "info" "[DRY-RUN] cloakbrowser.ensure_binary() -> download + Ed25519-verify free Chromium into ${cache}"
    rldyour::log "info" "[DRY-RUN] install fail-closed launchers ${bin_dir}/cloak-chromium[-stealth] and ${bin_dir}/cloakbrowser-cdp-health"
    return 0
  fi

  for command_name in uv python3 curl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      rldyour::log "error" "${command_name} is required for the mandatory CloakBrowser layer"
      return 1
    fi
  done

  if { [ -e "$marker_file" ] || [ -L "$marker_file" ]; } && \
    { [ ! -f "$marker_file" ] || [ -L "$marker_file" ] || ! grep -Fxq "# Managed by macos-ubuntu-bootstrap: browser-stack-v1" "$marker_file"; }; then
    rldyour::log "error" "CloakBrowser ownership marker is invalid; preserved: ${marker_file}"
    return 1
  fi
  if [ -L "$home" ] || { [ -e "$home" ] && [ ! -d "$home" ]; }; then
    rldyour::log "error" "CloakBrowser namespace is not a managed directory; preserved: ${home}"
    return 1
  fi
  if [ -d "$home" ] && [ ! -f "$marker_file" ] && [ -n "$(find "$home" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    rldyour::log "error" "CloakBrowser home exists without a management marker; preserved: ${home}"
    return 1
  fi
  if [ -L "$cache" ] || { [ -e "$cache" ] && [ ! -d "$cache" ]; }; then
    rldyour::log "error" "CloakBrowser cache path is not a managed directory; preserved: ${cache}"
    return 1
  fi
  if [ -L "$receipt" ] || { [ -e "$receipt" ] && [ ! -f "$receipt" ]; }; then
    rldyour::log "error" "CloakBrowser binary receipt path is unsafe; preserved: ${receipt}"
    return 1
  fi

  for required_template in cloakbrowser-pyproject.toml cloakbrowser-uv.lock; do
    if [ ! -f "$template_dir/$required_template" ]; then
      rldyour::log "error" "required CloakBrowser runtime lock template is missing: ${required_template}"
      return 1
    fi
  done

  mkdir -p "$home" "$cache" "$bin_dir" || return 1
  chmod 0700 "$home" "$cache" || return 1
  rldyour::_install_managed_browser_file "$marker_file" "# Managed by macos-ubuntu-bootstrap: browser-stack-v1" 0600 <<'MARKER' || return 1
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
# This dedicated directory may be updated only by the browser bootstrap layer.
MARKER

  rldyour::_install_cloak_runtime "$pin" "$home" "$template_dir" runtime_home || return 1
  python_bin="$runtime_home/.venv/bin/python"
  if [ -e "$receipt" ]; then
    if [ ! -f "$receipt" ] || [ -L "$receipt" ] || \
      ! grep -Fxq "# Managed by macos-ubuntu-bootstrap: browser-stack-v1" "$receipt"; then
      rldyour::log "error" "CloakBrowser binary receipt is invalid; preserved: ${receipt}"
      return 1
    fi
    receipt_path="$(sed -n 's/^path=//p' "$receipt")"
    receipt_sha256="$(sed -n 's/^sha256=//p' "$receipt")"
    if [ "$(grep -c '^path=' "$receipt")" -ne 1 ] || \
      [ "$(grep -c '^sha256=' "$receipt")" -ne 1 ] || \
      ! printf '%s' "$receipt_sha256" | grep -Eq '^[0-9a-f]{64}$' || \
      [ ! -x "$receipt_path" ]; then
      rldyour::log "error" "CloakBrowser binary receipt is incomplete; preserved: ${receipt}"
      return 1
    fi
    current_sha256="$(rldyour::sha256_file "$receipt_path")" || return 1
    if [ "$current_sha256" != "$receipt_sha256" ]; then
      rldyour::log "error" "CloakBrowser cached binary changed since verification; refusing to trust it"
      return 1
    fi
  elif [ -n "$(find "$cache" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    preserved_cache="$home/cache-unverified-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$cache" "$preserved_cache" || return 1
    mkdir -m 0700 "$cache" || return 1
    rldyour::log "warn" "preserved pre-receipt CloakBrowser cache for review: ${preserved_cache}"
  fi
  resolved_binary="$(env -u PYTHONPATH -u PYTHONHOME CLOAKBROWSER_CACHE_DIR="$cache" "$python_bin" -I - "$browser_version" <<'PY'
import sys

from cloakbrowser import ensure_binary

pin = sys.argv[1] or None
print(ensure_binary(browser_version=pin))
PY
)" || resolved_binary=""
  if [ -z "$resolved_binary" ] || [ ! -x "$resolved_binary" ]; then
    rldyour::log "error" "CloakBrowser signed binary download/verification failed"
    return 1
  fi
  if ! "$resolved_binary" --version >/dev/null 2>&1; then
    rldyour::log "error" "verified CloakBrowser binary cannot start; check required system libraries"
    return 1
  fi
  if [ "$(uname -s)" = "Linux" ] && command -v ldd >/dev/null 2>&1 && \
    ldd "$resolved_binary" 2>/dev/null | grep -Fq "not found"; then
    rldyour::log "error" "verified CloakBrowser binary has unresolved shared-library dependencies"
    return 1
  fi
  resolved_sha256="$(rldyour::sha256_file "$resolved_binary")" || return 1
  rldyour::_install_managed_browser_file \
    "$receipt" "# Managed by macos-ubuntu-bootstrap: browser-stack-v1" 0600 <<RECEIPT || return 1
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
package=cloakbrowser@${pin}
path=${resolved_binary}
sha256=${resolved_sha256}
RECEIPT
  printf -v resolved_binary_q '%q' "$resolved_binary"

  case "$(uname -s)" in Darwin) fp="macos" ;; *) fp="linux" ;; esac

  legacy_owned=0
  if rldyour::_is_legacy_cloak_launcher_file chromium "$bin_dir/cloak-chromium" "$bin_dir" "$cache" "$fp"; then
    legacy_owned=1
    rldyour::log "info" "adopting exact legacy rldyour launcher: ${bin_dir}/cloak-chromium"
  fi
  rldyour::_install_managed_browser_file "$bin_dir/cloak-chromium" "# Managed by macos-ubuntu-bootstrap: browser-stack-v1" 0755 "" "$legacy_owned" <<RESOLVE || return 1
#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
# Resolve through CloakBrowser's verified wrapper; never fall back to stock Chrome.
# The .app bundle resolves Frameworks via @executable_path, so exec the REAL
# versioned path (never a symlink to Contents/MacOS/Chromium).
set -euo pipefail
for variable in CLOAKBROWSER_BINARY_PATH CLOAKBROWSER_DOWNLOAD_URL CLOAKBROWSER_SKIP_CHECKSUM CLOAKBROWSER_VERSION CLOAKBROWSER_WIDEVINE_CDM; do
  if printenv "\$variable" >/dev/null 2>&1; then
    echo "cloak-chromium: \$variable is forbidden by the signed browser policy" >&2
    exit 64
  fi
done
CLOAKBROWSER_CACHE_DIR="${cache}"
export CLOAKBROWSER_CACHE_DIR
bin=${resolved_binary_q}
if [ -z "\${bin:-}" ] || [ ! -x "\$bin" ]; then
  echo "cloak-chromium: verified CloakBrowser binary is unavailable" >&2
  exit 127
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256="\$(sha256sum "\$bin" | awk '{ print \$1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual_sha256="\$(shasum -a 256 "\$bin" | awk '{ print \$1 }')"
else
  echo "cloak-chromium: no SHA-256 verifier is available" >&2
  exit 127
fi
if [ "\$actual_sha256" != "${resolved_sha256}" ]; then
  echo "cloak-chromium: verified binary identity changed; rerun bootstrap after investigation" >&2
  exit 126
fi
exec "\$bin" "\$@"
RESOLVE

  legacy_owned=0
  if rldyour::_is_legacy_cloak_launcher_file stealth "$bin_dir/cloak-chromium-stealth" "$bin_dir" "$cache" "$fp"; then
    legacy_owned=1
    rldyour::log "info" "adopting exact legacy rldyour launcher: ${bin_dir}/cloak-chromium-stealth"
  fi
  rldyour::_install_managed_browser_file "$bin_dir/cloak-chromium-stealth" "# Managed by macos-ubuntu-bootstrap: browser-stack-v1" 0755 "" "$legacy_owned" <<STEALTH || return 1
#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
# CloakBrowser with safe default fingerprint flags. The Chromium sandbox stays on.
set -euo pipefail
exec "${bin_dir}/cloak-chromium" \\
  --fingerprint-platform="${fp}" \\
  --no-first-run --no-default-browser-check "\$@"
STEALTH

  rldyour::_install_managed_browser_file "$bin_dir/cloakbrowser-cdp-health" "# Managed by macos-ubuntu-bootstrap: browser-stack-v1" 0755 <<HEALTH || return 1
#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
set -euo pipefail
endpoint="http://127.0.0.1:9222"
profile="${home}/daemon-profile"
cloak_home="${home}"
platform="\$(uname -s)"
service_pid=""

case "\$platform" in
  Darwin)
    service_file="\$HOME/Library/LaunchAgents/com.rldyour.cloakbrowser.plist"
    state="\$(launchctl print "gui/\$(id -u)/com.rldyour.cloakbrowser" 2>/dev/null)" || {
      echo "cloakbrowser-cdp-health: managed launchd service is not loaded" >&2
      exit 1
    }
    service_pid="\$(printf '%s\n' "\$state" | awk '\$1 == "pid" && \$2 == "=" { print \$3; exit }')"
    ;;
  *)
    service_file="\$HOME/.config/systemd/user/rldyour-cloakbrowser.service"
    command -v systemctl >/dev/null 2>&1 || {
      echo "cloakbrowser-cdp-health: systemd user manager is required" >&2
      exit 1
    }
    systemctl --user is-active --quiet rldyour-cloakbrowser.service || {
      echo "cloakbrowser-cdp-health: managed systemd user service is not active" >&2
      exit 1
    }
    service_pid="\$(systemctl --user show rldyour-cloakbrowser.service --property MainPID --value)"
    ;;
esac

service_identity="\$(env -u PYTHONPATH -u PYTHONHOME python3 -I - \
  "\$service_file" "\$platform" "\$profile" <<'PY'
import pathlib
import plistlib
import re
import shlex
import sys

path = pathlib.Path(sys.argv[1])
platform = sys.argv[2]
profile = sys.argv[3]
raw = path.read_bytes()
text = raw.decode("utf-8")
marker = (
    "<!-- Managed by macos-ubuntu-bootstrap: browser-stack-v1 -->"
    if platform == "Darwin"
    else "# Managed by macos-ubuntu-bootstrap: browser-stack-v1"
)
if marker not in text:
    raise SystemExit("managed service marker is missing")
if platform == "Darwin":
    hashes = re.findall(r"<!-- rldyour-binary-sha256: ([0-9a-f]{64}) -->", text)
    config = plistlib.loads(raw)
    arguments = config.get("ProgramArguments")
    fingerprint = "macos"
else:
    hashes = re.findall(r"^# rldyour-binary-sha256=([0-9a-f]{64})$", text, re.MULTILINE)
    exec_lines = re.findall(r"^ExecStart=(.+)$", text, re.MULTILINE)
    if len(exec_lines) != 1:
        raise SystemExit("managed service has an ambiguous ExecStart")
    arguments = shlex.split(exec_lines[0])
    fingerprint = "linux"
if len(hashes) != 1 or not isinstance(arguments, list) or not arguments:
    raise SystemExit("managed service provenance is incomplete")
expected_tail = [
    "--headless=new",
    "--remote-debugging-address=127.0.0.1",
    "--remote-debugging-port=9222",
    f"--user-data-dir={profile}",
    "--no-first-run",
    "--no-default-browser-check",
    f"--fingerprint-platform={fingerprint}",
]
if arguments[1:] != expected_tail:
    raise SystemExit("managed service arguments escaped the fixed CDP contract")
binary = arguments[0]
if not pathlib.Path(binary).is_absolute() or "\n" in binary:
    raise SystemExit("managed service binary path is invalid")
print(binary)
print(hashes[0])
PY
)" || {
  echo "cloakbrowser-cdp-health: managed service provenance is invalid" >&2
  exit 1
}
if [ "\$(printf '%s\n' "\$service_identity" | wc -l | tr -d '[:space:]')" -ne 2 ]; then
  echo "cloakbrowser-cdp-health: managed service provenance is incomplete" >&2
  exit 1
fi
expected_binary="\$(printf '%s\n' "\$service_identity" | sed -n '1p')"
expected_sha256="\$(printf '%s\n' "\$service_identity" | sed -n '2p')"
case "\$expected_binary" in
  "\$cloak_home/cache/"*) ;;
  *)
    echo "cloakbrowser-cdp-health: managed service binary escaped the CloakBrowser cache" >&2
    exit 1
    ;;
esac
if [ ! -x "\$expected_binary" ]; then
  echo "cloakbrowser-cdp-health: managed service binary is unavailable" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  service_binary_sha256="\$(sha256sum "\$expected_binary" | awk '{ print \$1 }')"
elif command -v shasum >/dev/null 2>&1; then
  service_binary_sha256="\$(shasum -a 256 "\$expected_binary" | awk '{ print \$1 }')"
else
  echo "cloakbrowser-cdp-health: no SHA-256 verifier is available" >&2
  exit 1
fi
if [ "\$service_binary_sha256" != "\$expected_sha256" ]; then
  echo "cloakbrowser-cdp-health: managed service binary provenance changed" >&2
  exit 1
fi

case "\$service_pid" in
  ''|0|*[!0-9]*)
    echo "cloakbrowser-cdp-health: managed service PID is unavailable" >&2
    exit 1
    ;;
esac
cmdline="\$(ps -ww -p "\$service_pid" -o command= 2>/dev/null || true)"
case "\$cmdline" in
  *--remote-debugging-address=127.0.0.1*--remote-debugging-port=9222*--user-data-dir="\$profile"*) ;;
  *)
    echo "cloakbrowser-cdp-health: service command does not match the fixed managed endpoint/profile" >&2
    exit 1
    ;;
esac

case "\$platform" in
  Darwin)
    actual_binary="\$(lsof -nP -a -p "\$service_pid" -d txt -Fn 2>/dev/null | awk '/^n/ { print substr(\$0, 2); exit }')"
    ;;
  *)
    actual_binary="\$(readlink -f "/proc/\$service_pid/exe" 2>/dev/null || true)"
    ;;
esac
if [ "\$actual_binary" != "\$expected_binary" ]; then
  echo "cloakbrowser-cdp-health: service executable is not the verified CloakBrowser binary" >&2
  exit 1
fi

# Bind the discovery response to the managed service process, not merely to a
# different CDP-compatible process that happened to win the port race.
case "\$platform" in
  Darwin)
    command -v lsof >/dev/null 2>&1 || {
      echo "cloakbrowser-cdp-health: lsof is required to prove listener ownership" >&2
      exit 1
    }
    lsof -nP -a -p "\$service_pid" -iTCP@127.0.0.1:9222 -sTCP:LISTEN -t 2>/dev/null | grep -Fxq "\$service_pid" || {
      echo "cloakbrowser-cdp-health: fixed CDP listener is not owned by the managed service PID" >&2
      exit 1
    }
    ;;
  *)
    command -v ss >/dev/null 2>&1 || {
      echo "cloakbrowser-cdp-health: ss is required to prove listener ownership" >&2
      exit 1
    }
    listeners="\$(ss -H -ltnp 'sport = :9222' 2>/dev/null || true)"
    case "\$listeners" in
      *127.0.0.1:9222*"pid=\$service_pid,"*) ;;
      *)
        echo "cloakbrowser-cdp-health: fixed CDP listener is not owned by the managed service PID" >&2
        exit 1
        ;;
    esac
    ;;
esac

json="\$(curl --noproxy '*' --fail --silent --show-error --max-time 2 "\$endpoint/json/version")" || {
  echo "cloakbrowser-cdp-health: fixed CDP endpoint is unreachable" >&2
  exit 1
}
printf '%s' "\$json" | env -u PYTHONPATH -u PYTHONHOME python3 -I -c '
import json
import sys
from urllib.parse import urlparse

data = json.load(sys.stdin)
url = urlparse(data.get("webSocketDebuggerUrl", ""))
if url.scheme != "ws" or url.hostname != "127.0.0.1" or url.port != 9222:
    raise SystemExit("cloakbrowser-cdp-health: discovery document escaped the fixed loopback endpoint")
if not data.get("Browser") or not data.get("Protocol-Version"):
    raise SystemExit("cloakbrowser-cdp-health: incomplete CDP discovery document")
'
HEALTH

  export CLOAKBROWSER_CACHE_DIR="$cache"
  export AGENT_BROWSER_EXECUTABLE_PATH="$bin_dir/cloak-chromium"
  export RLDYOUR_BROWSER_CDP_ENDPOINT="http://127.0.0.1:9222"
  export PLAYWRIGHT_MCP_CDP_ENDPOINT="$RLDYOUR_BROWSER_CDP_ENDPOINT"
  export LOCAL_BROWSER_CDP_URL="$RLDYOUR_BROWSER_CDP_ENDPOINT"
  export BROWSER_CDP_URL="$RLDYOUR_BROWSER_CDP_ENDPOINT"
  if [ -n "$runtime_output_var" ]; then
    printf -v "$runtime_output_var" '%s' "$runtime_home"
  fi
  if [ -n "$binary_output_var" ]; then
    printf -v "$binary_output_var" '%s' "$resolved_binary"
  fi
  rldyour::log "ok" "CloakBrowser ${pin} installed with fail-closed launchers under ${bin_dir}"
}

# Install and load a managed background service that runs one headless
# CloakBrowser with a loopback CDP endpoint (127.0.0.1:9222). Every adapter's
# chrome-devtools-mcp connects with --browserUrl, keeping the committed adapter
# configs portable (no per-user absolute paths). launchd on macOS, systemd
# --user on Linux; KeepAlive so the endpoint is always available.
rldyour::_restore_cloak_service_file() {
  local destination=$1 snapshot=$2 prior_present=$3 current_marker=$4
  local restore_tmp

  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    rldyour::log "error" "cannot roll back CloakBrowser service over an unsafe path: ${destination}"
    return 1
  fi
  if [ -f "$destination" ] && ! grep -Fxq "$current_marker" "$destination"; then
    rldyour::log "error" "cannot roll back over a concurrently changed unmanaged service: ${destination}"
    return 1
  fi
  if [ "$prior_present" -eq 0 ]; then
    rm -f "$destination" || return 1
    return 0
  fi
  if [ ! -f "$snapshot" ] || [ -L "$snapshot" ]; then
    rldyour::log "error" "CloakBrowser service rollback snapshot is unavailable"
    return 1
  fi
  mkdir -p "$(dirname "$destination")" || return 1
  restore_tmp="$(mktemp "${destination}.restore.XXXXXX")" || return 1
  if ! cp -p "$snapshot" "$restore_tmp" || ! mv -f "$restore_tmp" "$destination"; then
    rm -f "$restore_tmp"
    return 1
  fi
}

rldyour::_verified_cloak_binary_from_receipt() {
  local home=$1 output_var=$2 sha_output_var=${3:-}
  local receipt="$home/.verified-binary" binary expected_sha256 actual_sha256

  if [ ! -f "$receipt" ] || [ -L "$receipt" ] || \
    ! grep -Fxq "# Managed by macos-ubuntu-bootstrap: browser-stack-v1" "$receipt"; then
    rldyour::log "error" "verified CloakBrowser binary receipt is unavailable: ${receipt}"
    return 1
  fi
  binary="$(sed -n 's/^path=//p' "$receipt")"
  expected_sha256="$(sed -n 's/^sha256=//p' "$receipt")"
  if [ "$(grep -c '^path=' "$receipt")" -ne 1 ] || \
    [ "$(grep -c '^sha256=' "$receipt")" -ne 1 ] || \
    ! printf '%s' "$expected_sha256" | grep -Eq '^[0-9a-f]{64}$' || \
    [ ! -x "$binary" ]; then
    rldyour::log "error" "verified CloakBrowser binary receipt is incomplete"
    return 1
  fi
  case "$binary" in
    "$home/cache/"*) ;;
    *)
      rldyour::log "error" "verified CloakBrowser service binary escaped the managed cache"
      return 1
      ;;
  esac
  actual_sha256="$(rldyour::sha256_file "$binary")" || return 1
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    rldyour::log "error" "verified CloakBrowser service binary identity changed"
    return 1
  fi
  printf -v "$output_var" '%s' "$binary"
  if [ -n "$sha_output_var" ]; then
    printf -v "$sha_output_var" '%s' "$expected_sha256"
  fi
}

rldyour::_cloak_service_file_identity() {
  local kind=$1 service_file=$2 home=$3 profile=$4 output_var=$5 sha_output_var=$6
  local identity binary expected_sha256 actual_sha256

  identity="$(rldyour::_isolated_python python3 - \
    "$kind" "$service_file" "$profile" <<'PY'
import pathlib
import plistlib
import re
import shlex
import sys

kind, raw_path, profile = sys.argv[1:]
path = pathlib.Path(raw_path)
raw = path.read_bytes()
text = raw.decode("utf-8")
if kind == "launchd":
    marker = "<!-- Managed by macos-ubuntu-bootstrap: browser-stack-v1 -->"
    hashes = re.findall(r"<!-- rldyour-binary-sha256: ([0-9a-f]{64}) -->", text)
    arguments = plistlib.loads(raw).get("ProgramArguments")
    fingerprint = "macos"
else:
    marker = "# Managed by macos-ubuntu-bootstrap: browser-stack-v1"
    hashes = re.findall(r"^# rldyour-binary-sha256=([0-9a-f]{64})$", text, re.MULTILINE)
    exec_lines = re.findall(r"^ExecStart=(.+)$", text, re.MULTILINE)
    if len(exec_lines) != 1:
        raise SystemExit(1)
    arguments = shlex.split(exec_lines[0])
    fingerprint = "linux"
if marker not in text or len(hashes) != 1 or not isinstance(arguments, list) or not arguments:
    raise SystemExit(1)
expected_tail = [
    "--headless=new",
    "--remote-debugging-address=127.0.0.1",
    "--remote-debugging-port=9222",
    f"--user-data-dir={profile}",
    "--no-first-run",
    "--no-default-browser-check",
    f"--fingerprint-platform={fingerprint}",
]
if arguments[1:] != expected_tail:
    raise SystemExit(1)
binary = arguments[0]
if not pathlib.Path(binary).is_absolute() or "\n" in binary:
    raise SystemExit(1)
print(binary)
print(hashes[0])
PY
)" || return 1
  if [ "$(printf '%s\n' "$identity" | wc -l | tr -d '[:space:]')" -ne 2 ]; then
    return 1
  fi
  binary="$(printf '%s\n' "$identity" | sed -n '1p')"
  expected_sha256="$(printf '%s\n' "$identity" | sed -n '2p')"
  case "$binary" in "$home/cache/"*) ;; *) return 1 ;; esac
  [ -x "$binary" ] || return 1
  actual_sha256="$(rldyour::sha256_file "$binary")" || return 1
  [ "$actual_sha256" = "$expected_sha256" ] || return 1
  printf -v "$output_var" '%s' "$binary"
  printf -v "$sha_output_var" '%s' "$expected_sha256"
}

rldyour::_active_cloak_service_binary() {
  local kind=$1 home=$2 profile=$3 port=$4 output_var=$5 sha_output_var=$6
  local pid cmdline binary binary_sha256 state

  case "$kind" in
    launchd)
      state="$(launchctl print "gui/$(id -u)/com.rldyour.cloakbrowser" 2>/dev/null)" || return 1
      pid="$(printf '%s\n' "$state" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
      ;;
    systemd)
      pid="$(systemctl --user show rldyour-cloakbrowser.service --property MainPID --value 2>/dev/null)" || return 1
      ;;
    *)
      return 1
      ;;
  esac
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  cmdline="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
  case "$cmdline" in
    *--remote-debugging-address=127.0.0.1*--remote-debugging-port="$port"*--user-data-dir="$profile"*) ;;
    *) return 1 ;;
  esac
  case "$kind" in
    launchd)
      binary="$(lsof -nP -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }')"
      ;;
    systemd)
      binary="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
      ;;
  esac
  case "$binary" in "$home/cache/"*) ;; *) return 1 ;; esac
  [ -x "$binary" ] || return 1
  binary_sha256="$(rldyour::sha256_file "$binary")" || return 1
  printf -v "$output_var" '%s' "$binary"
  printf -v "$sha_output_var" '%s' "$binary_sha256"
}

rldyour::_rollback_cloak_launchd_service() {
  local plist=$1 snapshot=$2 prior_present=$3 prior_active=$4 domain=$5
  local marker="<!-- Managed by macos-ubuntu-bootstrap: browser-stack-v1 -->"
  local failed=0 service_target="${domain}/com.rldyour.cloakbrowser"

  launchctl bootout "$service_target" >/dev/null 2>&1 || true
  if ! rldyour::_wait_launchd_service_state "$service_target" unloaded; then
    rldyour::log "error" "CloakBrowser launchd service did not quiesce during rollback"
    return 1
  fi
  rldyour::_restore_cloak_service_file \
    "$plist" "$snapshot" "$prior_present" "$marker" || failed=1
  if [ "$prior_active" -eq 1 ]; then
    if [ "$failed" -eq 0 ]; then
      # launchctl can report a transient bootstrap error while the job is
      # already becoming visible. The bounded state check is authoritative.
      launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || true
      rldyour::_wait_launchd_service_state "$service_target" loaded || failed=1
    fi
  elif ! rldyour::_wait_launchd_service_state "$service_target" unloaded; then
    failed=1
  fi
  [ "$failed" -eq 0 ]
}

rldyour::_wait_launchd_service_state() {
  local target=$1 expected=$2 attempts=${3:-50} attempt=0 loaded
  while [ "$attempt" -lt "$attempts" ]; do
    loaded=0
    launchctl print "$target" >/dev/null 2>&1 && loaded=1
    case "$expected:$loaded" in
      loaded:1|unloaded:0) return 0 ;;
    esac
    attempt=$((attempt + 1))
    sleep 0.1
  done
  return 1
}

rldyour::_rollback_cloak_systemd_service() {
  local unit=$1 snapshot=$2 prior_present=$3 prior_active=$4 prior_enabled=$5
  local marker="# Managed by macos-ubuntu-bootstrap: browser-stack-v1"
  local service="rldyour-cloakbrowser.service" failed=0

  systemctl --user stop "$service" >/dev/null 2>&1 || failed=1
  if [ "$prior_enabled" -eq 0 ]; then
    systemctl --user disable "$service" >/dev/null 2>&1 || failed=1
  fi
  rldyour::_restore_cloak_service_file \
    "$unit" "$snapshot" "$prior_present" "$marker" || failed=1
  systemctl --user daemon-reload >/dev/null 2>&1 || failed=1
  if [ "$prior_enabled" -eq 1 ]; then
    systemctl --user enable "$service" >/dev/null 2>&1 || failed=1
  fi
  if [ "$prior_active" -eq 1 ]; then
    systemctl --user start "$service" >/dev/null 2>&1 || failed=1
    systemctl --user is-active --quiet "$service" >/dev/null 2>&1 || failed=1
  else
    # The restored state may intentionally have no unit file. The stop before
    # restoration already quiesced the candidate; only a live process now is a
    # rollback failure.
    systemctl --user stop "$service" >/dev/null 2>&1 || true
    if systemctl --user is-active --quiet "$service" >/dev/null 2>&1; then
      failed=1
    fi
  fi
  if [ "$prior_enabled" -eq 1 ]; then
    systemctl --user is-enabled --quiet "$service" >/dev/null 2>&1 || failed=1
  elif systemctl --user is-enabled --quiet "$service" >/dev/null 2>&1; then
    failed=1
  fi
  [ "$failed" -eq 0 ]
}

rldyour::_rollback_cloak_service_handoff() {
  local kind=$1 service_file=$2 snapshot=$3 prior_present=$4
  local prior_active=$5 prior_enabled=$6 domain=$7

  case "$kind" in
    launchd)
      rldyour::_rollback_cloak_launchd_service \
        "$service_file" "$snapshot" "$prior_present" "$prior_active" "$domain"
      ;;
    systemd)
      rldyour::_rollback_cloak_systemd_service \
        "$service_file" "$snapshot" "$prior_present" "$prior_active" "$prior_enabled"
      ;;
    *)
      return 1
      ;;
  esac
}

rldyour::_clear_cloak_daemon_transaction() {
  unset \
    RLDYOUR_CLOAK_DAEMON_TX_KIND \
    RLDYOUR_CLOAK_DAEMON_TX_FILE \
    RLDYOUR_CLOAK_DAEMON_TX_SNAPSHOT \
    RLDYOUR_CLOAK_DAEMON_TX_PRIOR_PRESENT \
    RLDYOUR_CLOAK_DAEMON_TX_PRIOR_ACTIVE \
    RLDYOUR_CLOAK_DAEMON_TX_PRIOR_ENABLED \
    RLDYOUR_CLOAK_DAEMON_TX_PRIOR_LINGER \
    RLDYOUR_CLOAK_DAEMON_TX_DOMAIN
}

rldyour::commit_cloak_daemon_handoff() {
  local snapshot=${RLDYOUR_CLOAK_DAEMON_TX_SNAPSHOT:-}
  [ -z "$snapshot" ] || rm -f "$snapshot" || return 1
  rldyour::_clear_cloak_daemon_transaction
}

rldyour::_set_user_linger() {
  local desired=$1 action expected user

  case "$desired" in
    1|yes|enable)
      action=enable-linger
      expected=yes
      ;;
    0|no|disable)
      action=disable-linger
      expected=no
      ;;
    *) return 2 ;;
  esac
  command -v loginctl >/dev/null 2>&1 || return 1
  user=$(id -un) || return 1
  if ! loginctl "$action" "$user" >/dev/null 2>&1; then
    command -v sudo >/dev/null 2>&1 &&
      sudo -n loginctl "$action" "$user" >/dev/null 2>&1 || return 1
  fi
  loginctl show-user "$user" -p Linger --value 2>/dev/null | grep -q "^${expected}$"
}

rldyour::rollback_cloak_daemon_handoff() {
  local rollback_failed=0 prior_linger=${RLDYOUR_CLOAK_DAEMON_TX_PRIOR_LINGER:--1}
  [ -n "${RLDYOUR_CLOAK_DAEMON_TX_KIND:-}" ] || return 1
  rldyour::_rollback_cloak_service_handoff \
    "$RLDYOUR_CLOAK_DAEMON_TX_KIND" \
    "$RLDYOUR_CLOAK_DAEMON_TX_FILE" \
    "${RLDYOUR_CLOAK_DAEMON_TX_SNAPSHOT:-}" \
    "$RLDYOUR_CLOAK_DAEMON_TX_PRIOR_PRESENT" \
    "$RLDYOUR_CLOAK_DAEMON_TX_PRIOR_ACTIVE" \
    "$RLDYOUR_CLOAK_DAEMON_TX_PRIOR_ENABLED" \
    "${RLDYOUR_CLOAK_DAEMON_TX_DOMAIN:-}" || rollback_failed=1
  if [ "$RLDYOUR_CLOAK_DAEMON_TX_KIND" = "systemd" ] && command -v loginctl >/dev/null 2>&1; then
    if [ "$prior_linger" -eq 0 ]; then
      rldyour::_set_user_linger disable || rollback_failed=1
    elif [ "$prior_linger" -eq 1 ]; then
      rldyour::_set_user_linger enable || rollback_failed=1
    fi
  fi
  [ -z "${RLDYOUR_CLOAK_DAEMON_TX_SNAPSHOT:-}" ] || \
    rm -f "$RLDYOUR_CLOAK_DAEMON_TX_SNAPSHOT" || rollback_failed=1
  rldyour::_clear_cloak_daemon_transaction
  [ "$rollback_failed" -eq 0 ]
}

# Roll back both the service definition and its prior active/enabled state. The
# new file is installed atomically, but a successful file rename is not a
# successful handoff until the service restart and CDP health gate both pass.
rldyour::install_cloakbrowser_daemon() {
  local dry_run="${RLDYOUR_DRY_RUN:-1}"
  local bin_dir="$HOME/.local/bin"
  local port=9222
  local endpoint="http://127.0.0.1:9222"
  local home profile fp attempt legacy_owned
  local service_kind="" service_file="" service_snapshot="" service_domain=""
  local service_prior_present=0 service_prior_active=0 service_prior_enabled=0
  local service_marker service_target service_binary service_sha256 rollback_status
  local service_prior_binary="" service_prior_sha256="" rollback_binary rollback_sha256
  local service_file_binary="" service_file_sha256="" service_file_identity_valid=0
  local service_prior_linger=-1 linger_state="" linger_ok=0
  home="$(rldyour::_cloak_home)"
  profile="$home/daemon-profile"
  case "$(uname -s)" in Darwin) fp="macos" ;; *) fp="linux" ;; esac

  rldyour::section "Install CloakBrowser CDP daemon (${endpoint})"
  if [ -n "${RLDYOUR_CLOAK_DAEMON_TX_KIND:-}" ]; then
    rldyour::log "error" "an unfinished CloakBrowser daemon transaction must be committed or rolled back first"
    return 1
  fi
  if [ -n "${CLOAKBROWSER_CDP_PORT:-}" ] && [ "$CLOAKBROWSER_CDP_PORT" != "$port" ]; then
    rldyour::log "error" "CLOAKBROWSER_CDP_PORT must remain fixed at ${port}"
    return 1
  fi
  if [ "$dry_run" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] managed headless CloakBrowser CDP service on ${endpoint} (KeepAlive)"
    rldyour::log "info" "[DRY-RUN] require managed service identity plus valid /json/version discovery"
    return 0
  fi
  if [ ! -x "$bin_dir/cloak-chromium" ] || [ ! -x "$bin_dir/cloakbrowser-cdp-health" ]; then
    rldyour::log "error" "managed CloakBrowser launchers are missing; refusing to install the daemon"
    return 1
  fi
  rldyour::_verified_cloak_binary_from_receipt \
    "$home" service_binary service_sha256 || return 1
  mkdir -p "$profile" || return 1
  chmod 0700 "$profile" || return 1

  if [ "$fp" = "macos" ]; then
    local xml_launcher xml_service_binary xml_profile xml_log
    service_kind="launchd"
    service_file="$HOME/Library/LaunchAgents/com.rldyour.cloakbrowser.plist"
    service_domain="gui/$(id -u)"
    service_target="${service_domain}/com.rldyour.cloakbrowser"
    service_marker="<!-- Managed by macos-ubuntu-bootstrap: browser-stack-v1 -->"
    command -v launchctl >/dev/null 2>&1 || {
      rldyour::log "error" "launchctl is required for the mandatory CloakBrowser daemon"
      return 1
    }
    xml_launcher="$(rldyour::_isolated_python python3 -c 'import html, sys; print(html.escape(sys.argv[1], quote=True))' "$bin_dir/cloak-chromium")" || return 1
    xml_service_binary="$(rldyour::_isolated_python python3 -c 'import html, sys; print(html.escape(sys.argv[1], quote=True))' "$service_binary")" || return 1
    xml_profile="$(rldyour::_isolated_python python3 -c 'import html, sys; print(html.escape(sys.argv[1], quote=True))' "$profile")" || return 1
    xml_log="$(rldyour::_isolated_python python3 -c 'import html, sys; print(html.escape(sys.argv[1], quote=True))' "$home/daemon.log")" || return 1
    legacy_owned=0
    if rldyour::_is_legacy_cloak_service_file launchd "$service_file" "$bin_dir" "$home" "$profile" "$fp" "$port"; then
      legacy_owned=1
      rldyour::log "info" "adopting exact legacy rldyour launchd service: ${service_file}"
    fi
    if [ -L "$service_file" ] || { [ -e "$service_file" ] && [ ! -f "$service_file" ]; }; then
      rldyour::log "error" "launchd service path is unsafe; preserved: ${service_file}"
      return 1
    fi
    if [ -f "$service_file" ]; then
      if ! grep -Fxq "$service_marker" "$service_file" && [ "$legacy_owned" -ne 1 ]; then
        rldyour::log "error" "unmanaged launchd service is preserved: ${service_file}"
        return 1
      fi
      service_prior_present=1
    fi
    if launchctl print "$service_target" >/dev/null 2>&1; then
      service_prior_active=1
    fi
    if [ "$service_prior_present" -eq 0 ] && [ "$service_prior_active" -eq 1 ]; then
      rldyour::log "error" "loaded launchd label has no managed service file; preserved"
      return 1
    fi
    rollback_binary="$service_binary"
    rollback_sha256="$service_sha256"
    service_file_identity_valid=0
    if [ "$service_prior_present" -eq 1 ]; then
      if rldyour::_cloak_service_file_identity \
        launchd "$service_file" "$home" "$profile" \
        service_file_binary service_file_sha256; then
        service_file_identity_valid=1
        rollback_binary="$service_file_binary"
        rollback_sha256="$service_file_sha256"
      elif grep -Fq "rldyour-binary-sha256:" "$service_file"; then
        rldyour::log "error" "prior launchd service provenance is invalid; preserved"
        return 1
      fi
    fi
    if [ "$service_prior_active" -eq 1 ]; then
      if ! rldyour::_active_cloak_service_binary \
        launchd "$home" "$profile" "$port" \
        service_prior_binary service_prior_sha256; then
        rldyour::log "error" "could not authenticate the active prior launchd CloakBrowser process"
        return 1
      fi
      if [ "$service_file_identity_valid" -eq 1 ] && \
        { [ "$service_prior_binary" != "$service_file_binary" ] || \
          [ "$service_prior_sha256" != "$service_file_sha256" ]; }; then
        rldyour::log "error" "active launchd process differs from its managed immutable service provenance"
        return 1
      fi
      rollback_binary="$service_prior_binary"
      rollback_sha256="$service_prior_sha256"
    fi
    if [ "$service_prior_present" -eq 1 ]; then
      service_snapshot="$(mktemp "$home/.launchd-service-snapshot.XXXXXX")" || return 1
      cp -p "$service_file" "$service_snapshot" || {
        rm -f "$service_snapshot"
        return 1
      }
      # Marker-bearing prior releases may use the stable launcher in the service
      # definition. Normalize those snapshots to the verified immutable binary.
      # An exact markerless legacy service stays byte-identical because the outer
      # home migration also snapshots and restores its matching launcher pair.
      if [ "$legacy_owned" -ne 1 ]; then
        rldyour::_isolated_python python3 - "$service_snapshot" "$xml_launcher" "$rollback_binary" "$rollback_sha256" <<'PY' || {
import html
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
old = f"<string>{sys.argv[2]}</string>"
new = f"<string>{html.escape(sys.argv[3], quote=True)}</string>"
if source.count(old) > 1:
    raise SystemExit("ambiguous stable CloakBrowser launcher in launchd snapshot")
source = source.replace(old, new)
source = re.sub(r"\n?<!-- rldyour-binary-sha256: [0-9a-f]{64} -->", "", source)
marker = "<!-- Managed by macos-ubuntu-bootstrap: browser-stack-v1 -->"
if marker not in source:
    raise SystemExit("managed launchd marker missing from rollback snapshot")
source = source.replace(marker, marker + f"\n<!-- rldyour-binary-sha256: {sys.argv[4]} -->", 1)
path.write_text(source, encoding="utf-8")
PY
          rm -f "$service_snapshot"
          return 1
        }
      fi
    fi
    trap '[ -z "${service_snapshot:-}" ] || rm -f "$service_snapshot"; trap - RETURN' RETURN
    rldyour::_install_managed_browser_file "$service_file" "$service_marker" 0600 "" "$legacy_owned" <<PLIST || return 1
<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by macos-ubuntu-bootstrap: browser-stack-v1 -->
<!-- rldyour-binary-sha256: ${service_sha256} -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.rldyour.cloakbrowser</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xml_service_binary}</string>
    <string>--headless=new</string>
    <string>--remote-debugging-address=127.0.0.1</string>
    <string>--remote-debugging-port=${port}</string>
    <string>--user-data-dir=${xml_profile}</string>
    <string>--no-first-run</string>
    <string>--no-default-browser-check</string>
    <string>--fingerprint-platform=${fp}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>Umask</key><integer>63</integer>
  <key>StandardErrorPath</key><string>${xml_log}</string>
  <key>StandardOutPath</key><string>${xml_log}</string>
</dict>
</plist>
PLIST
    if [ "$service_prior_active" -eq 1 ]; then
      if ! launchctl bootout "$service_target" >/dev/null 2>&1 || \
        ! rldyour::_wait_launchd_service_state "$service_target" unloaded; then
        rollback_status=0
        rldyour::_rollback_cloak_service_handoff \
          "$service_kind" "$service_file" "$service_snapshot" \
          "$service_prior_present" "$service_prior_active" "$service_prior_enabled" \
          "$service_domain" || rollback_status=1
        [ "$rollback_status" -eq 0 ] || rldyour::log "error" "launchd rollback was incomplete"
        rldyour::log "error" "launchctl could not quiesce the prior CloakBrowser service"
        return 1
      fi
    fi
    # launchd unload is asynchronous. Treat bounded state convergence, not the
    # immediate bootstrap exit status, as the handoff commit criterion.
    launchctl bootstrap "$service_domain" "$service_file" >/dev/null 2>&1 || true
    if ! rldyour::_wait_launchd_service_state "$service_target" loaded; then
      rollback_status=0
      rldyour::_rollback_cloak_service_handoff \
        "$service_kind" "$service_file" "$service_snapshot" \
        "$service_prior_present" "$service_prior_active" "$service_prior_enabled" \
        "$service_domain" || rollback_status=1
      [ "$rollback_status" -eq 0 ] || rldyour::log "error" "launchd rollback was incomplete"
      rldyour::log "error" "launchctl bootstrap failed for the mandatory CloakBrowser service"
      return 1
    fi
    rldyour::log "ok" "CloakBrowser launchd service loaded (${endpoint})"
  else
    service_kind="systemd"
    service_file="$HOME/.config/systemd/user/rldyour-cloakbrowser.service"
    service_marker="# Managed by macos-ubuntu-bootstrap: browser-stack-v1"
    command -v systemctl >/dev/null 2>&1 || {
      rldyour::log "error" "systemd --user is required for the mandatory CloakBrowser daemon"
      return 1
    }
    if command -v loginctl >/dev/null 2>&1; then
      linger_state="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
      case "$linger_state" in
        yes) service_prior_linger=1 ;;
        no) service_prior_linger=0 ;;
      esac
    fi
    if [ "${RLDYOUR_PROFILE:-desktop}" = "server" ] && [ "$service_prior_linger" -lt 0 ]; then
      rldyour::log "error" "Ubuntu server requires a queryable systemd linger state before daemon handoff"
      return 1
    fi
    legacy_owned=0
    if rldyour::_is_legacy_cloak_service_file systemd "$service_file" "$bin_dir" "$home" "$profile" "$fp" "$port"; then
      legacy_owned=1
      rldyour::log "info" "adopting exact legacy rldyour systemd service: ${service_file}"
    fi
    if [ -L "$service_file" ] || { [ -e "$service_file" ] && [ ! -f "$service_file" ]; }; then
      rldyour::log "error" "systemd user service path is unsafe; preserved: ${service_file}"
      return 1
    fi
    if [ -f "$service_file" ]; then
      if ! grep -Fxq "$service_marker" "$service_file" && [ "$legacy_owned" -ne 1 ]; then
        rldyour::log "error" "unmanaged systemd user service is preserved: ${service_file}"
        return 1
      fi
      service_prior_present=1
    fi
    if systemctl --user is-active --quiet rldyour-cloakbrowser.service >/dev/null 2>&1; then
      service_prior_active=1
    fi
    if systemctl --user is-enabled --quiet rldyour-cloakbrowser.service >/dev/null 2>&1; then
      service_prior_enabled=1
    fi
    if [ "$service_prior_present" -eq 0 ] && \
      { [ "$service_prior_active" -eq 1 ] || [ "$service_prior_enabled" -eq 1 ]; }; then
      rldyour::log "error" "systemd user service state exists without the managed unit file; preserved"
      return 1
    fi
    rollback_binary="$service_binary"
    rollback_sha256="$service_sha256"
    service_file_identity_valid=0
    if [ "$service_prior_present" -eq 1 ]; then
      if rldyour::_cloak_service_file_identity \
        systemd "$service_file" "$home" "$profile" \
        service_file_binary service_file_sha256; then
        service_file_identity_valid=1
        rollback_binary="$service_file_binary"
        rollback_sha256="$service_file_sha256"
      elif grep -Fq "rldyour-binary-sha256=" "$service_file"; then
        rldyour::log "error" "prior systemd service provenance is invalid; preserved"
        return 1
      fi
    fi
    if [ "$service_prior_active" -eq 1 ]; then
      if ! rldyour::_active_cloak_service_binary \
        systemd "$home" "$profile" "$port" \
        service_prior_binary service_prior_sha256; then
        rldyour::log "error" "could not authenticate the active prior systemd CloakBrowser process"
        return 1
      fi
      if [ "$service_file_identity_valid" -eq 1 ] && \
        { [ "$service_prior_binary" != "$service_file_binary" ] || \
          [ "$service_prior_sha256" != "$service_file_sha256" ]; }; then
        rldyour::log "error" "active systemd process differs from its managed immutable service provenance"
        return 1
      fi
      rollback_binary="$service_prior_binary"
      rollback_sha256="$service_prior_sha256"
    fi
    if [ "$service_prior_present" -eq 1 ]; then
      service_snapshot="$(mktemp "$home/.systemd-service-snapshot.XXXXXX")" || return 1
      cp -p "$service_file" "$service_snapshot" || {
        rm -f "$service_snapshot"
        return 1
      }
      # See the launchd path above. Marker-bearing snapshots are normalized;
      # exact markerless legacy services retain their matching launcher pair.
      if [ "$legacy_owned" -ne 1 ]; then
        rldyour::_isolated_python python3 - "$service_snapshot" "$bin_dir/cloak-chromium" "$rollback_binary" "$rollback_sha256" <<'PY' || {
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
old = f'ExecStart="{sys.argv[2]}"'
new = f'ExecStart="{sys.argv[3]}"'
if source.count(old) > 1:
    raise SystemExit("ambiguous stable CloakBrowser launcher in systemd snapshot")
source = source.replace(old, new)
source = re.sub(r"\n?# rldyour-binary-sha256=[0-9a-f]{64}", "", source)
marker = "# Managed by macos-ubuntu-bootstrap: browser-stack-v1"
if marker not in source:
    raise SystemExit("managed systemd marker missing from rollback snapshot")
source = source.replace(marker, marker + f"\n# rldyour-binary-sha256={sys.argv[4]}", 1)
path.write_text(source, encoding="utf-8")
PY
          rm -f "$service_snapshot"
          return 1
        }
      fi
    fi
    trap '[ -z "${service_snapshot:-}" ] || rm -f "$service_snapshot"; trap - RETURN' RETURN
    rldyour::_install_managed_browser_file "$service_file" "$service_marker" 0600 "" "$legacy_owned" <<UNIT || return 1
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
# rldyour-binary-sha256=${service_sha256}
[Unit]
Description=rldyour CloakBrowser headless CDP endpoint
After=default.target

[Service]
ExecStart="${service_binary}" --headless=new --remote-debugging-address=127.0.0.1 --remote-debugging-port=${port} "--user-data-dir=${profile}" --no-first-run --no-default-browser-check --fingerprint-platform=${fp}
Restart=always
RestartSec=3
UMask=0077

[Install]
WantedBy=default.target
UNIT
    if ! systemctl --user daemon-reload >/dev/null 2>&1; then
      rollback_status=0
      rldyour::_rollback_cloak_service_handoff \
        "$service_kind" "$service_file" "$service_snapshot" \
        "$service_prior_present" "$service_prior_active" "$service_prior_enabled" \
        "$service_domain" || rollback_status=1
      [ "$rollback_status" -eq 0 ] || rldyour::log "error" "systemd rollback was incomplete"
      rldyour::log "error" "systemd --user is required for the mandatory CloakBrowser daemon"
      return 1
    fi
    if ! systemctl --user enable rldyour-cloakbrowser.service >/dev/null 2>&1 || \
      ! systemctl --user restart rldyour-cloakbrowser.service >/dev/null 2>&1; then
      rollback_status=0
      rldyour::_rollback_cloak_service_handoff \
        "$service_kind" "$service_file" "$service_snapshot" \
        "$service_prior_present" "$service_prior_active" "$service_prior_enabled" \
        "$service_domain" || rollback_status=1
      [ "$rollback_status" -eq 0 ] || rldyour::log "error" "systemd rollback was incomplete"
      rldyour::log "error" "systemd --user failed to enable/restart the mandatory CloakBrowser service"
      return 1
    fi
    rldyour::log "ok" "CloakBrowser systemd --user service enabled (${endpoint})"
  fi

  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if "$bin_dir/cloakbrowser-cdp-health" >/dev/null 2>&1; then
      if [ "$service_kind" = "systemd" ]; then
        if ! systemctl --user is-enabled --quiet rldyour-cloakbrowser.service >/dev/null 2>&1; then
          rollback_status=0
          rldyour::_rollback_cloak_service_handoff \
            "$service_kind" "$service_file" "$service_snapshot" \
            "$service_prior_present" "$service_prior_active" "$service_prior_enabled" \
            "$service_domain" || rollback_status=1
          [ "$rollback_status" -eq 0 ] || rldyour::log "error" "systemd rollback was incomplete"
          rldyour::log "error" "CloakBrowser user service is active but not enabled"
          return 1
        fi

        # Linger is part of the server commit: without it, a healthy user unit
        # dies at SSH logout. Desktop sessions may explicitly remain degraded.
        linger_ok=0
        if command -v loginctl >/dev/null 2>&1 && \
          loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -q '^yes$'; then
          linger_ok=1
        elif command -v loginctl >/dev/null 2>&1; then
          if rldyour::_set_user_linger enable; then
            linger_ok=1
            rldyour::log "ok" "enabled systemd linger for $(id -un)"
          fi
        fi
        if [ "$linger_ok" -ne 1 ]; then
          if [ "${RLDYOUR_PROFILE:-desktop}" = "server" ]; then
            rollback_status=0
            rldyour::_rollback_cloak_service_handoff \
              "$service_kind" "$service_file" "$service_snapshot" \
              "$service_prior_present" "$service_prior_active" "$service_prior_enabled" \
              "$service_domain" || rollback_status=1
            if [ "$service_prior_linger" -eq 0 ] && command -v loginctl >/dev/null 2>&1; then
              rldyour::_set_user_linger disable || rollback_status=1
            elif [ "$service_prior_linger" -eq 1 ] && command -v loginctl >/dev/null 2>&1; then
              rldyour::_set_user_linger enable || rollback_status=1
            fi
            [ "$rollback_status" -eq 0 ] || rldyour::log "error" "server daemon/linger rollback was incomplete"
            rldyour::log "error" "Ubuntu server requires systemd Linger=yes for persistent CloakBrowser"
            return 1
          fi
          rldyour::log "warn" "could not enable linger; desktop service remains active only while the user manager runs"
        fi
      fi
      if [ "${RLDYOUR_DEFER_CLOAK_DAEMON_COMMIT:-0}" -eq 1 ]; then
        RLDYOUR_CLOAK_DAEMON_TX_KIND=$service_kind
        RLDYOUR_CLOAK_DAEMON_TX_FILE=$service_file
        RLDYOUR_CLOAK_DAEMON_TX_SNAPSHOT=$service_snapshot
        RLDYOUR_CLOAK_DAEMON_TX_PRIOR_PRESENT=$service_prior_present
        RLDYOUR_CLOAK_DAEMON_TX_PRIOR_ACTIVE=$service_prior_active
        RLDYOUR_CLOAK_DAEMON_TX_PRIOR_ENABLED=$service_prior_enabled
        RLDYOUR_CLOAK_DAEMON_TX_PRIOR_LINGER=$service_prior_linger
        RLDYOUR_CLOAK_DAEMON_TX_DOMAIN=$service_domain
        service_snapshot=""
        trap - RETURN
      else
        [ -z "$service_snapshot" ] || rm -f "$service_snapshot"
        service_snapshot=""
        trap - RETURN
      fi
      rldyour::log "ok" "CloakBrowser CDP health gate passed (${endpoint})"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.2
  done
  "$bin_dir/cloakbrowser-cdp-health" || true
  rollback_status=0
  rldyour::_rollback_cloak_service_handoff \
    "$service_kind" "$service_file" "$service_snapshot" \
    "$service_prior_present" "$service_prior_active" "$service_prior_enabled" \
    "$service_domain" || rollback_status=1
  if [ "$rollback_status" -eq 0 ]; then
    rldyour::log "warn" "restored the prior CloakBrowser service after failed health handoff"
  else
    rldyour::log "error" "CloakBrowser service rollback was incomplete"
  fi
  rldyour::log "error" "CloakBrowser CDP service failed its mandatory health gate"
  return 1
}

# Install rtk (Rust Token Killer, Apache-2.0), the token-economy shell-output
# compressor the Claude and Codex adapters drive through their PreToolUse hooks
# / rules file. Pinned to RTK_VERSION. Also writes the machine-global rtk config
# with the exclude_commands baseline that protects hook-watched git commands and
# validator/JSON output (control-plane config/token-economy-policy.json, ADR 0004).
# The managed binary is installed from a hash-pinned release artifact. Existing
# package-manager installations outside ~/.local/bin are preserved; the managed
# launcher wins through rldyour::ensure_path. Skip only as an explicit recovery
# action with RLDYOUR_SKIP_RTK=1.
rldyour::install_rtk() {
  local dry_run="${RLDYOUR_DRY_RUN:-1}"
  local pin="0.43.0"
  local cfg_home cfg artifact_url artifact_sha256
  local namespace version_dir destination receipt launcher archive stage extracted publish_tmp
  local actual_version binary_sha256 receipt_sha256 existing_version backup
  namespace="$HOME/.local/share/rldyour/rtk"
  version_dir="$namespace/$pin"
  destination="$namespace/$pin/rtk"
  receipt="$namespace/$pin/rtk.sha256"
  launcher="$HOME/.local/bin/rtk"

  case "$(uname -s):$(uname -m)" in
    Darwin:arm64)
      cfg_home="$HOME/Library/Application Support/rtk"
      artifact_url="https://github.com/rtk-ai/rtk/releases/download/v${pin}/rtk-aarch64-apple-darwin.tar.gz"
      artifact_sha256="8a17e49acbd378997eb21d0eb6f7f861111f35b4fc9b1c74edf4c7448e576c65"
      ;;
    Linux:x86_64|Linux:amd64)
      cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}/rtk"
      artifact_url="https://github.com/rtk-ai/rtk/releases/download/v${pin}/rtk-x86_64-unknown-linux-musl.tar.gz"
      artifact_sha256="ff8a1e7766496e175291a85aeca1dc97c9ff6df33e51e5893d1fbc78fea2a609"
      ;;
    Linux:aarch64|Linux:arm64)
      cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}/rtk"
      artifact_url="https://github.com/rtk-ai/rtk/releases/download/v${pin}/rtk-aarch64-unknown-linux-gnu.tar.gz"
      artifact_sha256="5519f7ca12e5c143a609f0d28a0a77b97413a8dce31c2681f1a41c24519a8731"
      ;;
    *)
      rldyour::log "error" "RTK ${pin} has no tracked artifact for $(uname -s)/$(uname -m)"
      return 1
      ;;
  esac
  cfg="$cfg_home/config.toml"

  rldyour::section "Install rtk token-economy CLI (pinned ${pin})"
  if [ "${RLDYOUR_SKIP_RTK:-0}" -ne 0 ]; then
    rldyour::log "warn" "rtk layer skipped by RLDYOUR_SKIP_RTK"
    return 0
  fi

  if [ "$dry_run" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] install RTK ${pin} from its hash-pinned release artifact and publish a tamper-evident managed launcher"
    rldyour::log "info" "[DRY-RUN] write ${cfg} with [hooks] exclude_commands baseline"
    return 0
  fi

  # crates.io 'rtk' is a different tool (Rust Type Kit); never `cargo install rtk`.
  if [ -L "$namespace" ] || { [ -e "$namespace" ] && [ ! -d "$namespace" ]; } || \
    [ -L "$version_dir" ] || { [ -e "$version_dir" ] && [ ! -d "$version_dir" ]; }; then
    rldyour::log "error" "RTK managed namespace is unsafe; preserved: ${namespace}"
    return 1
  fi
  if [ -L "$receipt" ] || { [ -e "$receipt" ] && [ ! -f "$receipt" ]; }; then
    rldyour::log "error" "RTK receipt path is unsafe; preserved: ${receipt}"
    return 1
  fi
  mkdir -p "$namespace" "$HOME/.local/bin" || return 1
  chmod 0700 "$namespace" || return 1
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -f "$destination" ] || [ ! -x "$destination" ] || \
      [ ! -f "$receipt" ] || [ -L "$receipt" ] || \
      ! grep -Fxq "# Managed by macos-ubuntu-bootstrap: rtk-v1" "$receipt"; then
      rldyour::log "error" "managed RTK destination or receipt is invalid; preserved: ${destination}"
      return 1
    fi
    receipt_sha256="$(sed -n 's/^sha256=//p' "$receipt")"
    if [ "$(grep -c '^sha256=' "$receipt")" -ne 1 ] || \
      ! printf '%s' "$receipt_sha256" | grep -Eq '^[0-9a-f]{64}$' || \
      [ "$(rldyour::sha256_file "$destination")" != "$receipt_sha256" ]; then
      rldyour::log "error" "managed RTK binary identity changed; refusing to replace it"
      return 1
    fi
  else
    archive="$(mktemp)"; stage="$(mktemp -d)"; publish_tmp=""
    trap 'rm -rf "$archive" "$stage"; [ -z "${publish_tmp:-}" ] || rm -f "$publish_tmp"; trap - RETURN' RETURN
    rldyour::download_verified_file "$artifact_url" "$artifact_sha256" "$archive" || return 1
    tar -xzf "$archive" -C "$stage" || return 1
    extracted="$stage/rtk"
    [ -f "$extracted" ] || {
      rldyour::log "error" "RTK archive did not contain the expected executable"
      return 1
    }
    chmod 0755 "$extracted" || return 1
    actual_version="$("$extracted" --version 2>/dev/null | head -n 1)"
    if ! printf '%s' "$actual_version" | grep -Eq "^rtk[[:space:]]+${pin}([[:space:]]|$)"; then
      rldyour::log "error" "RTK artifact version mismatch: expected ${pin}, got ${actual_version:-unknown}"
      return 1
    fi
    mkdir -p "$(dirname "$destination")" || return 1
    chmod 0700 "$(dirname "$destination")" || return 1
    publish_tmp="$(mktemp "$(dirname "$destination")/.rtk.tmp.XXXXXX")" || return 1
    install -m 0755 "$extracted" "$publish_tmp" || return 1
    binary_sha256="$(rldyour::sha256_file "$publish_tmp")" || return 1
    # Receipt-first publication makes an interrupted install resumable while
    # preserving the invariant that no managed binary exists without identity.
    rldyour::_install_managed_browser_file \
      "$receipt" "# Managed by macos-ubuntu-bootstrap: rtk-v1" 0600 <<RECEIPT || return 1
# Managed by macos-ubuntu-bootstrap: rtk-v1
version=${pin}
sha256=${binary_sha256}
RECEIPT
    mv "$publish_tmp" "$destination" || return 1
    publish_tmp=""
    rm -rf "$archive" "$stage"
    trap - RETURN
  fi

  if [ -e "$launcher" ] && [ ! -L "$launcher" ] && \
    ! grep -Fxq "# Managed by macos-ubuntu-bootstrap: rtk-v1" "$launcher"; then
    existing_version="$("$launcher" --version 2>/dev/null | head -n 1 || true)"
    if ! printf '%s' "$existing_version" | grep -Eq '^rtk[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+'; then
      rldyour::log "error" "unmanaged ~/.local/bin/rtk is not a recognized RTK binary; preserved"
      return 1
    fi
    backup="$namespace/legacy-$(printf '%s' "$existing_version" | tr -cd '0-9.')-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$backup" || return 1
    mv "$launcher" "$backup/rtk" || return 1
    rldyour::log "info" "preserved legacy RTK binary: ${backup}/rtk"
  elif [ -L "$launcher" ]; then
    case "$(readlink "$launcher")" in
      "$namespace"/*) rm -f "$launcher" || return 1 ;;
      *) rldyour::log "error" "unmanaged rtk symlink exists; preserved: ${launcher}"; return 1 ;;
    esac
  fi

  binary_sha256="$(rldyour::sha256_file "$destination")" || return 1
  rldyour::_install_managed_browser_file \
    "$launcher" "# Managed by macos-ubuntu-bootstrap: rtk-v1" 0755 <<LAUNCHER || return 1
#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap: rtk-v1
set -euo pipefail
binary="${destination}"
expected="${binary_sha256}"
if command -v sha256sum >/dev/null 2>&1; then
  actual="\$(sha256sum "\$binary" | awk '{ print \$1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual="\$(shasum -a 256 "\$binary" | awk '{ print \$1 }')"
else
  echo "rtk: no SHA-256 verifier is available" >&2
  exit 127
fi
[ "\$actual" = "\$expected" ] || { echo "rtk: managed binary identity changed" >&2; exit 126; }
exec "\$binary" "\$@"
LAUNCHER
  actual_version="$("$launcher" --version 2>/dev/null | head -n 1)"
  printf '%s' "$actual_version" | grep -Eq "^rtk[[:space:]]+${pin}([[:space:]]|$)" || {
    rldyour::log "error" "managed RTK launcher verification failed"
    return 1
  }

  # Idempotent: write the exclude_commands baseline only when absent so an owner's
  # edits are never clobbered.
  if [ -L "$cfg" ] || { [ -e "$cfg" ] && [ ! -f "$cfg" ]; }; then
    rldyour::log "error" "unmanaged RTK config path is not a regular file; preserved: ${cfg}"
    return 1
  elif [ ! -f "$cfg" ]; then
    mkdir -p "$cfg_home"
    cat > "$cfg" <<'RTKCFG'
# Managed by macos-ubuntu-bootstrap (token-economy standard; control-plane
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
    chmod 0600 "$cfg"
    rldyour::log "ok" "wrote rtk config with exclude_commands baseline: ${cfg}"
  else
    rldyour::log "info" "rtk config already present (kept): ${cfg}"
  fi
}

# Build and publish the Node-based browser providers as one immutable runtime.
# Output variables receive absolute provider paths only after the destination
# tree exists and all exact-version/executable probes have passed.
rldyour::_install_browser_config_bundle() {
  local browser_home=$1 template_dir=$2 output_var=$3
  local playwright_source="$template_dir/playwright-cli.json"
  local runtimes="$browser_home/config-runtimes"
  local content_id destination runtime_marker stage=""

  content_id="$(rldyour::_runtime_content_id \
    "browser-config|schema=3" "$playwright_source")" || return 1
  destination="$runtimes/config-${content_id}"
  runtime_marker="$destination/.rldyour-runtime"
  if [ -L "$runtimes" ] || { [ -e "$runtimes" ] && [ ! -d "$runtimes" ]; }; then
    rldyour::log "error" "browser config runtimes path is not a managed directory; preserved: ${runtimes}"
    return 1
  fi
  if ! rldyour::_isolated_python python3 - "$playwright_source" <<'PY'
import json
import pathlib
import sys

playwright = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected_playwright = {
    "browser": {
        "browserName": "chromium",
        "isolated": False,
        "remoteEndpoint": None,
        "cdpEndpoint": "http://127.0.0.1:9222",
        "cdpTimeout": 5000,
    }
}
if playwright != expected_playwright:
    raise SystemExit("managed Playwright config escaped the fixed CDP contract")
PY
  then
    rldyour::log "error" "browser routing templates failed their exact fail-closed contract"
    return 1
  fi

  mkdir -p "$runtimes" || return 1
  chmod 0700 "$runtimes" || return 1
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -d "$destination" ]; }; then
    rldyour::log "error" "browser config runtime destination is invalid; preserved: ${destination}"
    return 1
  fi
  trap 'if [ -n "${stage:-}" ]; then rm -rf "$stage"; fi; trap - RETURN' RETURN
  if [ ! -d "$destination" ]; then
    stage="$(mktemp -d "$runtimes/.config-${content_id}.staging.XXXXXX")" || return 1
    chmod 0700 "$stage" || return 1
    install -m 0600 "$playwright_source" "$stage/playwright-cli.json" || return 1
    cat >"$stage/.rldyour-runtime" <<RUNTIME
# Managed by macos-ubuntu-bootstrap: browser-config-runtime-v3
identity=${content_id}
RUNTIME
    chmod 0600 "$stage/.rldyour-runtime" || return 1
    mv "$stage" "$destination" || return 1
    stage=""
  fi
  if [ ! -f "$runtime_marker" ] || [ -L "$runtime_marker" ] || \
    ! grep -Fxq "# Managed by macos-ubuntu-bootstrap: browser-config-runtime-v3" "$runtime_marker" || \
    ! grep -Fxq "identity=${content_id}" "$runtime_marker" || \
    ! cmp -s "$playwright_source" "$destination/playwright-cli.json"; then
    rldyour::log "error" "content-addressed browser config runtime identity is invalid; preserved: ${destination}"
    return 1
  fi
  printf -v "$output_var" '%s' "$destination"
  trap - RETURN
}

# Bun packages may arrive with group-writable entrypoints even under a private
# umask. Normalize a freshly staged tree before publication, and validate every
# reused tree. Symlinks are allowed only when they resolve back inside the same
# content-addressed runtime; all material files and directories must be owned by
# the current UID and must never remain group/world-writable.
rldyour::_browser_node_runtime_permissions() {
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

rldyour::_install_browser_node_bundle() {
  local chrome_version=$1 playwright_version=$2 browser_home=$3
  local manifest_source=$4 lock_source=$5 chrome_output_var=$6 playwright_output_var=$7
  local runtime_output_var=${8:-}
  local runtimes="$browser_home/node-runtimes"
  local runtime_label content_id runtime_name destination runtime_marker stage=""
  local rebuild_unsafe=0 preserved=""
  local chrome_path playwright_path actual_chrome actual_playwright

  runtime_label="browser-node|chrome=${chrome_version}|playwright=${playwright_version}|platform=$(uname -s)-$(uname -m)"
  content_id="$(rldyour::_runtime_content_id "$runtime_label" "$manifest_source" "$lock_source")" || return 1
  runtime_name="node-${chrome_version}-${playwright_version}-${content_id}"
  destination="$runtimes/$runtime_name"
  runtime_marker="$destination/.rldyour-runtime"

  if [ -L "$runtimes" ] || { [ -e "$runtimes" ] && [ ! -d "$runtimes" ]; }; then
    rldyour::log "error" "browser Node runtimes path is not a managed directory; preserved: ${runtimes}"
    return 1
  fi
  mkdir -p "$runtimes" || return 1
  chmod 0700 "$runtimes" || return 1
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -d "$destination" ]; }; then
    rldyour::log "error" "browser Node runtime destination is invalid; preserved: ${destination}"
    return 1
  fi
  if [ -d "$destination" ]; then
    if [ ! -f "$runtime_marker" ] || [ -L "$runtime_marker" ] || \
      ! grep -Fxq "# Managed by macos-ubuntu-bootstrap: browser-node-runtime-v2" "$runtime_marker" || \
      ! grep -Fxq "identity=${content_id}" "$runtime_marker" || \
      ! cmp -s "$manifest_source" "$destination/package.json" || \
      ! cmp -s "$lock_source" "$destination/bun.lock"; then
      rldyour::log "error" "content-addressed browser Node runtime identity is invalid; preserved: ${destination}"
      return 1
    fi
    if ! rldyour::_browser_node_runtime_permissions validate "$destination"; then
      rebuild_unsafe=1
      rldyour::log "warn" "browser Node runtime permissions are unsafe; rebuilding from the frozen lock"
    fi
  fi
  trap 'if [ -n "${stage:-}" ]; then rm -rf "$stage"; fi; trap - RETURN' RETURN
  if [ ! -d "$destination" ] || [ "$rebuild_unsafe" -eq 1 ]; then
    stage="$(mktemp -d "$runtimes/.${runtime_name}.staging.XXXXXX")" || return 1
    chmod 0700 "$stage" || return 1
    install -m 0600 "$manifest_source" "$stage/package.json" || return 1
    install -m 0600 "$lock_source" "$stage/bun.lock" || return 1
    cat >"$stage/.rldyour-runtime" <<RUNTIME
# Managed by macos-ubuntu-bootstrap: browser-node-runtime-v2
identity=${content_id}
chrome_devtools_mcp=${chrome_version}
playwright_cli=${playwright_version}
RUNTIME
    chmod 0600 "$stage/.rldyour-runtime" || return 1
    if ! bun install --cwd "$stage" --frozen-lockfile --ignore-scripts \
      --production >/dev/null 2>&1; then
      rldyour::log "error" "isolated browser provider staging installation failed"
      return 1
    fi
    if ! rldyour::_browser_node_runtime_permissions normalize "$stage"; then
      rldyour::log "error" "staged browser provider runtime permissions are unsafe"
      return 1
    fi
    chrome_path="$stage/node_modules/.bin/chrome-devtools-mcp"
    playwright_path="$stage/node_modules/.bin/playwright-cli"
    actual_chrome="$(rldyour::_isolated_python python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$stage/node_modules/chrome-devtools-mcp/package.json" 2>/dev/null || true)"
    actual_playwright="$(rldyour::_isolated_python python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$stage/node_modules/@playwright/cli/package.json" 2>/dev/null || true)"
    if [ "$actual_chrome" != "$chrome_version" ] || [ ! -x "$chrome_path" ]; then
      rldyour::log "error" "staged chrome-devtools-mcp pin verification failed: expected ${chrome_version}, got ${actual_chrome:-unknown}"
      return 1
    fi
    if [ "$actual_playwright" != "$playwright_version" ] || [ ! -x "$playwright_path" ]; then
      rldyour::log "error" "staged Playwright CLI pin verification failed: expected ${playwright_version}, got ${actual_playwright:-unknown}"
      return 1
    fi
    if ! CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1 CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1 \
      "$chrome_path" --version >/dev/null 2>&1 || \
      ! NO_UPDATE_NOTIFIER=1 "$playwright_path" --version >/dev/null 2>&1; then
      rldyour::log "error" "staged browser provider executable smoke check failed"
      return 1
    fi
    if [ "$rebuild_unsafe" -eq 1 ]; then
      preserved="$runtimes/.${runtime_name}.unsafe-$(date -u +%Y%m%dT%H%M%SZ)"
      [ ! -e "$preserved" ] && [ ! -L "$preserved" ] || return 1
      mv "$destination" "$preserved" || return 1
      if ! mv "$stage" "$destination"; then
        mv "$preserved" "$destination" || \
          rldyour::log "error" "browser Node runtime rebuild and restoration both failed"
        return 1
      fi
      rldyour::log "warn" "preserved replaced unsafe browser Node runtime: ${preserved}"
    else
      mv "$stage" "$destination" || return 1
    fi
    stage=""
  fi

  if [ ! -f "$runtime_marker" ] || [ -L "$runtime_marker" ] || \
    ! grep -Fxq "# Managed by macos-ubuntu-bootstrap: browser-node-runtime-v2" "$runtime_marker" || \
    ! grep -Fxq "identity=${content_id}" "$runtime_marker" || \
    ! cmp -s "$manifest_source" "$destination/package.json" || \
    ! cmp -s "$lock_source" "$destination/bun.lock"; then
    rldyour::log "error" "content-addressed browser Node runtime identity is invalid; preserved: ${destination}"
    return 1
  fi
  if ! rldyour::_browser_node_runtime_permissions validate "$destination"; then
    rldyour::log "error" "published browser Node runtime permissions are unsafe"
    return 1
  fi
  chrome_path="$destination/node_modules/.bin/chrome-devtools-mcp"
  playwright_path="$destination/node_modules/.bin/playwright-cli"
  actual_chrome="$(rldyour::_isolated_python python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$destination/node_modules/chrome-devtools-mcp/package.json" 2>/dev/null || true)"
  actual_playwright="$(rldyour::_isolated_python python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$destination/node_modules/@playwright/cli/package.json" 2>/dev/null || true)"
  if [ "$actual_chrome" != "$chrome_version" ] || [ ! -x "$chrome_path" ] || \
    [ "$actual_playwright" != "$playwright_version" ] || [ ! -x "$playwright_path" ]; then
    rldyour::log "error" "published browser Node runtime failed exact identity probes"
    return 1
  fi
  if ! CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1 CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1 \
    "$chrome_path" --version >/dev/null 2>&1 || \
    ! NO_UPDATE_NOTIFIER=1 "$playwright_path" --version >/dev/null 2>&1; then
    rldyour::log "error" "published browser provider executable smoke check failed"
    return 1
  fi
  printf -v "$chrome_output_var" '%s' "$chrome_path"
  printf -v "$playwright_output_var" '%s' "$playwright_path"
  if [ -n "$runtime_output_var" ]; then
    printf -v "$runtime_output_var" '%s' "$destination"
  fi
  trap - RETURN
}

# Publish one canonical receipt only after every browser runtime, wrapper, and
# service invariant has been proven against the repository policy. An existing
# receipt must first prove its ownership and self-integrity; divergent local
# state is preserved and the installer fails closed.
rldyour::_publish_browser_runtime_receipt() {
  local browser_home=$1 cloak_runtime=$2 cloak_binary=$3 node_runtime=$4 config_runtime=$5
  local common_dir root_dir integrity_script verify_script receipt stage_dir="" stage_receipt policy_file
  common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root_dir="$(cd "$common_dir/../.." && pwd)"
  integrity_script="$root_dir/scripts/browser_runtime_integrity.py"
  verify_script="$root_dir/scripts/verify-browser-runtime.sh"
  receipt="$browser_home/browser-runtime-receipt.json"

  for policy_file in "$integrity_script" "$verify_script"; do
    if [ ! -f "$policy_file" ] || [ -L "$policy_file" ]; then
      rldyour::log "error" "browser runtime integrity policy is missing or unsafe: ${policy_file}"
      return 1
    fi
  done
  if { [ -e "$receipt" ] || [ -L "$receipt" ]; } && \
    { [ ! -f "$receipt" ] || [ -L "$receipt" ] || \
      ! env -u PYTHONPATH -u PYTHONHOME python3 -I "$integrity_script" \
        metadata-only --receipt "$receipt" >/dev/null; }; then
    rldyour::log "error" "browser runtime receipt is unmanaged or corrupt; preserved: ${receipt}"
    return 1
  fi

  stage_dir="$(mktemp -d "$browser_home/.browser-runtime-receipt.XXXXXX")" || return 1
  chmod 0700 "$stage_dir" || { rm -rf "$stage_dir"; return 1; }
  stage_receipt="$stage_dir/receipt.json"
  trap 'if [ -n "${stage_dir:-}" ]; then rm -rf "$stage_dir"; fi; trap - RETURN' RETURN
  if ! env -u PYTHONPATH -u PYTHONHOME python3 -I "$integrity_script" build \
    --output "$stage_receipt" \
    --cloak-runtime "$cloak_runtime" \
    --cloak-binary "$cloak_binary" \
    --node-runtime "$node_runtime" \
    --config-runtime "$config_runtime" >/dev/null; then
    rldyour::log "error" "installed browser runtime did not satisfy the exact integrity contract"
    return 1
  fi
  if ! env -u PYTHONPATH -u PYTHONHOME python3 -I "$integrity_script" \
    metadata-only --receipt "$stage_receipt" >/dev/null; then
    rldyour::log "error" "staged browser runtime receipt failed canonical integrity verification"
    return 1
  fi
  if [ -e "$receipt" ] && \
    ! env -u PYTHONPATH -u PYTHONHOME python3 -I "$integrity_script" \
      metadata-only --receipt "$receipt" >/dev/null; then
    rldyour::log "error" "browser runtime receipt changed during publication; preserved"
    return 1
  fi
  mv -f "$stage_receipt" "$receipt" || return 1
  rmdir "$stage_dir" || return 1
  stage_dir=""
  if ! "$verify_script" --receipt "$receipt" --json >/dev/null; then
    rldyour::log "error" "published browser runtime receipt failed full live verification"
    return 1
  fi
  rldyour::log "ok" "browser runtime integrity receipt published and proven: ${receipt}"
  trap - RETURN
}

# Install the pinned browser providers used by the AI CLI config adapters.
# Packages live under a dedicated managed data directory; small PATH wrappers
# enforce the one fixed CloakBrowser CDP endpoint. Existing global packages and
# unmanaged config files are neither removed nor overwritten.
rldyour::_is_exact_legacy_cloak_home() {
  local home=$1 bin_dir=$2 cache="$1/cache" fp service_file version
  [ -d "$home" ] && [ ! -L "$home" ] && [ -O "$home" ] || return 1
  [ -d "$home/.venv" ] && [ ! -L "$home/.venv" ] || return 1
  [ -x "$home/.venv/bin/python" ] || return 1
  [ -d "$cache" ] && [ ! -L "$cache" ] || return 1
  [ -d "$home/daemon-profile" ] && [ ! -L "$home/daemon-profile" ] || return 1
  version="$(rldyour::_isolated_python "$home/.venv/bin/python" -c 'from importlib.metadata import version; print(version("cloakbrowser"))' 2>/dev/null || true)"
  printf '%s' "$version" | grep -Eq '^0\.4\.[0-9]+$' || return 1
  case "$(uname -s)" in
    Darwin)
      fp="macos"
      service_file="$HOME/Library/LaunchAgents/com.rldyour.cloakbrowser.plist"
      rldyour::_is_legacy_cloak_service_file \
        launchd "$service_file" "$bin_dir" "$home" "$home/daemon-profile" "$fp" 9222 || return 1
      ;;
    Linux)
      fp="linux"
      service_file="$HOME/.config/systemd/user/rldyour-cloakbrowser.service"
      rldyour::_is_legacy_cloak_service_file \
        systemd "$service_file" "$bin_dir" "$home" "$home/daemon-profile" "$fp" 9222 || return 1
      ;;
    *) return 1 ;;
  esac
  if rldyour::_is_legacy_cloak_launcher_file \
    chromium "$bin_dir/cloak-chromium" "$bin_dir" "$cache" "$fp" && \
    rldyour::_is_legacy_cloak_launcher_file \
      stealth "$bin_dir/cloak-chromium-stealth" "$bin_dir" "$cache" "$fp"; then
    :
  elif ! rldyour::_is_current_managed_cloak_launcher_set "$bin_dir" "$cache" "$fp"; then
    return 1
  fi
  env -u PYTHONPATH -u PYTHONHOME \
    "$bin_dir/cloak-chromium" --version >/dev/null 2>&1 || return 1
}

rldyour::_resume_legacy_cloak_service() {
  local was_active=$1 target
  [ "$was_active" -eq 1 ] || return 0
  case "$(uname -s)" in
    Darwin)
      target="gui/$(id -u)/com.rldyour.cloakbrowser"
      if launchctl print "$target" >/dev/null 2>&1; then
        return 0
      fi
      launchctl bootstrap \
        "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.rldyour.cloakbrowser.plist" >/dev/null 2>&1 || true
      rldyour::_wait_launchd_service_state "$target" loaded
      ;;
    Linux)
      systemctl --user daemon-reload >/dev/null 2>&1 || return 1
      systemctl --user start rldyour-cloakbrowser.service >/dev/null 2>&1 || return 1
      systemctl --user is-active --quiet rldyour-cloakbrowser.service
      ;;
    *) return 0 ;;
  esac
}

rldyour::_prepare_legacy_cloak_home() {
  local home=$1 backup_var=$2 active_var=$3 bin_dir=$4 backup_path profile marker snapshot wrapper
  local was_active_value=0
  backup_path="${home}-legacy-$(date -u +%Y%m%dT%H%M%SZ)"
  [ ! -e "$backup_path" ] && [ ! -L "$backup_path" ] || return 1
  case "$(uname -s)" in
    Darwin)
      if launchctl print "gui/$(id -u)/com.rldyour.cloakbrowser" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/com.rldyour.cloakbrowser" >/dev/null 2>&1 || return 1
        was_active_value=1
      fi
      ;;
    Linux)
      if systemctl --user is-active --quiet rldyour-cloakbrowser.service >/dev/null 2>&1; then
        systemctl --user stop rldyour-cloakbrowser.service >/dev/null 2>&1 || return 1
        was_active_value=1
      fi
      ;;
  esac
  if ! mv "$home" "$backup_path"; then
    rldyour::_resume_legacy_cloak_service "$was_active_value" || true
    return 1
  fi
  snapshot="$backup_path/.rldyour-migration-wrappers"
  if ! mkdir -m 0700 "$snapshot"; then
    mv "$backup_path" "$home" || true
    rldyour::_resume_legacy_cloak_service "$was_active_value" || true
    return 1
  fi
  for wrapper in \
    cloak-chromium cloak-chromium-stealth cloakbrowser-cdp-health \
    chrome-devtools-mcp playwright-cli webwright; do
    if [ -e "$bin_dir/$wrapper" ] || [ -L "$bin_dir/$wrapper" ]; then
      if [ ! -f "$bin_dir/$wrapper" ] || [ -L "$bin_dir/$wrapper" ] || \
        ! cp -p "$bin_dir/$wrapper" "$snapshot/$wrapper"; then
        rm -rf "$snapshot"
        mv "$backup_path" "$home" || true
        rldyour::_resume_legacy_cloak_service "$was_active_value" || true
        return 1
      fi
    elif ! : >"$snapshot/.absent-$wrapper"; then
      rm -rf "$snapshot"
      mv "$backup_path" "$home" || true
      rldyour::_resume_legacy_cloak_service "$was_active_value" || true
      return 1
    fi
  done
  if ! mkdir -m 0700 "$home"; then
    rm -rf "$snapshot"
    mv "$backup_path" "$home" || true
    rldyour::_resume_legacy_cloak_service "$was_active_value" || true
    return 1
  fi
  profile="$backup_path/daemon-profile"
  if [ -d "$profile" ] && [ ! -L "$profile" ]; then
    if ! cp -a "$profile" "$home/daemon-profile"; then
      rm -rf "$home"
      rm -rf "$snapshot"
      mv "$backup_path" "$home" || true
      rldyour::_resume_legacy_cloak_service "$was_active_value" || true
      return 1
    fi
  fi
  marker="$home/.rldyour-browser-stack"
  if ! rldyour::_install_managed_browser_file \
    "$marker" "# Managed by macos-ubuntu-bootstrap: browser-stack-v1" 0600 <<'MARKER'
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
# This dedicated directory may be updated only by the browser bootstrap layer.
MARKER
  then
    rm -rf "$home"
    rm -rf "$snapshot"
    mv "$backup_path" "$home" || true
    rldyour::_resume_legacy_cloak_service "$was_active_value" || true
    return 1
  fi
  printf -v "$backup_var" '%s' "$backup_path"
  printf -v "$active_var" '%s' "$was_active_value"
  rldyour::log "info" "preserved exact legacy CloakBrowser home before managed migration: ${backup_path}"
}

rldyour::_restore_legacy_cloak_home() {
  local home=$1 backup=$2 legacy_was_active=$3 bin_dir=$4 failed snapshot wrapper
  local destination restore_tmp marker="# Managed by macos-ubuntu-bootstrap: browser-stack-v1"
  [ -n "$backup" ] && [ -d "$backup" ] && [ ! -L "$backup" ] || return 1
  if [ -e "$home" ] || [ -L "$home" ]; then
    failed="${home}-failed-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$home" "$failed" || return 1
    rldyour::log "warn" "preserved failed managed CloakBrowser migration for review: ${failed}"
  fi
  mv "$backup" "$home" || return 1
  snapshot="$home/.rldyour-migration-wrappers"
  if [ -d "$snapshot" ] && [ ! -L "$snapshot" ]; then
    for wrapper in \
      cloak-chromium cloak-chromium-stealth cloakbrowser-cdp-health \
      chrome-devtools-mcp playwright-cli webwright; do
      destination="$bin_dir/$wrapper"
      if [ -f "$snapshot/$wrapper" ] && [ ! -L "$snapshot/$wrapper" ]; then
        if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
          return 1
        fi
        if [ -f "$destination" ] && ! cmp -s "$snapshot/$wrapper" "$destination" && \
          ! grep -Fxq "$marker" "$destination"; then
          rldyour::log "error" "concurrently changed wrapper is preserved during rollback: ${destination}"
          return 1
        fi
        restore_tmp="$(mktemp "$bin_dir/.${wrapper}.restore.XXXXXX")" || return 1
        if ! cp -p "$snapshot/$wrapper" "$restore_tmp" || ! mv -f "$restore_tmp" "$destination"; then
          rm -f "$restore_tmp"
          return 1
        fi
      elif [ -f "$snapshot/.absent-$wrapper" ] && [ ! -L "$snapshot/.absent-$wrapper" ]; then
        if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
          return 1
        fi
        if [ -f "$destination" ] && ! grep -Fxq "$marker" "$destination"; then
          rldyour::log "error" "new unmanaged wrapper is preserved during rollback: ${destination}"
          return 1
        fi
        rm -f "$destination" || return 1
      else
        rldyour::log "error" "legacy wrapper snapshot is incomplete: ${wrapper}"
        return 1
      fi
    done
    rm -rf "$snapshot" || return 1
  fi
  rldyour::_resume_legacy_cloak_service "$legacy_was_active" || return 1
  rldyour::log "ok" "restored exact legacy CloakBrowser home after failed migration: ${home}"
}

rldyour::_install_browser_providers_impl() {
  local dry_run="${RLDYOUR_DRY_RUN:-1}"
  local chrome_version="1.6.0"
  local playwright_version="0.1.17"
  local endpoint="http://127.0.0.1:9222"
  local bin_dir="$HOME/.local/bin"
  local browser_home="$HOME/.local/share/rldyour/browser-stack"
  local config_home="" cloak_runtime="" cloak_binary="" node_runtime=""
  local session_home marker_file playwright_global_root receipt integrity_script
  local common_dir root_dir template_dir
  local provider_manifest provider_lock provider_source
  local chrome_bin playwright_bin node_version
  local wrapper_stage="" wrapper_marker="# Managed by macos-ubuntu-bootstrap: browser-stack-v1"
  local command_name template wrapper_name
  session_home="$browser_home/playwright-sessions"
  marker_file="$browser_home/.rldyour-browser-stack"
  playwright_global_root="$browser_home/playwright-global-empty"
  common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root_dir="$(cd "$common_dir/../.." && pwd)"
  template_dir="$root_dir/templates/browser"
  provider_manifest="$template_dir/provider/package.json"
  provider_lock="$template_dir/provider/bun.lock"
  receipt="$browser_home/browser-runtime-receipt.json"
  integrity_script="$root_dir/scripts/browser_runtime_integrity.py"

  rldyour::section "Install browser providers (pinned)"
  rldyour::_reject_cloak_trust_overrides || return 1

  if [ "${RLDYOUR_SKIP_CLOAKBROWSER:-0}" -ne 0 ]; then
    rldyour::log "error" "RLDYOUR_SKIP_CLOAKBROWSER cannot be used with the mandatory browser provider layer"
    return 1
  fi

  export RLDYOUR_BROWSER_CDP_ENDPOINT="$endpoint"
  export PLAYWRIGHT_MCP_CDP_ENDPOINT="$endpoint"
  export LOCAL_BROWSER_CDP_URL="$endpoint"
  export BROWSER_CDP_URL="$endpoint"
  export AGENT_BROWSER_EXECUTABLE_PATH="$bin_dir/cloak-chromium"

  if [ "$dry_run" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] require apply-time commands: bun, uv, compatible node, python3, curl"
    rldyour::install_cloakbrowser || return 1
    rldyour::install_cloakbrowser_daemon || return 1
    rldyour::log "info" "[DRY-RUN] bun install --frozen-lockfile --ignore-scripts from the repository-owned provider lock"
    rldyour::log "info" "[DRY-RUN] stage the content-addressed fixed-CDP Playwright config under ${browser_home}/config-runtimes"
    rldyour::log "info" "[DRY-RUN] install two active provider wrappers plus the exact disabled Webwright tombstone under ${bin_dir}"
    rldyour::log "info" "[DRY-RUN] publish and live-verify the canonical browser runtime integrity receipt"
    return 0
  fi

  for command_name in bun node python3; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      rldyour::log "error" "${command_name} is required for the mandatory browser provider layer"
      return 1
    fi
  done
  if { [ -e "$receipt" ] || [ -L "$receipt" ]; } && \
    { [ ! -f "$receipt" ] || [ -L "$receipt" ] || \
      ! env -u PYTHONPATH -u PYTHONHOME python3 -I "$integrity_script" \
        metadata-only --receipt "$receipt" >/dev/null; }; then
    rldyour::log "error" "browser runtime receipt is unmanaged or corrupt; preserved: ${receipt}"
    return 1
  fi
  node_version="$(node -p 'process.versions.node' 2>/dev/null || true)"
  if ! rldyour::_isolated_python python3 - "$node_version" <<'PY'
import sys

try:
    major, minor, *_ = (int(part) for part in sys.argv[1].split("."))
except (TypeError, ValueError):
    raise SystemExit(1)
supported = (major == 20 and minor >= 19) or (major == 22 and minor >= 12) or major >= 23
raise SystemExit(0 if supported else 1)
PY
  then
    rldyour::log "error" "Node ${node_version:-unknown} is incompatible with chrome-devtools-mcp ${chrome_version}"
    return 1
  fi

  if [ -L "$browser_home" ] || { [ -e "$browser_home" ] && [ ! -d "$browser_home" ]; }; then
    rldyour::log "error" "browser provider namespace is not a managed directory; preserved: ${browser_home}"
    return 1
  fi
  if [ -e "$marker_file" ] && { [ ! -f "$marker_file" ] || [ -L "$marker_file" ] || ! grep -Fxq "$wrapper_marker" "$marker_file"; }; then
    rldyour::log "error" "browser provider ownership marker is invalid; preserved: ${marker_file}"
    return 1
  fi
  if [ -d "$browser_home" ] && [ ! -f "$marker_file" ] && [ -n "$(find "$browser_home" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    rldyour::log "error" "browser provider home exists without a management marker; preserved: ${browser_home}"
    return 1
  fi
  if [ -L "$playwright_global_root" ] || \
    { [ -e "$playwright_global_root" ] && [ ! -d "$playwright_global_root" ]; } || \
    { [ -d "$playwright_global_root" ] && [ -n "$(find "$playwright_global_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; }; then
    rldyour::log "error" "Playwright empty global-config root is not empty and managed; preserved: ${playwright_global_root}"
    return 1
  fi
  for wrapper_name in chrome-devtools-mcp playwright-cli webwright; do
    rldyour::_managed_wrapper_replaceable "$bin_dir/$wrapper_name" "$wrapper_marker" || return 1
  done
  for provider_source in "$provider_manifest" "$provider_lock"; do
    if [ ! -f "$provider_source" ] || [ -L "$provider_source" ]; then
      rldyour::log "error" "required browser provider lock input is missing or unsafe: ${provider_source}"
      return 1
    fi
  done
  for template in playwright-cli.json cloakbrowser-pyproject.toml cloakbrowser-uv.lock; do
    if [ ! -f "$template_dir/$template" ] || [ -L "$template_dir/$template" ]; then
      rldyour::log "error" "required browser routing template is missing or unsafe: ${template_dir}/${template}"
      return 1
    fi
  done

  mkdir -p "$browser_home" "$session_home" "$playwright_global_root" "$bin_dir" || return 1
  chmod 0700 "$browser_home" "$session_home" "$playwright_global_root" || return 1
  rldyour::_install_managed_browser_file "$marker_file" "$wrapper_marker" 0600 <<'MARKER' || return 1
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
# Isolated npm packages and provider configs for the fail-closed browser stack.
MARKER
  rldyour::_install_browser_node_bundle \
    "$chrome_version" "$playwright_version" "$browser_home" \
    "$provider_manifest" "$provider_lock" chrome_bin playwright_bin node_runtime || return 1
  rldyour::_install_browser_config_bundle "$browser_home" "$template_dir" config_home || return 1

  wrapper_stage="$(mktemp -d "$bin_dir/.browser-provider-wrappers.XXXXXX")" || return 1
  chmod 0700 "$wrapper_stage" || {
    rm -rf "$wrapper_stage"
    return 1
  }
  if ! cat >"$wrapper_stage/chrome-devtools-mcp" <<CHROME
#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
set -euo pipefail
endpoint="${endpoint}"
health="${bin_dir}/cloakbrowser-cdp-health"
provider="${chrome_bin}"
args=()

while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --)
      echo "chrome-devtools-mcp: '--' cannot bypass the mandatory CDP and privacy flags" >&2
      exit 64
      ;;
    --browser-url|--browserUrl)
      [ "\$#" -ge 2 ] || { echo "chrome-devtools-mcp: missing endpoint value" >&2; exit 64; }
      [ "\$2" = "\$endpoint" ] || { echo "chrome-devtools-mcp: alternate CDP endpoint rejected" >&2; exit 64; }
      shift 2
      ;;
    --browser-url=*|--browserUrl=*)
      value="\${1#*=}"
      [ "\$value" = "\$endpoint" ] || { echo "chrome-devtools-mcp: alternate CDP endpoint rejected" >&2; exit 64; }
      shift
      ;;
    --ws-endpoint|--wsEndpoint|--ws-endpoint=*|--wsEndpoint=*|--auto-connect|--autoConnect|--auto-connect=*|--autoConnect=*|--channel|--channel=*|--executable-path|--executablePath|--executable-path=*|--executablePath=*)
      echo "chrome-devtools-mcp: alternate browser connection mode rejected" >&2
      exit 64
      ;;
    --no-usage-statistics|--noUsageStatistics|--no-performance-crux|--noPerformanceCrux)
      shift
      ;;
    --usage-statistics|--usage-statistics=*|--usageStatistics|--usageStatistics=*|--performance-crux|--performance-crux=*|--performanceCrux|--performanceCrux=*|--no-usage-statistics=*|--noUsageStatistics=*|--no-performance-crux=*|--noPerformanceCrux=*)
      echo "chrome-devtools-mcp: usage telemetry and CrUX are disabled by policy" >&2
      exit 64
      ;;
    *)
      args+=("\$1")
      shift
      ;;
  esac
done

case "\${args[0]:-}" in
  -h|--help|-V|--version) ;;
  *) "\$health" ;;
esac
export CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1
export CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1
exec "\$provider" "--browser-url=\$endpoint" "\${args[@]}" --no-usage-statistics --no-performance-crux
CHROME
  then
    rm -rf "$wrapper_stage"
    return 1
  fi
  chmod 0755 "$wrapper_stage/chrome-devtools-mcp" || {
    rm -rf "$wrapper_stage"
    return 1
  }

  if ! cat >"$wrapper_stage/playwright-cli" <<PLAYWRIGHT
#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
set -euo pipefail
endpoint="${endpoint}"
health="${bin_dir}/cloakbrowser-cdp-health"
provider="${playwright_bin}"
config="${config_home}/playwright-cli.json"
global_config_root="${playwright_global_root}"
args=()

while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --)
      echo "playwright-cli: '--' cannot bypass the mandatory CDP configuration" >&2
      exit 64
      ;;
    install|install-browser|attach)
      echo "playwright-cli: stock-browser installation and external attach commands are disabled" >&2
      exit 64
      ;;
    run-code|--filename|--filename=*)
      echo "playwright-cli: arbitrary code and file execution are disabled by the managed browser policy" >&2
      exit 64
      ;;
    --config|--config=*|--browser|--browser=*|--extension|--extension=*|--endpoint|--endpoint=*|--remote-endpoint|--remote-endpoint=*|--cdp-endpoint|--cdp-endpoint=*|--executable-path|--executable-path=*|--user-data-dir|--user-data-dir=*|--persistent|--profile|--profile=*|--init-workspace|--init-skills|--init-skills=*)
      echo "playwright-cli: alternate browser configuration rejected" >&2
      exit 64
      ;;
    --cdp)
      [ "\$#" -ge 2 ] || { echo "playwright-cli: missing CDP endpoint value" >&2; exit 64; }
      [ "\$2" = "\$endpoint" ] || { echo "playwright-cli: alternate CDP endpoint rejected" >&2; exit 64; }
      args+=("\$1" "\$2")
      shift 2
      ;;
    --cdp=*)
      [ "\${1#*=}" = "\$endpoint" ] || { echo "playwright-cli: alternate CDP endpoint rejected" >&2; exit 64; }
      args+=("\$1")
      shift
      ;;
    *)
      args+=("\$1")
      shift
      ;;
  esac
done

case "\${args[0]:-}" in
  -h|--help|-V|--version) ;;
  *) "\$health" ;;
esac
if [ -L "\$global_config_root" ] || [ ! -d "\$global_config_root" ] || \
  [ -n "\$(find "\$global_config_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "playwright-cli: managed global-config root is not empty and safe" >&2
  exit 64
fi
unset PLAYWRIGHT_MCP_BROWSER PLAYWRIGHT_MCP_CONFIG PLAYWRIGHT_MCP_EXECUTABLE_PATH PLAYWRIGHT_MCP_EXTENSION PWTEST_CLI_GLOBAL_CONFIG
export PLAYWRIGHT_MCP_CDP_ENDPOINT="\$endpoint"
export AGENT_BROWSER_EXECUTABLE_PATH="${bin_dir}/cloak-chromium"
export PWTEST_DAEMON_SESSION_DIR="${session_home}"
export PWTEST_CLI_GLOBAL_CONFIG="\$global_config_root"
export NO_UPDATE_NOTIFIER=1
exec "\$provider" "--config=\$config" "\${args[@]}"
PLAYWRIGHT
  then
    rm -rf "$wrapper_stage"
    return 1
  fi
  chmod 0755 "$wrapper_stage/playwright-cli" || {
    rm -rf "$wrapper_stage"
    return 1
  }

  # Do not invoke `playwright-cli install`: even its skills-only mode initializes
  # a workspace and downloads Playwright's stock Chromium. The isolated CLI and
  # managed config above are sufficient for the CDP-locked PATH entry point.

  if ! cat >"$wrapper_stage/webwright" <<'WEBWRIGHT'
#!/usr/bin/env bash
# Managed by macos-ubuntu-bootstrap: browser-stack-v1
set -euo pipefail
echo "webwright: retired by the fail-closed browser policy; arbitrary Python/browser objects are NOT_PROVEN" >&2
exit 78
WEBWRIGHT
  then
    rm -rf "$wrapper_stage"
    return 1
  fi
  chmod 0755 "$wrapper_stage/webwright" || {
    rm -rf "$wrapper_stage"
    return 1
  }

  rldyour::install_cloakbrowser cloak_runtime cloak_binary || {
    rm -rf "$wrapper_stage"
    return 1
  }
  if ! RLDYOUR_DEFER_CLOAK_DAEMON_COMMIT=1 rldyour::install_cloakbrowser_daemon; then
    rm -rf "$wrapper_stage"
    return 1
  fi
  if ! rldyour::_publish_managed_wrapper_set \
    "$wrapper_stage" "$bin_dir" "$wrapper_marker" \
    chrome-devtools-mcp playwright-cli webwright; then
    rm -rf "$wrapper_stage"
    if ! rldyour::rollback_cloak_daemon_handoff; then
      rldyour::log "error" "provider wrapper publication and CloakBrowser daemon rollback both failed"
    fi
    return 1
  fi
  wrapper_stage=""
  if ! rldyour::_publish_browser_runtime_receipt \
    "$browser_home" "$cloak_runtime" "$cloak_binary" "$node_runtime" "$config_home"; then
    if ! rldyour::rollback_cloak_daemon_handoff; then
      rldyour::log "error" "browser runtime verification and CloakBrowser daemon rollback both failed"
    fi
    return 1
  fi
  rldyour::commit_cloak_daemon_handoff || {
    rldyour::log "error" "provider wrappers are live but daemon transaction cleanup failed"
    return 1
  }

  rldyour::log "ok" "browser providers installed: chrome-devtools-mcp ${chrome_version}, Playwright CLI ${playwright_version}; Webwright retired fail-closed"
}

rldyour::install_browser_providers() {
  local dry_run="${RLDYOUR_DRY_RUN:-1}"
  local home bin_dir backup="" legacy_was_active=0
  home="$(rldyour::_cloak_home)"
  bin_dir="$HOME/.local/bin"
  # Reject explicit trust-boundary overrides before inspecting local migration
  # state so the public entry point is deterministic and fail-closed on every
  # host, including dry-run planning against an existing legacy installation.
  rldyour::_reject_cloak_trust_overrides || return 1
  if [ -d "$home" ] && [ ! -f "$home/.rldyour-browser-stack" ] && \
    [ -n "$(find "$home" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    if ! rldyour::_is_exact_legacy_cloak_home "$home" "$bin_dir"; then
      rldyour::log "error" "CloakBrowser home is unmanaged and does not match an exact legacy rldyour installation; preserved: ${home}"
      return 1
    fi
    if [ "$dry_run" -eq 1 ]; then
      rldyour::log "info" "[DRY-RUN] preserve exact legacy CloakBrowser home, copy its daemon profile, and migrate transactionally"
      rldyour::_install_browser_providers_impl
      return
    fi
    rldyour::_prepare_legacy_cloak_home "$home" backup legacy_was_active "$bin_dir" || {
      rldyour::log "error" "could not stage the exact legacy CloakBrowser home for managed migration"
      return 1
    }
  fi
  if rldyour::_install_browser_providers_impl; then
    if [ -n "$backup" ]; then
      rldyour::log "ok" "managed CloakBrowser migration completed; legacy backup retained: ${backup}"
    fi
    return 0
  fi
  if [ -n "$backup" ] && ! rldyour::_restore_legacy_cloak_home \
    "$home" "$backup" "$legacy_was_active" "$bin_dir"; then
    rldyour::log "error" "managed CloakBrowser migration failed and legacy restoration also failed"
  fi
  return 1
}

# --- Terminal layer ----------------------------------------------------------

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
  # The active harness set is codex and zcode. Both are owned by their GDS
  # modules, which publish their launchers into the managed prefix; require them
  # only when their module paths were provided to bootstrap. The browser and rtk
  # commands are always published by this bootstrap.
  local -a required_cmds=(
    rtk cloak-chromium cloakbrowser-cdp-health chrome-devtools-mcp playwright-cli
  )
  [ -n "${RLDYOUR_ZCODE_MODULE:-}" ] && required_cmds=(zcode "${required_cmds[@]}")
  [ -n "${RLDYOUR_CODEX_MODULE:-}" ] && required_cmds=(codex "${required_cmds[@]}")
  command -v zsh >/dev/null 2>&1 || {
    rldyour::log "error" "zsh is required for managed terminal verification"
    return 1
  }
  shell_dump="$(RLDYOUR_VERIFY_CMDS="${required_cmds[*]}" zsh -l -c '
    printf "__RLDYOUR_PATH__=%s\n" "$PATH"
    printf "__RLDYOUR_ENDPOINT__=%s\n" "${RLDYOUR_BROWSER_CDP_ENDPOINT-}"
    printf "__RLDYOUR_CODEX_AUTO__=%s\n" "${DISABLE_AUTOUPDATER-}"
    printf "__RLDYOUR_CODEX_ALL__=%s\n" "${DISABLE_UPDATES-}"
    printf "__RLDYOUR_CLOAK_BINARY__=%s\n" "${CLOAKBROWSER_BINARY_PATH-unset}"
    printf "__RLDYOUR_CLOAK_URL__=%s\n" "${CLOAKBROWSER_DOWNLOAD_URL-unset}"
    printf "__RLDYOUR_CLOAK_SKIP__=%s\n" "${CLOAKBROWSER_SKIP_CHECKSUM-unset}"
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
required = {
    "__RLDYOUR_PATH__",
    "__RLDYOUR_ENDPOINT__",
    "__RLDYOUR_CODEX_AUTO__",
    "__RLDYOUR_CODEX_ALL__",
    "__RLDYOUR_CLOAK_BINARY__",
    "__RLDYOUR_CLOAK_URL__",
    "__RLDYOUR_CLOAK_SKIP__",
}
# The browser and rtk commands are always published by this bootstrap; codex and
# zcode appear only when their GDS module paths were provided.
always = (
    "rtk", "cloak-chromium", "cloakbrowser-cdp-health",
    "chrome-devtools-mcp", "playwright-cli",
)
required.update(f"__RLDYOUR_CMD_{name}__" for name in always)
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
# DISABLE_AUTOUPDATER/DISABLE_UPDATES keep the codex harness update-locked.
if (
    values["__RLDYOUR_ENDPOINT__"],
    values["__RLDYOUR_CODEX_AUTO__"],
    values["__RLDYOUR_CODEX_ALL__"],
) != (
    "http://127.0.0.1:9222", "1", "1"
):
    raise SystemExit("managed browser or updater environment is not active")
if any(values[key] != "unset" for key in (
    "__RLDYOUR_CLOAK_BINARY__", "__RLDYOUR_CLOAK_URL__", "__RLDYOUR_CLOAK_SKIP__"
)):
    raise SystemExit("forbidden CloakBrowser trust override survived shell startup")
for name in commands:
    resolved = values[f"__RLDYOUR_CMD_{name}__"]
    if not resolved.startswith(expected_bin + "/"):
        raise SystemExit(f"managed command resolved outside {expected_bin}: {resolved}")
PY
  rldyour::log "ok" "fresh zsh login environment uses managed PATH, browser, and updater policy"
}

# Clone (or re-point) a git repository to an EXACT pinned commit at a managed
# path. Idempotent: an already-pinned clean checkout is a no-op and never
# re-clones; a non-git path at the destination is fail-closed and preserved.
rldyour::_ensure_pinned_git_checkout() {
  local url=$1 sha=$2 dir=$3 head
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    if [ -L "$dir" ] || [ ! -d "$dir/.git" ]; then
      rldyour::log "error" "unmanaged non-git path at pinned clone dir; preserved: ${dir}"
      return 1
    fi
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    if [ "$head" = "$sha" ]; then
      return 0
    fi
    git -C "$dir" fetch --quiet --tags origin || {
      rldyour::log "error" "failed to fetch pinned updates for ${dir}"
      return 1
    }
    git -C "$dir" checkout --quiet --detach "$sha" || {
      rldyour::log "error" "pinned commit ${sha} not found in ${dir}"
      return 1
    }
  else
    mkdir -p "${dir%/*}" || return 1
    git clone --quiet "$url" "$dir" || {
      rldyour::log "error" "failed to clone ${url}"
      return 1
    }
    git -C "$dir" checkout --quiet --detach "$sha" || {
      rldyour::log "error" "pinned commit ${sha} not found after cloning ${url}"
      return 1
    }
  fi
}

# Materialize an OFFLINE antidote plugin bundle shared by macOS and Ubuntu:
# ensure antidote is present, pre-clone every plugin at its pinned SHA into
# antidote's clone home, then compile the static ~/.zsh_plugins.zsh that shell
# startup sources with zero network. Idempotent: a second run re-verifies pinned
# SHAs and never re-clones a clean, already-pinned repo.
rldyour::materialize_zsh_plugins() {
  local manifest="$HOME/.zsh_plugins.txt"
  # getantidote/antidote pinned commit for the plain-Ubuntu clone path.
  local antidote_pin="4913257e0ae3fee2a77e7189e526fe55b6ff9536"
  local antidote_home="${XDG_CACHE_HOME:-$HOME/.cache}/antidote"
  local antidote_zsh="" candidate line repo sha dir bundle tmp
  local -a antidote_candidates=(
    /opt/homebrew/opt/antidote/share/antidote/antidote.zsh
    /usr/local/opt/antidote/share/antidote/antidote.zsh
    /home/linuxbrew/.linuxbrew/opt/antidote/share/antidote/antidote.zsh
    "$HOME/.antidote/antidote.zsh"
  )

  rldyour::section "Materialize offline antidote plugin bundle"

  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] ensure antidote (brew, else git clone getantidote/antidote@${antidote_pin} to \$HOME/.antidote), pre-clone every pinned plugin from ${manifest} into ${antidote_home}, then compile \$HOME/.zsh_plugins.zsh"
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
  #    otherwise clone getantidote/antidote at the pinned SHA to $HOME/.antidote,
  #    matching the path templates/terminal/zshrc already probes.
  for candidate in "${antidote_candidates[@]}"; do
    if [ -r "$candidate" ]; then
      antidote_zsh="$candidate"
      break
    fi
  done
  if [ -z "$antidote_zsh" ]; then
    rldyour::_ensure_pinned_git_checkout \
      "https://github.com/getantidote/antidote" "$antidote_pin" "$HOME/.antidote" || return 1
    antidote_zsh="$HOME/.antidote/antidote.zsh"
    [ -r "$antidote_zsh" ] || {
      rldyour::log "error" "antidote clone did not provide antidote.zsh: ${antidote_zsh}"
      return 1
    }
  fi

  # 2. Pre-clone every plugin at its pinned SHA into antidote's full-style clone
  #    home ($ANTIDOTE_HOME/github.com/<owner>/<repo>) so neither bundling nor
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
    rldyour::_ensure_pinned_git_checkout "https://github.com/$repo" "$sha" "$dir" || return 1
  done < "$manifest"

  # 3. Compile the static bundle. Every clone is present at its pinned SHA, so
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
  rldyour::_install_managed_browser_file \
    "$HOME/.config/rldyour/zshenv" \
    "# Managed by macos-ubuntu-bootstrap: terminal-zshenv-v1" 0644 \
    <"$tpl_dir/zshenv"
  rldyour::_install_managed_browser_file \
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
