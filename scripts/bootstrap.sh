#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPLY=0
PLATFORM="auto"
PROFILE="auto"
STRICT=0
SKIP_SYSTEM=0
SKIP_AI=0
SKIP_LSPS=0
SKIP_BROWSER=0
SKIP_CHECKS=0

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap.sh [--platform macos|ubuntu] [--profile server|desktop]
                           [--apply|--plan]
                           [--skip-system] [--skip-ai] [--skip-lsps] [--skip-browser]
                           [--skip-checks] [--strict]

Entrypoint for the module installer.

Default:
  - mode: plan (dry-run)
  - platform: auto-detect (darwin -> macos, linux -> ubuntu)
  - profile: auto (macos -> desktop; ubuntu -> server)

Profiles:
  - server:  full terminal-first CLI stack (shell, prompt, multiplexer, LSPs,
             AI CLIs, dev tools). No GUI apps. Suitable for headless Ubuntu.
  - desktop: server layer PLUS the GUI desktop layer (terminal emulator, Nerd
             fonts). macOS is always desktop.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform)
      PLATFORM="${2:?--platform requires one of macos|ubuntu}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:?--profile requires one of server|desktop}"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --plan | --dry-run)
      APPLY=0
      shift
      ;;
    --skip-system)
      SKIP_SYSTEM=1
      shift
      ;;
    --skip-ai)
      SKIP_AI=1
      shift
      ;;
    --skip-lsps)
      SKIP_LSPS=1
      shift
      ;;
    --skip-browser)
      SKIP_BROWSER=1
      shift
      ;;
    --skip-checks)
      SKIP_CHECKS=1
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$PLATFORM" = "auto" ]; then
  case "$(uname -s)" in
    Darwin)
      PLATFORM="macos"
      ;;
    Linux)
      PLATFORM="ubuntu"
      ;;
    *)
      echo "Unsupported OS: $(uname -s)" >&2
      exit 2
      ;;
  esac
fi

if [ "$PLATFORM" != "macos" ] && [ "$PLATFORM" != "ubuntu" ]; then
  echo "Unsupported platform: $PLATFORM (expected macos|ubuntu)" >&2
  exit 2
fi

# Resolve the install profile. macOS is a GUI workstation (always desktop);
# Ubuntu defaults to the headless server profile unless --profile desktop is set.
if [ "$PROFILE" = "auto" ]; then
  if [ "$PLATFORM" = "macos" ]; then
    PROFILE="desktop"
  else
    PROFILE="server"
  fi
fi

if [ "$PROFILE" != "server" ] && [ "$PROFILE" != "desktop" ]; then
  echo "Unsupported profile: $PROFILE (expected server|desktop)" >&2
  exit 2
fi

# macOS is always a desktop workstation; a server profile there is meaningless.
if [ "$PLATFORM" = "macos" ] && [ "$PROFILE" != "desktop" ]; then
  echo "macOS only supports the desktop profile (got: $PROFILE)" >&2
  exit 2
fi

RUNNER_SCRIPT="${SCRIPT_DIR}/${PLATFORM}/install.sh"
if [ ! -x "$RUNNER_SCRIPT" ]; then
  echo "Missing runner script: $RUNNER_SCRIPT" >&2
  exit 2
fi

export RLDYOUR_DRY_RUN=$((1 - APPLY))
export RLDYOUR_PROFILE=$PROFILE
export RLDYOUR_STRICT=$STRICT
export RLDYOUR_SKIP_SYSTEM=$SKIP_SYSTEM
export RLDYOUR_SKIP_AI=$SKIP_AI
export RLDYOUR_SKIP_LSPS=$SKIP_LSPS
export RLDYOUR_SKIP_BROWSER=$SKIP_BROWSER
export RLDYOUR_SKIP_CHECKS=$SKIP_CHECKS

"$RUNNER_SCRIPT"
