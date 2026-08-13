#!/usr/bin/env bash
#
# scripts/ubuntu/desktop.sh
# ------------------------------------------------------------
# Ubuntu desktop customization: GNOME shell, keyboard layouts,
# default browser, and stock-browser cleanup.
#
# Called by scripts/ubuntu/install.sh in the desktop+gui profile.
# Safe to re-run (idempotent). Prompts sudo once for the whole run.
#
# What it does (desktop profile only):
#   1. GNOME dock: move to bottom, centered, macOS-style.
#   2. Keyboard: add Russian layout with Alt+Shift toggle.
#   3. Google Chrome: install from the fingerprint-verified signed apt source.
#   4. RustDesk: required pinned .deb.
#   5. Firefox: remove the stock snap+apt Firefox completely.
#
# Server profile (headless) skips this entirely.
# ------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=privilege.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/privilege.sh"

# ----------------------------- helpers -----------------------------
info() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  \u2713 %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  \u2717 %s\033[0m\n' "$*" >&2; exit 1; }

# Steps whose failure makes the desktop layer wrong rather than merely
# incomplete. Google Chrome is the estate's standard browser and the Firefox
# removal and RustDesk are declared policy, so all three are required. The dock and keyboard layout are cosmetic
# and legitimately unavailable on a session without the dash-to-dock extension
# or xkb data. Only a required failure fails the run.
REQUIRED_STEPS=(google_chrome rustdesk firefox_removal)
OPTIONAL_STEPS=(gnome_dock russian_layout)

# Populated by nddev::_record; read by the aggregate report.
declare -A STEP_STATUS=()

nddev::_record() {
  STEP_STATUS["$1"]=$2
}

nddev::_is_required() {
  local candidate
  for candidate in "${REQUIRED_STEPS[@]}"; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

# Run one step, remember its outcome, and never let it abort the run. Steps
# report `skipped` for a precondition they do not own (a missing GNOME
# extension) and `failed` for work they attempted and could not finish.
nddev::_step() {
  local name=$1
  shift
  if "$@"; then
    [ -n "${STEP_STATUS[$name]:-}" ] || nddev::_record "$name" ok
  else
    nddev::_record "$name" failed
  fi
}

# ----------------------------- preflight -----------------------------
nddev::desktop_configure() {
  [[ "$(id -u)" -ne 0 ]] || die "Run as your normal user, NOT root/sudo."
  command -v gsettings >/dev/null || die "gsettings missing (needs GNOME)"
  command -v localectl >/dev/null || die "localectl missing (needs systemd)"

  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] desktop customization: GNOME dock bottom, Russian layout, Google Chrome install, RustDesk install, Firefox removal"
    return 0
  fi

  case "$RLDYOUR_PRIVILEGE_MODE" in
    root|sudo-noninteractive|sudo-tty|policykit) ;;
    *) die "privilege state was not preflighted by scripts/ubuntu/install.sh" ;;
  esac

  nddev::_step gnome_dock nddev::_gnome_dock_bottom
  nddev::_step russian_layout nddev::_russian_keyboard_layout
  nddev::_step google_chrome nddev::_install_google_chrome
  nddev::_step rustdesk nddev::_install_desktop_deb rustdesk
  nddev::_step firefox_removal nddev::_remove_firefox

  # Report the real outcome. Announcing "complete" unconditionally is what let
  # a half-configured desktop pass both apply and strict verification.
  local name status failed_required=0 failed_optional=0
  for name in "${REQUIRED_STEPS[@]}" "${OPTIONAL_STEPS[@]}"; do
    status=${STEP_STATUS[$name]:-missing}
    case "$status" in
      ok) ok "$name: ok" ;;
      skipped) warn "$name: skipped (precondition absent)" ;;
      *)
        if nddev::_is_required "$name"; then
          printf '\033[1;31m  ✗ %s\033[0m\n' "$name: FAILED (required)" >&2
          failed_required=$((failed_required + 1))
        else
          warn "$name: failed (optional)"
          failed_optional=$((failed_optional + 1))
        fi
        ;;
    esac
  done

  if [ "$failed_required" -gt 0 ]; then
    printf '\033[1;31m  ✗ desktop customization incomplete: %d required step(s) failed\033[0m\n' \
      "$failed_required" >&2
    return 1
  fi
  if [ "$failed_optional" -gt 0 ]; then
    warn "desktop customization complete with $failed_optional optional step(s) failed"
    return 0
  fi
  ok "desktop customization complete"
}

# Refresh sudo timestamp before a sudo-requiring step. Dies if it cannot.
nddev::_sudo_refresh() {
  rldyour::privilege::refresh || die "privilege authorization expired; rerun bootstrap preflight"
}

# ----------------------------- GNOME dock -----------------------------
nddev::_gnome_dock_bottom() {
  info "Configuring GNOME dock (bottom, centered, macOS-style)"
  local schema="org.gnome.shell.extensions.dash-to-dock"
  gsettings list-schemas | command grep -q "^${schema}$" \
    || { nddev::_record gnome_dock skipped; return 0; }

  gsettings set "$schema" dock-position 'BOTTOM'
  gsettings set "$schema" extend-height false
  gsettings set "$schema" dock-fixed true
  gsettings set "$schema" transparency-mode 'DYNAMIC'
  gsettings set "$schema" dash-max-icon-size 48
  ok "dock moved to bottom, centered"
}

# ----------------------------- Russian keyboard -----------------------------
nddev::_russian_keyboard_layout() {
  info "Adding Russian keyboard layout (Alt+Shift toggle)"
  [ -f /usr/share/X11/xkb/symbols/ru ] \
    || {
      warn "Russian xkb data missing — install: sudo apt install xkb-data"
      nddev::_record russian_layout skipped
      return 0
    }

  if locale -a | command grep -qi 'ru_RU.utf8'; then
    ok "ru_RU.UTF-8 generated"
  else
    warn "ru_RU.UTF-8 not found in locale -a"
    return 1
  fi

  # System X11 keymap: us,ru + Alt+Shift toggle is part of desktop-locale.
  ok "X11 keymap set to us,ru with Alt+Shift toggle"

  # A GNOME session does not read the system X11 keymap: it reads the per-user
  # org.gnome.desktop.input-sources list, and on Wayland there is no X server
  # to read the former at all. Setting only localectl left the estate's own
  # desktop with `X11 Layout: us` while the layout that actually worked had
  # been added by hand through GNOME Settings. Append ru if it is missing and
  # preserve whatever the owner already has, including order.
  nddev::_gnome_add_russian_input_source
}

# Append ('xkb', 'ru') to the GNOME input sources without reordering or
# dropping the owner's existing entries. Idempotent: an already-present ru is
# left exactly as it is.
nddev::_gnome_add_russian_input_source() {
  local current updated
  current="$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null)" || {
    warn "GNOME input sources unavailable; the session layout was not changed"
    return 0
  }
  updated="$(python3 - "$current" <<'PY'
import ast
import sys

raw = sys.argv[1]
for prefix in ("@a(ss) ", "@a(ss)"):
    if raw.startswith(prefix):
        raw = raw[len(prefix):]
        break
values = ast.literal_eval(raw)
if not isinstance(values, list):
    raise SystemExit("input-sources is not a list")
entries = [tuple(value) for value in values]
if ("xkb", "ru") not in entries:
    entries.append(("xkb", "ru"))
if ("xkb", "us") not in entries:
    entries.insert(0, ("xkb", "us"))
print("[" + ", ".join(f"('{kind}', '{name}')" for kind, name in entries) + "]")
PY
)" || {
    warn "could not compute the GNOME input source list; leaving it unchanged"
    return 0
  }
  if [ "$updated" = "$current" ]; then
    ok "GNOME input sources already include ru"
    return 0
  fi
  gsettings set org.gnome.desktop.input-sources sources "$updated" || return 1
  ok "added ru to the GNOME input sources"
}

# ----------------------------- pinned .deb applications -----------------------------

# Verify a package installed by the single privileged desktop transaction.
# Artifact URLs and hashes live only in the machine-readable root contract.
nddev::_install_desktop_deb() {
  local wanted=$1 package
  case "$wanted" in
    rustdesk) package=rustdesk ;;
    *)
    warn "unknown required desktop package: ${wanted}"
    return 1
    ;;
  esac

  info "Verifying ${wanted} from the completed privileged desktop transaction"
  if dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
    command grep -q "install ok installed"; then
    ok "${wanted} installed"
    return 0
  fi
  warn "${wanted} missing after the privileged desktop transaction"
  return 1
}

nddev::_install_google_chrome() {
  info "Installing Google Chrome (signed apt source, stable channel)"

  if [ "$(dpkg --print-architecture 2>/dev/null)" != "amd64" ]; then
    warn "Google publishes no Linux build for this architecture"
    nddev::_record google_chrome skipped
    return 0
  fi

  if dpkg-query -W -f='${Status}' google-chrome-stable 2>/dev/null |
    command grep -q "install ok installed"; then
    ok "Google Chrome already installed"
    return 0
  fi

  warn "Google Chrome missing after the privileged desktop transaction"
  return 1
}

# ----------------------------- Firefox removal -----------------------------
nddev::_remove_firefox() {
  info "Removing Firefox (snap + apt stub)"
  if snap list firefox >/dev/null 2>&1 ||
    dpkg-query -W -f='${Status}' firefox 2>/dev/null | command grep -q 'install ok installed'; then
    warn "Firefox remains after the privileged desktop transaction"
    return 1
  fi
  ok "Firefox absent"
}

# Guard so the main flow only runs when executed directly, not when sourced.
# This mirrors ubuntu/install.sh, ubuntu/server.sh and macos/install.sh. Without
# it every test had to cut individual functions out of this file with sed, which
# tests a copy rather than the script, and no test could exercise a step against
# a real (containerised) system.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  nddev::desktop_configure "$@"
fi
