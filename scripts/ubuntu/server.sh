#!/usr/bin/env bash

# Sourceable Ubuntu server bootstrap module.
#
# Default execution is a read-only plan. Mutations require --apply (or
# RLDYOUR_DRY_RUN=0). The public functions are intentionally namespaced so this
# file can be sourced by scripts/bootstrap.sh or another future orchestrator.

if ! declare -F rldyour::run >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
fi

rldyour::ubuntu_server::usage() {
  cat <<'EOF'
Usage: scripts/ubuntu/server.sh [options]

Modes:
  --plan                         Print the plan (default).
  --apply                        Apply changes explicitly.

Docker:
  --docker-mode MODE             none|rootful|rootless (default: none).

Opt-in hardening:
  --enable-ufw                   Configure an SSH allow rule, then enable UFW.
  --harden-ssh                   Require key-only SSH and disable root login.
  --enable-fail2ban              Enable the Fail2ban sshd jail.
  --ssh-port PORT                SSH port; otherwise detect with sshd -T.
  --ssh-allow-cidr CIDR          Restrict the UFW SSH rule to this CIDR.
  --ufw-console-confirmed        Confirm out-of-band console recovery when a
                                 CIDR is applied outside an SSH session.
  --ssh-user USER                Non-root account whose authorized_keys is
                                 validated before key-only SSH is enabled.
  --ssh-match-address ADDRESS    Client address used for Match-rule validation;
                                 defaults to SSH_CONNECTION when available.
  --ssh-match-host HOST          Client hostname for Match Host evaluation.
  --ssh-local-address ADDRESS    Server address for Match LocalAddress;
                                 defaults to SSH_CONNECTION when available.

Other:
  --skip-verify                  Do not run verify-server.sh after apply.
  --help                         Show this help.

Environment equivalents:
  RLDYOUR_DRY_RUN=0|1
  RLDYOUR_SERVER_DOCKER_MODE=none|rootful|rootless
  RLDYOUR_SERVER_ENABLE_UFW=0|1
  RLDYOUR_SERVER_HARDEN_SSH=0|1
  RLDYOUR_SERVER_ENABLE_FAIL2BAN=0|1
  RLDYOUR_SERVER_SSH_PORT=<1..65535>
  RLDYOUR_SERVER_SSH_ALLOW_CIDR=<IPv4/IPv6 CIDR>
  RLDYOUR_SERVER_UFW_CONSOLE_CONFIRMED=0|1
  RLDYOUR_SERVER_SSH_USER=<non-root user>
  RLDYOUR_SERVER_SSH_MATCH_ADDRESS=<client IPv4/IPv6 address>
  RLDYOUR_SERVER_SSH_MATCH_HOST=<client hostname>
  RLDYOUR_SERVER_SSH_LOCAL_ADDRESS=<server IPv4/IPv6 address>
  RLDYOUR_SERVER_SKIP_VERIFY=0|1

No firewall, SSH authentication, Fail2ban, sysctl, resource-limit, or Docker
mode change is inferred automatically.
EOF
}

rldyour::ubuntu_server::is_bool() {
  case "${1:-}" in
    0 | 1) return 0 ;;
    *) return 1 ;;
  esac
}

rldyour::ubuntu_server::validate_bool() {
  local name=$1
  local value=$2
  if ! rldyour::ubuntu_server::is_bool "$value"; then
    rldyour::log "error" "$name must be 0 or 1 (got: $value)"
    return 2
  fi
}

rldyour::ubuntu_server::os_release_value() {
  local key=$1
  local file=${2:-/etc/os-release}
  local value

  value=$(awk -F= -v wanted="$key" '
    $1 == wanted {
      sub(/^[^=]*=/, "", $0)
      print
      exit
    }
  ' "$file")
  value=${value#\"}
  value=${value%\"}
  value=${value#\'}
  value=${value%\'}
  printf '%s\n' "$value"
}

rldyour::ubuntu_server::validate_os() {
  local os_release=${RLDYOUR_SERVER_OS_RELEASE_FILE:-/etc/os-release}
  local id version codename arch

  if [ ! -r "$os_release" ]; then
    rldyour::log "error" "cannot read OS metadata: $os_release"
    return 1
  fi

  id=$(rldyour::ubuntu_server::os_release_value ID "$os_release")
  version=$(rldyour::ubuntu_server::os_release_value VERSION_ID "$os_release")
  if [ "$id" != "ubuntu" ]; then
    rldyour::log "error" "Ubuntu is required (detected ID=${id:-unknown})"
    return 1
  fi

  case "$version" in
    24.04) codename="noble" ;;
    26.04) codename="resolute" ;;
    *)
      rldyour::log "error" "supported Ubuntu releases are 24.04 and 26.04 (detected: ${version:-unknown})"
      return 1
      ;;
  esac

  if ! command -v dpkg >/dev/null 2>&1; then
    rldyour::log "error" "dpkg is required on the Ubuntu host"
    return 1
  fi
  arch=$(dpkg --print-architecture)
  case "$arch" in
    amd64 | arm64 | armhf | ppc64el | s390x) ;;
    *)
      rldyour::log "error" "Docker's Ubuntu repository does not support architecture: $arch"
      return 1
      ;;
  esac

  export RLDYOUR_SERVER_OS_VERSION=$version
  export RLDYOUR_SERVER_OS_CODENAME=$codename
  export RLDYOUR_SERVER_ARCH=$arch
  rldyour::log "ok" "Ubuntu $version ($codename), architecture $arch"
}

rldyour::ubuntu_server::validate_docker_mode() {
  case "$1" in
    none | rootful | rootless) return 0 ;;
    *)
      rldyour::log "error" "Docker mode must be none, rootful, or rootless (got: $1)"
      return 2
      ;;
  esac
}

rldyour::ubuntu_server::validate_port() {
  local port=$1
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    rldyour::log "error" "SSH port must be an integer from 1 to 65535 (got: $port)"
    return 2
  fi
}

rldyour::ubuntu_server::require_apply_privilege() {
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ] || [ "$EUID" -eq 0 ]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    rldyour::log "error" "apply mode requires root or sudo"
    return 1
  fi
  rldyour::run sudo -v
}

rldyour::ubuntu_server::as_root() {
  if [ "$EUID" -eq 0 ]; then
    rldyour::run "$@"
  else
    rldyour::run sudo "$@"
  fi
}

# Read-only privileged probes must execute even in plan mode. Avoid routing
# them through rldyour::run, whose dry-run output would corrupt captured data.
# A plan never prompts for sudo: callers can pass the value explicitly when no
# cached credential is available. Apply mode has already completed `sudo -v`.
rldyour::ubuntu_server::probe_as_root() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  elif [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    sudo -n "$@"
  else
    sudo "$@"
  fi
}

rldyour::ubuntu_server::apt_update() {
  rldyour::ubuntu_server::as_root apt-get update
}

rldyour::ubuntu_server::apt_install() {
  rldyour::ubuntu_server::as_root env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends --no-upgrade "$@"
}

rldyour::ubuntu_server::root_file_equals() {
  local source=$1
  local destination=$2

  if [ ! -e "$destination" ]; then
    return 1
  fi
  if [ -r "$destination" ]; then
    cmp -s -- "$source" "$destination"
  elif [ "$EUID" -eq 0 ]; then
    cmp -s -- "$source" "$destination"
  elif [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    return 1
  else
    sudo cmp -s -- "$source" "$destination"
  fi
}

rldyour::ubuntu_server::backup_root_file() {
  local destination=$1
  local stamp backup

  if [ ! -e "$destination" ]; then
    return 0
  fi
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup="${destination}.rldyour-backup.${stamp}"
  rldyour::ubuntu_server::as_root cp -a -- "$destination" "$backup"
  rldyour::log "info" "preserved existing config: $backup"
}

rldyour::ubuntu_server::install_managed_file() {
  local source=$1
  local destination=$2
  local mode=${3:-0644}
  local destination_dir temporary

  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    rldyour::log "error" "managed destination is not a regular file; preserved: $destination"
    return 1
  fi

  if rldyour::ubuntu_server::root_file_equals "$source" "$destination"; then
    if ! rldyour::ubuntu_server::as_root chown root:root -- "$destination" ||
      ! rldyour::ubuntu_server::as_root chmod "$mode" -- "$destination"; then
      rldyour::log "error" "managed file content is current but metadata repair failed: $destination"
      return 1
    fi
    rldyour::log "ok" "managed file content current; owner and mode enforced: $destination"
    return 0
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] install managed file $destination (mode $mode; preserve existing file)"
    return 0
  fi

  destination_dir=$(dirname "$destination")
  temporary="${destination}.rldyour.tmp.$$"
  rldyour::ubuntu_server::as_root install -d -m 0755 "$destination_dir"
  rldyour::ubuntu_server::backup_root_file "$destination"
  rldyour::ubuntu_server::as_root install -m "$mode" -- "$source" "$temporary"
  rldyour::ubuntu_server::as_root mv -f -- "$temporary" "$destination"
  rldyour::log "ok" "installed managed file: $destination"
}

rldyour::ubuntu_server::restore_managed_file() {
  local previous=$1
  local destination=$2
  local had_previous=$3

  if [ "$had_previous" -eq 1 ]; then
    rldyour::ubuntu_server::as_root cp -a -- "$previous" "$destination"
  else
    rldyour::ubuntu_server::as_root rm -f -- "$destination"
  fi
}

rldyour::ubuntu_server::package_installed() {
  dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

rldyour::ubuntu_server::configure_unattended_upgrades() (
  set -euo pipefail
  local destination=/etc/apt/apt.conf.d/52rldyour-unattended-upgrades
  local candidate previous effective
  local had_previous=0

  candidate=$(mktemp)
  previous=$(mktemp)
  trap 'rm -f -- "$candidate" "$previous" 2>/dev/null || rldyour::ubuntu_server::as_root rm -f -- "$candidate" "$previous"' EXIT
  cat >"$candidate" <<'EOF'
// Managed by macos-ubuntu-bootstrap.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && [ -e "$destination" ]; then
    had_previous=1
    rldyour::ubuntu_server::as_root cp -a -- "$destination" "$previous"
  fi
  rldyour::ubuntu_server::install_managed_file "$candidate" "$destination" 0644
  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::log "info" "[DRY-RUN] validate effective unattended-upgrades settings with apt-config dump"
    return 0
  fi

  if ! effective=$(apt-config dump 2>/dev/null) ||
    ! grep -Fqx 'APT::Periodic::Update-Package-Lists "1";' <<<"$effective" ||
    ! grep -Fqx 'APT::Periodic::Unattended-Upgrade "1";' <<<"$effective"; then
    rldyour::log "error" "APT rejected or overrode the managed unattended-upgrades settings; restoring the previous state"
    rldyour::ubuntu_server::restore_managed_file "$previous" "$destination" "$had_previous"
    return 1
  fi
  rldyour::log "ok" "unattended security updates are enabled; reboot policy remains unchanged"
)

rldyour::ubuntu_server::install_baseline() {
  rldyour::section "Ubuntu server baseline"
  rldyour::ubuntu_server::apt_update
  rldyour::ubuntu_server::apt_install ca-certificates curl gnupg openssh-server unattended-upgrades
  rldyour::ubuntu_server::configure_unattended_upgrades

  if command -v systemctl >/dev/null 2>&1; then
    rldyour::ubuntu_server::as_root systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
    rldyour::ubuntu_server::ensure_ssh_activation
  fi
}

# Preserve the host's service-vs-socket activation choice. Ubuntu packaging
# normally starts one provider; switching providers implicitly can expose port
# 22, conflict with a custom listener, or lock out a remote session.
rldyour::ubuntu_server::ensure_ssh_activation() {
  local provider=""

  if systemctl is-active --quiet ssh.service; then
    rldyour::log "ok" "ssh.service is active; preserving service activation"
    return 0
  fi
  if systemctl is-active --quiet ssh.socket; then
    rldyour::log "ok" "ssh.socket is active; preserving socket activation"
    return 0
  fi
  if systemctl is-enabled --quiet ssh.service 2>/dev/null; then
    provider=ssh.service
  elif systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    provider=ssh.socket
  elif systemctl list-unit-files --type=service --no-legend ssh.service 2>/dev/null |
    grep -q '^ssh.service'; then
    provider=ssh.service
  elif systemctl list-unit-files --type=socket --no-legend ssh.socket 2>/dev/null |
    grep -q '^ssh.socket'; then
    provider=ssh.socket
  else
    rldyour::log "error" "OpenSSH was installed but no systemd SSH provider exists"
    return 1
  fi

  rldyour::ubuntu_server::as_root systemctl enable --now "$provider"
  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 0 ] && ! systemctl is-active --quiet "$provider"; then
    rldyour::log "error" "${provider} did not become active"
    return 1
  fi
  rldyour::log "ok" "started existing OpenSSH activation provider: ${provider}"
}

rldyour::ubuntu_server::ensure_time_sync() {
  local active_time_units
  rldyour::section "Time synchronization"
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" = yes ]; then
      rldyour::log "ok" "system clock is synchronized; preserving the host time provider"
      return 0
    fi
    if systemctl is-active --quiet chrony.service; then
      rldyour::log "ok" "chrony.service is active; preserving the host provider"
      return 0
    fi
    if systemctl is-active --quiet systemd-timesyncd.service; then
      rldyour::log "ok" "systemd-timesyncd.service is active; preserving the host provider"
      return 0
    fi
    active_time_units=$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null |
      awk 'tolower($1) ~ /(chron|ntp|timesync|ptp4l|phc2sys)/ { print $1 }')
    if [ -n "$active_time_units" ]; then
      rldyour::log "warn" "an existing time provider is active but not yet synchronized; preserved: ${active_time_units//$'\n'/, }"
      return 0
    fi
    if systemctl list-unit-files --type=service --no-legend chrony.service 2>/dev/null |
      grep -q '^chrony.service'; then
      rldyour::ubuntu_server::as_root systemctl enable --now chrony.service
      return 0
    fi
    if systemctl list-unit-files --type=service --no-legend systemd-timesyncd.service 2>/dev/null |
      grep -q '^systemd-timesyncd.service'; then
      rldyour::ubuntu_server::as_root systemctl enable --now systemd-timesyncd.service
      return 0
    fi
  fi

  rldyour::log "info" "no supported time provider detected; install Ubuntu chrony"
  rldyour::ubuntu_server::apt_install chrony
  if command -v systemctl >/dev/null 2>&1; then
    rldyour::ubuntu_server::as_root systemctl enable --now chrony.service
  fi
}

rldyour::ubuntu_server::check_docker_conflicts() {
  local -a conflicts=(docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc)
  local -a installed=()
  local package

  for package in "${conflicts[@]}"; do
    if rldyour::ubuntu_server::package_installed "$package"; then
      installed+=("$package")
    fi
  done
  if [ "${#installed[@]}" -gt 0 ]; then
    rldyour::log "error" "conflicting Docker packages are installed: ${installed[*]}"
    rldyour::log "error" "review their workloads and remove them explicitly before applying this module"
    return 1
  fi
}

rldyour::ubuntu_server::docker_repo_owner_marker() {
  local kind=$1
  printf 'macos-ubuntu-bootstrap docker-apt-%s v1\n' "$kind"
}

rldyour::ubuntu_server::validate_owned_docker_path() (
  set -euo pipefail
  local destination=$1
  local kind=$2
  local marker_path="${destination}.rldyour-owner"
  local marker_candidate

  marker_candidate=$(mktemp)
  trap 'rm -f -- "$marker_candidate"' EXIT
  rldyour::ubuntu_server::docker_repo_owner_marker "$kind" >"$marker_candidate"

  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    rldyour::log "error" "Docker repository path is not a regular file; preserved: $destination"
    return 1
  fi
  if [ -L "$marker_path" ] || { [ -e "$marker_path" ] && [ ! -f "$marker_path" ]; }; then
    rldyour::log "error" "Docker repository ownership marker is not a regular file; preserved: $marker_path"
    return 1
  fi
  if [ -e "$marker_path" ] &&
    ! rldyour::ubuntu_server::root_file_equals "$marker_candidate" "$marker_path"; then
    rldyour::log "error" "unknown Docker repository ownership marker; preserved: $marker_path"
    return 1
  fi
  if [ -e "$destination" ] && [ ! -e "$marker_path" ]; then
    rldyour::log "error" "unmanaged Docker repository file exists; preserved: $destination"
    return 1
  fi
)

rldyour::ubuntu_server::preflight_owned_docker_file() (
  set -euo pipefail
  local source=$1
  local destination=$2
  local kind=$3
  local marker_path="${destination}.rldyour-owner"
  local marker_candidate

  marker_candidate=$(mktemp)
  trap 'rm -f -- "$marker_candidate"' EXIT
  rldyour::ubuntu_server::docker_repo_owner_marker "$kind" >"$marker_candidate"

  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    rldyour::log "error" "Docker repository path is not a regular file; preserved: $destination"
    return 1
  fi
  if [ -L "$marker_path" ] || { [ -e "$marker_path" ] && [ ! -f "$marker_path" ]; }; then
    rldyour::log "error" "Docker repository ownership marker is not a regular file; preserved: $marker_path"
    return 1
  fi
  if [ -e "$marker_path" ] &&
    ! rldyour::ubuntu_server::root_file_equals "$marker_candidate" "$marker_path"; then
    rldyour::log "error" "unknown Docker repository ownership marker; preserved: $marker_path"
    return 1
  fi
  if [ -e "$destination" ] && [ ! -e "$marker_path" ] &&
    ! rldyour::ubuntu_server::root_file_equals "$source" "$destination"; then
    rldyour::log "error" "unmanaged Docker repository file differs; preserved: $destination"
    return 1
  fi
)

rldyour::ubuntu_server::install_owned_docker_file() (
  set -euo pipefail
  local source=$1
  local destination=$2
  local kind=$3
  local mode=${4:-0644}
  local marker_path="${destination}.rldyour-owner"
  local marker_candidate
  local destination_exists=0 marker_exists=0

  marker_candidate=$(mktemp)
  trap 'rm -f -- "$marker_candidate"' EXIT
  rldyour::ubuntu_server::docker_repo_owner_marker "$kind" >"$marker_candidate"

  rldyour::ubuntu_server::preflight_owned_docker_file "$source" "$destination" "$kind"

  [ -e "$destination" ] && destination_exists=1
  [ -e "$marker_path" ] && marker_exists=1
  if [ "$destination_exists" -eq 1 ] && [ "$marker_exists" -eq 0 ]; then
    rldyour::log "info" "adopting exact known Docker repository content: $destination"
  fi

  rldyour::ubuntu_server::install_managed_file "$source" "$destination" "$mode"
  rldyour::ubuntu_server::install_managed_file "$marker_candidate" "$marker_path" 0644
)

rldyour::ubuntu_server::reject_conflicting_docker_sources() {
  local managed_source=/etc/apt/sources.list.d/rldyour-docker.sources
  local source_file

  for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -e "$source_file" ] || continue
    [ "$source_file" = "$managed_source" ] && continue
    if [ ! -f "$source_file" ] || [ ! -r "$source_file" ]; then
      rldyour::log "error" "cannot safely inspect existing apt source; preserved: $source_file"
      return 1
    fi
    if grep -Fq 'download.docker.com/linux/ubuntu' "$source_file"; then
      rldyour::log "error" "an unmanaged Docker apt source already exists; preserved: $source_file"
      rldyour::log "error" "review/remove or migrate it explicitly before this module manages Docker packages"
      return 1
    fi
  done
}

rldyour::ubuntu_server::configure_docker_repo() (
  set -euo pipefail
  local expected_fingerprint=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
  local key_path=/etc/apt/keyrings/rldyour-docker.asc
  local source_path=/etc/apt/sources.list.d/rldyour-docker.sources
  local tmp_key tmp_source primary_fingerprint

  tmp_source=$(mktemp)
  trap 'rm -f -- "${tmp_key:-}" "$tmp_source"' EXIT
  cat >"$tmp_source" <<EOF
# Managed by macos-ubuntu-bootstrap; exact ownership is recorded in a sidecar.
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $RLDYOUR_SERVER_OS_CODENAME
Components: stable
Architectures: $RLDYOUR_SERVER_ARCH
Signed-By: $key_path
EOF

  rldyour::ubuntu_server::reject_conflicting_docker_sources

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::ubuntu_server::validate_owned_docker_path "$key_path" key
    rldyour::ubuntu_server::validate_owned_docker_path "$source_path" source
    rldyour::log "info" "[DRY-RUN] download Docker apt key without executing remote code"
    rldyour::log "info" "[DRY-RUN] verify Docker key fingerprint: $expected_fingerprint"
    rldyour::log "info" "[DRY-RUN] install owned key $key_path"
    rldyour::log "info" "[DRY-RUN] install owned deb822 source $source_path for $RLDYOUR_SERVER_OS_CODENAME"
    return 0
  fi

  tmp_key=$(mktemp)

  curl --proto '=https' --tlsv1.2 -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp_key"
  if ! primary_fingerprint=$(gpg --batch --show-keys --with-colons "$tmp_key" |
    awk -F: '
      $1 == "pub" { primary_count++; awaiting_primary_fpr=1; next }
      $1 == "fpr" && awaiting_primary_fpr { primary_fpr=toupper($10); awaiting_primary_fpr=0 }
      END {
        if (primary_count != 1 || primary_fpr == "") exit 1
        print primary_fpr
      }
    ') || [ "$primary_fingerprint" != "$expected_fingerprint" ]; then
    rldyour::log "error" "Docker apt key fingerprint verification failed"
    return 1
  fi

  rldyour::ubuntu_server::preflight_owned_docker_file "$tmp_key" "$key_path" key
  rldyour::ubuntu_server::preflight_owned_docker_file "$tmp_source" "$source_path" source
  rldyour::ubuntu_server::as_root install -d -m 0755 /etc/apt/keyrings
  rldyour::ubuntu_server::install_owned_docker_file "$tmp_key" "$key_path" key 0644
  rldyour::ubuntu_server::install_owned_docker_file "$tmp_source" "$source_path" source 0644
)

rldyour::ubuntu_server::install_docker_packages() {
  local mode=$1
  local -a packages=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
  )

  rldyour::section "Docker Engine ($mode)"
  rldyour::ubuntu_server::check_docker_conflicts

  if [ "$mode" = rootful ]; then
    local installed_count=0 package
    for package in "${packages[@]}"; do
      rldyour::ubuntu_server::package_installed "$package" && installed_count=$((installed_count + 1))
    done
    if [ "$installed_count" -eq "${#packages[@]}" ]; then
      if ! rldyour::ubuntu_server::docker_rootful_runtime_active ||
        ! rldyour::ubuntu_server::as_root docker info >/dev/null 2>&1; then
        rldyour::log "error" "existing Docker CE packages are not healthy; preserving them without upgrade or restart"
        return 1
      fi
      rldyour::log "ok" "healthy existing Docker CE installation preserved; no package transaction"
      return 0
    fi
    if [ "$installed_count" -ne 0 ]; then
      rldyour::log "error" "partial existing Docker CE package set detected; preserving it without upgrade"
      return 1
    fi
    if rldyour::ubuntu_server::docker_rootful_state_present; then
      rldyour::log "error" "non-package Docker/containerd runtime, socket, service, or data exists; preserving it without Docker CE installation"
      return 1
    fi
  fi

  rldyour::ubuntu_server::configure_docker_repo
  rldyour::ubuntu_server::apt_update

  if [ "$mode" = "rootless" ]; then
    if [ "${RLDYOUR_SERVER_ROOTLESS_PREFLIGHT_STATE:-}" != clean ] ||
      [ "${RLDYOUR_SERVER_ROOTFUL_PREEXISTED:-1}" -ne 0 ] ||
      rldyour::ubuntu_server::docker_rootful_state_present; then
      rldyour::log "error" "Docker/containerd state changed after rootless preflight; refusing package installation"
      return 1
    fi
    packages+=(docker-ce-rootless-extras uidmap dbus-user-session slirp4netns)
  fi
  rldyour::ubuntu_server::apt_install "${packages[@]}"
}

rldyour::ubuntu_server::install_docker_rootful() {
  rldyour::ubuntu_server::install_docker_packages rootful
  if command -v systemctl >/dev/null 2>&1; then
    rldyour::ubuntu_server::as_root systemctl enable --now containerd.service docker.service
  fi
  rldyour::log "warn" "the docker group is intentionally unchanged; membership is root-equivalent"
  rldyour::log "warn" "published container ports bypass ordinary UFW input rules; enforce exposure separately"
}

rldyour::ubuntu_server::subid_range_is_sufficient() {
  local file=$1
  local user=$2
  awk -F: -v user="$user" '
    $1 == user && $3 >= 65536 { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

rldyour::ubuntu_server::docker_rootless_packages_installed() {
  local package
  for package in \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    docker-ce-rootless-extras \
    uidmap \
    dbus-user-session \
    slirp4netns; do
    rldyour::ubuntu_server::package_installed "$package" || return 1
  done
}

rldyour::ubuntu_server::docker_rootless_context_exists() {
  command -v docker >/dev/null 2>&1 && docker context inspect rootless >/dev/null 2>&1
}

rldyour::ubuntu_server::docker_rootless_context_uses_user_socket() {
  [ "$(docker context inspect rootless --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" = "unix:///run/user/$(id -u)/docker.sock" ]
}

rldyour::ubuntu_server::docker_rootless_daemon_ready() {
  rldyour::ubuntu_server::docker_rootless_context_exists &&
    rldyour::ubuntu_server::docker_rootless_context_uses_user_socket &&
    systemctl --user is-active --quiet docker.service &&
    docker --context rootless info --format '{{json .SecurityOptions}}' 2>/dev/null |
      grep -q 'rootless'
}

rldyour::ubuntu_server::docker_rootful_runtime_active() {
  if command -v systemctl >/dev/null 2>&1 &&
    { systemctl is-active --quiet docker.service ||
      systemctl is-active --quiet docker.socket ||
      systemctl is-active --quiet containerd.service; }; then
    return 0
  fi
  if [ -S /run/docker.sock ] || [ -S /var/run/docker.sock ]; then
    return 0
  fi
  if command -v ps >/dev/null 2>&1 &&
    ps -eo uid=,comm= 2>/dev/null |
      awk '$1 == 0 && ($2 == "dockerd" || $2 == "containerd") { found = 1 } END { exit(found ? 0 : 1) }'; then
    return 0
  fi
  return 1
}

rldyour::ubuntu_server::docker_rootful_state_present() {
  local package

  rldyour::ubuntu_server::docker_rootful_runtime_active && return 0
  for package in docker-ce docker.io containerd.io containerd podman-docker; do
    rldyour::ubuntu_server::package_installed "$package" && return 0
  done
  if command -v systemctl >/dev/null 2>&1 &&
    systemctl list-unit-files --no-legend docker.service docker.socket containerd.service 2>/dev/null |
      grep -Eq '^(docker\.service|docker\.socket|containerd\.service)[[:space:]]'; then
    return 0
  fi
  [ -e /var/lib/docker ] || [ -e /var/lib/containerd ]
}

rldyour::ubuntu_server::docker_rootless_preflight() {
  RLDYOUR_SERVER_ROOTLESS_PREFLIGHT_STATE=clean
  RLDYOUR_SERVER_ROOTFUL_PREEXISTED=0

  if rldyour::ubuntu_server::docker_rootless_daemon_ready; then
    RLDYOUR_SERVER_ROOTLESS_PREFLIGHT_STATE=ready
    if rldyour::ubuntu_server::docker_rootful_state_present; then
      RLDYOUR_SERVER_ROOTFUL_PREEXISTED=1
      rldyour::log "warn" "existing rootful Docker/containerd state will be preserved; no daemon migration is attempted"
    fi
    return 0
  fi

  if rldyour::ubuntu_server::docker_rootless_context_exists; then
    if ! rldyour::ubuntu_server::docker_rootless_context_uses_user_socket; then
      rldyour::log "error" "the rootless context does not target this user's local rootless socket; preserving it unchanged"
      return 1
    fi
    if rldyour::ubuntu_server::docker_rootful_runtime_active; then
      rldyour::log "error" "rootless context exists but is not healthy while a rootful runtime is active"
      rldyour::log "error" "preserving both states; repair or migrate explicitly before rerunning"
      return 1
    fi
    if ! rldyour::ubuntu_server::docker_rootless_packages_installed; then
      rldyour::log "error" "partial rootless configuration is missing required packages; preserving it unchanged"
      return 1
    fi
    RLDYOUR_SERVER_ROOTLESS_PREFLIGHT_STATE=configured
    RLDYOUR_SERVER_ROOTFUL_PREEXISTED=1
    rldyour::log "info" "inactive rootless context detected with no active rootful runtime; only the user service will be repaired"
    return 0
  fi

  if rldyour::ubuntu_server::docker_rootful_state_present; then
    RLDYOUR_SERVER_ROOTFUL_PREEXISTED=1
    rldyour::log "error" "existing rootful Docker/containerd installation, runtime, socket, or data detected"
    rldyour::log "error" "automatic rootful-to-rootless migration is intentionally unsupported; existing state was not changed"
    return 1
  fi

  rldyour::log "ok" "rootless preflight found no pre-existing Docker/containerd state"
}

rldyour::ubuntu_server::system_unit_owned_by_package() {
  local unit=$1
  local package=$2
  local fragment canonical candidate

  fragment=$(systemctl show --property=FragmentPath --value "$unit" 2>/dev/null) || return 1
  [ -n "$fragment" ] || return 1
  canonical=$(readlink -f -- "$fragment") || return 1
  while IFS= read -r candidate; do
    [ -e "$candidate" ] || continue
    if [ "$(readlink -f -- "$candidate")" = "$canonical" ]; then
      return 0
    fi
  done < <(dpkg-query -L "$package" 2>/dev/null)
  return 1
}

rldyour::ubuntu_server::rootful_workloads_absent() {
  local socket="" namespace="" namespaces="" output=""

  if [ -S /run/docker.sock ]; then
    socket=/run/docker.sock
  elif [ -S /var/run/docker.sock ]; then
    socket=/var/run/docker.sock
  fi
  if [ -n "$socket" ]; then
    if ! output=$(rldyour::ubuntu_server::as_root docker --host "unix://$socket" ps --all --quiet); then
      rldyour::log "error" "cannot prove the newly installed rootful Docker daemon has no workloads"
      return 1
    fi
    if [ -n "$output" ]; then
      rldyour::log "error" "rootful Docker acquired containers after preflight; preserving the runtime"
      return 1
    fi
    if ! output=$(rldyour::ubuntu_server::as_root docker --host "unix://$socket" image list --quiet); then
      rldyour::log "error" "cannot inspect images in the newly installed rootful Docker daemon"
      return 1
    fi
    if [ -n "$output" ]; then
      rldyour::log "error" "rootful Docker acquired images after preflight; preserving the runtime"
      return 1
    fi
    if ! output=$(rldyour::ubuntu_server::as_root docker --host "unix://$socket" volume list --quiet); then
      rldyour::log "error" "cannot inspect volumes in the newly installed rootful Docker daemon"
      return 1
    fi
    if [ -n "$output" ]; then
      rldyour::log "error" "rootful Docker acquired volumes after preflight; preserving the runtime"
      return 1
    fi
  fi

  if systemctl is-active --quiet containerd.service; then
    if ! namespaces=$(rldyour::ubuntu_server::as_root ctr namespaces list --quiet); then
      rldyour::log "error" "cannot inspect the newly installed system containerd namespaces"
      return 1
    fi
    while IFS= read -r namespace; do
      [ -n "$namespace" ] || continue
      if ! output=$(rldyour::ubuntu_server::as_root ctr --namespace "$namespace" containers list --quiet); then
        rldyour::log "error" "cannot inspect system containerd namespace: $namespace"
        return 1
      fi
      if [ -n "$output" ]; then
        rldyour::log "error" "system containerd acquired workloads after preflight; preserving the runtime"
        return 1
      fi
      if ! output=$(rldyour::ubuntu_server::as_root ctr --namespace "$namespace" images list --quiet); then
        rldyour::log "error" "cannot inspect images in system containerd namespace: $namespace"
        return 1
      fi
      if [ -n "$output" ]; then
        rldyour::log "error" "system containerd acquired images after preflight; preserving the runtime"
        return 1
      fi
    done <<<"$namespaces"
  fi
}

rldyour::ubuntu_server::stop_new_rootful_units_after_rootless_ready() {
  if [ "${RLDYOUR_SERVER_ROOTLESS_PREFLIGHT_STATE:-}" != clean ] ||
    [ "${RLDYOUR_SERVER_ROOTFUL_PREEXISTED:-1}" -ne 0 ]; then
    rldyour::log "error" "refusing to stop rootful units not proven to originate from this clean installation"
    return 1
  fi
  if ! rldyour::ubuntu_server::docker_rootless_daemon_ready; then
    rldyour::log "error" "refusing to stop newly installed rootful units before rootless Docker is healthy"
    return 1
  fi
  if ! rldyour::ubuntu_server::system_unit_owned_by_package docker.service docker-ce ||
    ! rldyour::ubuntu_server::system_unit_owned_by_package docker.socket docker-ce ||
    ! rldyour::ubuntu_server::system_unit_owned_by_package containerd.service containerd.io; then
    rldyour::log "error" "rootful unit provenance does not match packages installed by this clean invocation; preserving units"
    return 1
  fi
  if ! rldyour::ubuntu_server::rootful_workloads_absent; then
    return 1
  fi

  rldyour::ubuntu_server::as_root systemctl disable --now docker.socket docker.service containerd.service
  if rldyour::ubuntu_server::docker_rootful_runtime_active; then
    rldyour::log "error" "newly installed rootful runtime remains active; rootless daemon was left running"
    return 1
  fi
  rldyour::log "ok" "disabled only rootful units created by this clean package installation"
}

rldyour::ubuntu_server::install_docker_rootless() {
  local user state

  if [ "$EUID" -eq 0 ]; then
    rldyour::log "error" "rootless mode must be invoked by the target non-root user, not via sudo server.sh"
    return 1
  fi
  user=$(id -un)
  if ! rldyour::ubuntu_server::subid_range_is_sufficient /etc/subuid "$user" ||
    ! rldyour::ubuntu_server::subid_range_is_sufficient /etc/subgid "$user"; then
    rldyour::log "error" "rootless Docker requires at least 65536 subordinate UIDs and GIDs for $user"
    rldyour::log "error" "allocate non-overlapping ranges explicitly before rerunning"
    return 1
  fi

  rldyour::ubuntu_server::docker_rootless_preflight
  state=$RLDYOUR_SERVER_ROOTLESS_PREFLIGHT_STATE

  if [ "$state" = ready ] || [ "$state" = configured ]; then
    if ! rldyour::ubuntu_server::docker_rootless_packages_installed; then
      rldyour::log "error" "existing rootless Docker is missing the required package set; no package migration was attempted"
      return 1
    fi
  else
    rldyour::ubuntu_server::install_docker_packages rootless
  fi

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    if [ "$state" = clean ]; then
      rldyour::log "info" "[DRY-RUN] create rootless context, start and health-check it before stopping newly created rootful units"
    else
      rldyour::log "info" "[DRY-RUN] preserve all rootful state and verify the existing rootless context for $user"
    fi
    rldyour::log "info" "[DRY-RUN] loginctl enable-linger $user"
    return 0
  fi
  if ! command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
    rldyour::log "error" "docker-ce-rootless-extras did not provide dockerd-rootless-setuptool.sh"
    return 1
  fi
  if ! docker context inspect rootless >/dev/null 2>&1; then
    if [ "$state" != clean ]; then
      rldyour::log "error" "refusing to create a missing rootless context over pre-existing Docker state"
      return 1
    fi
    dockerd-rootless-setuptool.sh install --force
  else
    rldyour::log "ok" "Docker rootless context already exists"
  fi
  rldyour::ubuntu_server::as_root loginctl enable-linger "$user"
  systemctl --user enable --now docker.service

  if ! rldyour::ubuntu_server::docker_rootless_daemon_ready; then
    rldyour::log "error" "rootless Docker failed its context, user-service, or daemon health check"
    rldyour::log "error" "pre-existing rootful state was not stopped; clean-install package services remain available for recovery"
    return 1
  fi
  rldyour::log "ok" "rootless Docker daemon is healthy"

  if [ "$state" = clean ]; then
    rldyour::ubuntu_server::stop_new_rootful_units_after_rootless_ready
    rldyour::ubuntu_server::docker_rootless_daemon_ready
  else
    rldyour::log "ok" "existing rootful Docker/containerd units and sockets were not changed"
  fi
}

rldyour::ubuntu_server::detect_ssh_port() {
  local configured=${1:-}
  local detected effective port_count session_port=""

  if [ -n "${SSH_CONNECTION:-}" ]; then
    # shellcheck disable=SC2086
    set -- $SSH_CONNECTION
    if [ "$#" -ne 4 ]; then
      rldyour::log "error" "SSH_CONNECTION is malformed; pass --ssh-port explicitly" >&2
      return 1
    fi
    session_port=$4
    rldyour::ubuntu_server::validate_port "$session_port" >&2 || return 1
  fi

  if [ -n "$configured" ]; then
    rldyour::ubuntu_server::validate_port "$configured" >&2 || return 1
    if [ -n "$session_port" ] && [ "$configured" != "$session_port" ]; then
      rldyour::log "error" "explicit SSH port ${configured} differs from the live session port ${session_port}" >&2
      return 1
    fi
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ssh.socket; then
    detected=${configured:-$session_port}
    if [ -z "$detected" ]; then
      rldyour::log "error" "ssh.socket owns the listener; pass --ssh-port or run from the target SSH session" >&2
      return 1
    fi
    printf '%s\n' "$detected"
    return 0
  fi

  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ] && [ -n "$configured" ]; then
    printf '%s\n' "$configured"
    return 0
  fi

  if command -v sshd >/dev/null 2>&1; then
    if ! effective=$(rldyour::ubuntu_server::probe_as_root sshd -T 2>/dev/null); then
      rldyour::log "error" "cannot read the effective OpenSSH port; pass --ssh-port explicitly" >&2
      return 1
    fi
    detected=$(awk '$1 == "port" { print $2 }' <<<"$effective" | sort -u)
    port_count=$(grep -Ec '^[0-9]+$' <<<"$detected" || true)
    if [ "$port_count" -ne 1 ] || [ "$(wc -l <<<"$detected" | tr -d ' ')" -ne 1 ]; then
      rldyour::log "error" "OpenSSH did not report exactly one numeric port; pass --ssh-port explicitly" >&2
      return 1
    fi
  else
    detected=${configured:-22}
  fi
  rldyour::ubuntu_server::validate_port "$detected" >&2
  if [ -n "$configured" ] && [ "$configured" != "$detected" ]; then
    rldyour::log "error" "explicit SSH port ${configured} differs from sshd effective port ${detected}" >&2
    return 1
  fi
  if [ -n "$session_port" ] && [ "$session_port" != "$detected" ]; then
    rldyour::log "error" "live SSH session port ${session_port} differs from sshd effective port ${detected}" >&2
    return 1
  fi
  printf '%s\n' "$detected"
}

rldyour::ubuntu_server::ufw_status_has_ssh_rule() {
  local status=$1
  local port=$2
  local allow_cidr=${3:-}
  local line

  if [ -n "$allow_cidr" ]; then
    allow_cidr=$(rldyour::ubuntu_server::canonicalize_cidr "$allow_cidr") || return 1
  fi

  while IFS= read -r line; do
    if grep -Eq "(^|[[:space:]])${port}(/tcp)?([[:space:]]|$)" <<<"$line" &&
      grep -Eq '(^|[[:space:]])ALLOW([[:space:]]|$)' <<<"$line"; then
      if { [ -z "$allow_cidr" ] && grep -Fq 'Anywhere' <<<"$line"; } ||
        { [ -n "$allow_cidr" ] && grep -Fq "$allow_cidr" <<<"$line"; }; then
        return 0
      fi
    fi
  done <<<"$status"
  return 1
}

rldyour::ubuntu_server::canonicalize_cidr() {
  local allow_cidr=$1

  [ -n "$allow_cidr" ] || return 1
  env -u PYTHONHOME -u PYTHONPATH python3 -I - "$allow_cidr" 2>/dev/null <<'PY'
import ipaddress
import sys

print(ipaddress.ip_network(sys.argv[1], strict=False))
PY
}

rldyour::ubuntu_server::validate_ufw_operator_source() {
  local allow_cidr=$1 client_address=""

  [ -n "$allow_cidr" ] || return 0
  if ! allow_cidr=$(rldyour::ubuntu_server::canonicalize_cidr "$allow_cidr"); then
    rldyour::log "error" "invalid UFW allow CIDR"
    return 1
  fi
  if [ -n "${SSH_CONNECTION:-}" ]; then
    # shellcheck disable=SC2086
    set -- $SSH_CONNECTION
    [ "$#" -eq 4 ] || {
      rldyour::log "error" "SSH_CONNECTION is malformed; refusing CIDR-restricted UFW enablement"
      return 1
    }
    client_address=$1
    if ! env -u PYTHONHOME -u PYTHONPATH python3 -I - "$client_address" "$allow_cidr" 2>/dev/null <<'PY'
import ipaddress
import sys

client = ipaddress.ip_address(sys.argv[1])
network = ipaddress.ip_network(sys.argv[2], strict=False)
raise SystemExit(0 if client in network else 1)
PY
    then
      rldyour::log "error" "current SSH client ${client_address} is outside UFW allow CIDR ${allow_cidr}"
      return 1
    fi
    rldyour::log "ok" "current SSH client is inside the requested UFW allow CIDR"
    return 0
  fi
  if [ "${RLDYOUR_SERVER_UFW_CONSOLE_CONFIRMED:-0}" != 1 ]; then
    rldyour::log "error" "CIDR-restricted UFW outside SSH requires --ufw-console-confirmed and verified console recovery"
    return 1
  fi
  rldyour::log "warn" "CIDR-restricted UFW approved through explicit out-of-band console confirmation"
}

rldyour::ubuntu_server::snapshot_ufw_file() {
  local source=$1
  local backup=$2

  if [ ! -e "$source" ]; then
    return 1
  fi
  if [ -L "$source" ] || [ ! -f "$source" ]; then
    rldyour::log "error" "cannot safely snapshot non-regular UFW config: $source"
    return 2
  fi
  if ! rldyour::ubuntu_server::as_root cp -a -- "$source" "$backup"; then
    rldyour::log "error" "cannot snapshot UFW config before mutation: $source"
    return 2
  fi
}

rldyour::ubuntu_server::restore_ufw_snapshot_file() {
  local backup=$1
  local destination=$2
  local existed=$3

  if [ "$existed" -eq 1 ]; then
    rldyour::ubuntu_server::as_root cp -a -- "$backup" "$destination"
  else
    rldyour::ubuntu_server::as_root rm -f -- "$destination"
  fi
}

rldyour::ubuntu_server::rollback_ufw() {
  local backup_dir=$1
  local was_active=$2
  local had_user_rules=$3
  local had_user6_rules=$4
  local had_ufw_conf=$5
  local had_default_ufw=$6
  local rollback_failed=0

  rldyour::log "warn" "UFW apply failed; restoring the pre-change configuration snapshot"
  rldyour::ubuntu_server::restore_ufw_snapshot_file "$backup_dir/user.rules" /etc/ufw/user.rules "$had_user_rules" || rollback_failed=1
  rldyour::ubuntu_server::restore_ufw_snapshot_file "$backup_dir/user6.rules" /etc/ufw/user6.rules "$had_user6_rules" || rollback_failed=1
  rldyour::ubuntu_server::restore_ufw_snapshot_file "$backup_dir/ufw.conf" /etc/ufw/ufw.conf "$had_ufw_conf" || rollback_failed=1
  rldyour::ubuntu_server::restore_ufw_snapshot_file "$backup_dir/default-ufw" /etc/default/ufw "$had_default_ufw" || rollback_failed=1

  if [ "$was_active" -eq 1 ]; then
    rldyour::ubuntu_server::as_root ufw --force enable || rollback_failed=1
  else
    rldyour::ubuntu_server::as_root ufw --force disable || rollback_failed=1
  fi
  if [ "$rollback_failed" -ne 0 ]; then
    rldyour::log "error" "UFW rollback was incomplete; keep the current SSH session open and repair from console access"
    return 1
  fi
  rldyour::log "ok" "UFW configuration and prior active/inactive state restored"
}

rldyour::ubuntu_server::configure_ufw() (
  set -euo pipefail
  local port=$1
  local allow_cidr=${2:-}
  local backup_dir status
  local was_active=0
  local had_user_rules=0 had_user6_rules=0 had_ufw_conf=0 had_default_ufw=0

  rldyour::section "UFW (explicit opt-in)"
  if [ -n "$allow_cidr" ]; then
    if ! allow_cidr=$(rldyour::ubuntu_server::canonicalize_cidr "$allow_cidr"); then
      rldyour::log "error" "invalid UFW allow CIDR"
      return 1
    fi
  fi
  rldyour::ubuntu_server::validate_ufw_operator_source "$allow_cidr"
  rldyour::ubuntu_server::apt_install ufw
  if [ -n "$allow_cidr" ]; then
    rldyour::ubuntu_server::as_root ufw --dry-run allow proto tcp from "$allow_cidr" to any port "$port"
  else
    rldyour::ubuntu_server::as_root ufw --dry-run allow "${port}/tcp"
  fi

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    if [ -n "$allow_cidr" ]; then
      rldyour::ubuntu_server::as_root ufw allow proto tcp from "$allow_cidr" to any port "$port"
    else
      rldyour::ubuntu_server::as_root ufw allow "${port}/tcp"
    fi
    rldyour::ubuntu_server::as_root ufw default deny incoming
    rldyour::ubuntu_server::as_root ufw default allow outgoing
    rldyour::ubuntu_server::as_root ufw --force enable
    rldyour::log "info" "[DRY-RUN] snapshot UFW config and restore it automatically on local apply/validation failure"
    return 0
  fi

  if ! status=$(rldyour::ubuntu_server::as_root env LC_ALL=C ufw status); then
    rldyour::log "error" "cannot read UFW state; no firewall changes were made"
    return 1
  fi
  grep -q '^Status: active' <<<"$status" && was_active=1

  backup_dir=$(mktemp -d)
  trap 'rm -rf -- "$backup_dir" 2>/dev/null || rldyour::ubuntu_server::as_root rm -rf -- "$backup_dir"' EXIT
  if rldyour::ubuntu_server::snapshot_ufw_file /etc/ufw/user.rules "$backup_dir/user.rules"; then
    had_user_rules=1
  elif [ "$?" -eq 2 ]; then
    return 1
  fi
  if rldyour::ubuntu_server::snapshot_ufw_file /etc/ufw/user6.rules "$backup_dir/user6.rules"; then
    had_user6_rules=1
  elif [ "$?" -eq 2 ]; then
    return 1
  fi
  if rldyour::ubuntu_server::snapshot_ufw_file /etc/ufw/ufw.conf "$backup_dir/ufw.conf"; then
    had_ufw_conf=1
  elif [ "$?" -eq 2 ]; then
    return 1
  fi
  if rldyour::ubuntu_server::snapshot_ufw_file /etc/default/ufw "$backup_dir/default-ufw"; then
    had_default_ufw=1
  elif [ "$?" -eq 2 ]; then
    return 1
  fi

  if [ -n "$allow_cidr" ]; then
    if ! rldyour::ubuntu_server::as_root ufw allow proto tcp from "$allow_cidr" to any port "$port"; then
      rldyour::ubuntu_server::rollback_ufw "$backup_dir" "$was_active" "$had_user_rules" "$had_user6_rules" "$had_ufw_conf" "$had_default_ufw" || true
      return 1
    fi
  elif ! rldyour::ubuntu_server::as_root ufw allow "${port}/tcp"; then
    rldyour::ubuntu_server::rollback_ufw "$backup_dir" "$was_active" "$had_user_rules" "$had_user6_rules" "$had_ufw_conf" "$had_default_ufw" || true
    return 1
  fi
  if ! rldyour::ubuntu_server::as_root ufw default deny incoming ||
    ! rldyour::ubuntu_server::as_root ufw default allow outgoing ||
    ! rldyour::ubuntu_server::as_root ufw --force enable; then
    rldyour::ubuntu_server::rollback_ufw "$backup_dir" "$was_active" "$had_user_rules" "$had_user6_rules" "$had_ufw_conf" "$had_default_ufw" || true
    return 1
  fi
  if ! status=$(rldyour::ubuntu_server::as_root env LC_ALL=C ufw status) ||
    ! grep -q '^Status: active' <<<"$status" ||
    ! rldyour::ubuntu_server::ufw_status_has_ssh_rule "$status" "$port" "$allow_cidr"; then
    rldyour::log "error" "UFW did not reach the expected active state with the SSH allow rule"
    rldyour::ubuntu_server::rollback_ufw "$backup_dir" "$was_active" "$had_user_rules" "$had_user6_rules" "$had_ufw_conf" "$had_default_ufw" || true
    return 1
  fi

  rldyour::log "ok" "UFW active with the expected SSH allow rule"
  rldyour::log "warn" "keep the current SSH session open until a second connection succeeds"
)

rldyour::ubuntu_server::resolve_ssh_user() {
  local requested=${1:-}
  local candidate

  if [ -n "$requested" ]; then
    candidate=$requested
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    candidate=$SUDO_USER
  elif [ "$EUID" -ne 0 ]; then
    candidate=$(id -un)
  else
    rldyour::log "error" "key-only SSH hardening requires --ssh-user when invoked as root" >&2
    return 1
  fi
  if [ "$candidate" = "root" ] || ! getent passwd "$candidate" >/dev/null; then
    rldyour::log "error" "SSH hardening user must be an existing non-root account (got: $candidate)" >&2
    return 1
  fi
  printf '%s\n' "$candidate"
}

rldyour::ubuntu_server::validate_authorized_keys() {
  local user=$1
  local home ssh_dir authorized_keys user_uid metadata owner mode path label fingerprints records

  home=$(getent passwd "$user" | awk -F: '{ print $6 }')
  ssh_dir="$home/.ssh"
  authorized_keys="$ssh_dir/authorized_keys"
  user_uid=$(id -u "$user") || return 1
  if ! rldyour::ubuntu_server::probe_as_root test -r "$authorized_keys"; then
    rldyour::log "error" "cannot enable key-only SSH: missing readable $authorized_keys"
    return 1
  fi

  for path in "$home" "$ssh_dir" "$authorized_keys"; do
    case "$path" in
      "$home") label=home ;;
      "$ssh_dir") label=.ssh ;;
      *) label=authorized_keys ;;
    esac
    if rldyour::ubuntu_server::probe_as_root test -L "$path"; then
      rldyour::log "error" "cannot enable key-only SSH: ${label} must not be a symlink (${path})"
      return 1
    fi
    if [ "$path" = "$authorized_keys" ]; then
      rldyour::ubuntu_server::probe_as_root test -f "$path" || {
        rldyour::log "error" "cannot enable key-only SSH: ${path} is not a regular file"
        return 1
      }
    else
      rldyour::ubuntu_server::probe_as_root test -d "$path" || {
        rldyour::log "error" "cannot enable key-only SSH: ${path} is not a directory"
        return 1
      }
    fi
    metadata=$(rldyour::ubuntu_server::probe_as_root stat -c '%u %a' -- "$path") || {
      rldyour::log "error" "cannot inspect StrictModes metadata: ${path}"
      return 1
    }
    owner=${metadata%% *}
    mode=${metadata##* }
    if { [ "$owner" != "$user_uid" ] && [ "$owner" != 0 ]; } ||
      [ $((8#$mode & 0022)) -ne 0 ]; then
      rldyour::log "error" "cannot enable key-only SSH: unsafe owner/mode for ${path} (uid=${owner}, mode=${mode})"
      return 1
    fi
  done

  if ! fingerprints=$(rldyour::ubuntu_server::probe_as_root ssh-keygen -l -f "$authorized_keys" 2>/dev/null) ||
    ! grep -Eq '\((ED25519|RSA|ECDSA|ED25519-SK|ECDSA-SK)\)$' <<<"$fingerprints"; then
    rldyour::log "error" "cannot enable key-only SSH: no parseable supported public key found for $user"
    return 1
  fi
  records=$(sed -nE 's/^([0-9]+)[[:space:]].*\((ED25519|RSA|ECDSA|ED25519-SK|ECDSA-SK)\)$/\2:\1/p' <<<"$fingerprints")
  [ -n "$records" ] || return 1
  RLDYOUR_VALIDATED_SSH_KEY_RECORDS=$records
  rldyour::log "ok" "authorized key and StrictModes preflight passed for $user"
}

rldyour::ubuntu_server::ssh_effective_accepts_validated_key() {
  local effective=$1 accepted family bits required_rsa_size
  accepted=$(sed -n 's/^pubkeyacceptedalgorithms //p' <<<"$effective")
  required_rsa_size=$(sed -n 's/^requiredrsasize //p' <<<"$effective")
  [ -n "$accepted" ] && [[ "$required_rsa_size" =~ ^[0-9]+$ ]] || return 1

  while IFS=: read -r family bits; do
    case "$family" in
      ED25519) grep -Eq '(^|,)ssh-ed25519(,|$)' <<<"$accepted" && return 0 ;;
      RSA)
        [ "$bits" -ge "$required_rsa_size" ] &&
          grep -Eq '(^|,)(rsa-sha2-512|rsa-sha2-256|ssh-rsa)(,|$)' <<<"$accepted" && return 0
        ;;
      ECDSA)
        case "$bits" in
          256|384|521)
            grep -Eq "(^|,)ecdsa-sha2-nistp${bits}(,|$)" <<<"$accepted" && return 0
            ;;
        esac
        ;;
      ED25519-SK) grep -Eq '(^|,)sk-ssh-ed25519@openssh\.com(,|$)' <<<"$accepted" && return 0 ;;
      ECDSA-SK)
        [ "$bits" = 256 ] &&
          grep -Eq '(^|,)sk-ecdsa-sha2-nistp256@openssh\.com(,|$)' <<<"$accepted" && return 0
        ;;
    esac
  done <<<"${RLDYOUR_VALIDATED_SSH_KEY_RECORDS:-}"
  return 1
}

rldyour::ubuntu_server::ssh_match_context() {
  local user=$1 expected_port=${2:-}
  local address=${RLDYOUR_SERVER_SSH_MATCH_ADDRESS:-}
  local host=${RLDYOUR_SERVER_SSH_MATCH_HOST:-}
  local local_address=${RLDYOUR_SERVER_SSH_LOCAL_ADDRESS:-}
  local local_port=$expected_port
  local use_dns

  if [ -n "${SSH_CONNECTION:-}" ]; then
    # shellcheck disable=SC2086
    set -- $SSH_CONNECTION
    [ "$#" -eq 4 ] || {
      rldyour::log "error" "SSH_CONNECTION is malformed; pass --ssh-match-address" >&2
      return 1
    }
    address=${address:-$1}
    local_address=${local_address:-$3}
    if [ -n "$local_port" ] && [ "$local_port" != "$4" ]; then
      rldyour::log "error" "SSH Match local port ${local_port} differs from the live session port $4" >&2
      return 1
    fi
    local_port=${local_port:-$4}
  fi
  if [ -z "$address" ] || [ -z "$local_address" ] || [ -z "$local_port" ]; then
    rldyour::log "error" "SSH Match validation needs client address, local address, and local port; pass explicit values outside an SSH session" >&2
    return 1
  fi
  if ! env -u PYTHONHOME -u PYTHONPATH python3 -I - "$address" "$local_address" 2>/dev/null <<'PY'
import ipaddress
import sys

ipaddress.ip_address(sys.argv[1])
ipaddress.ip_address(sys.argv[2])
PY
  then
    rldyour::log "error" "SSH Match addresses must be literal IPv4 or IPv6 addresses" >&2
    return 1
  fi
  rldyour::ubuntu_server::validate_port "$local_port" >&2 || return 1
  use_dns=$(rldyour::ubuntu_server::probe_as_root sshd -T 2>/dev/null |
    awk '$1 == "usedns" { print $2; exit }') || {
      rldyour::log "error" "cannot read OpenSSH UseDNS policy for Match validation" >&2
      return 1
    }
  case "$use_dns" in
    no) host=$address ;;
    yes)
      if [ -z "$host" ]; then
        rldyour::log "error" "OpenSSH UseDNS=yes requires explicit --ssh-match-host after forward-confirmed reverse DNS review" >&2
        return 1
      fi
      ;;
    *)
      rldyour::log "error" "OpenSSH returned an unknown UseDNS policy" >&2
      return 1
      ;;
  esac
  case "$host" in
    *','* | *'='*)
      rldyour::log "error" "SSH Match host contains an invalid delimiter" >&2
      return 1
      ;;
  esac
  printf 'user=%s,host=%s,addr=%s,laddr=%s,lport=%s\n' \
    "$user" "$host" "$address" "$local_address" "$local_port"
}

rldyour::ubuntu_server::ssh_effective_is_hardened() {
  local effective=$1

  grep -Fqx 'permitrootlogin no' <<<"$effective" &&
    grep -Fqx 'pubkeyauthentication yes' <<<"$effective" &&
    grep -Fqx 'passwordauthentication no' <<<"$effective" &&
    grep -Fqx 'kbdinteractiveauthentication no' <<<"$effective" &&
    grep -Fqx 'authenticationmethods publickey' <<<"$effective" &&
    grep -Fqx 'strictmodes yes' <<<"$effective" &&
    grep -Eq '^authorizedkeysfile ([^ ]*\.ssh/authorized_keys)( |$)' <<<"$effective" &&
    rldyour::ubuntu_server::ssh_effective_accepts_validated_key "$effective"
}

rldyour::ubuntu_server::harden_ssh() (
  set -euo pipefail
  local user=$1
  local port=${2:-}
  local destination=/etc/ssh/sshd_config.d/00-rldyour-server.conf
  local candidate previous effective root_effective context root_context had_previous=0

  rldyour::section "OpenSSH key-only hardening (explicit opt-in)"
  rldyour::ubuntu_server::validate_authorized_keys "$user"
  context=$(rldyour::ubuntu_server::ssh_match_context "$user" "$port") || return 1
  root_context=$(rldyour::ubuntu_server::ssh_match_context root "$port") || return 1
  candidate=$(mktemp)
  previous=$(mktemp)
  trap 'rm -f -- "$candidate" "$previous" 2>/dev/null || rldyour::ubuntu_server::as_root rm -f -- "$candidate" "$previous"' EXIT
  cat >"$candidate" <<'EOF'
# Managed by macos-ubuntu-bootstrap.
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
EOF

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::ubuntu_server::install_managed_file "$candidate" "$destination" 0644
    rldyour::log "info" "[DRY-RUN] validate with sshd -t, then preserve the active SSH provider"
    return 0
  fi

  if [ -e "$destination" ]; then
    had_previous=1
    rldyour::ubuntu_server::as_root cp -a -- "$destination" "$previous"
  fi
  rldyour::ubuntu_server::install_managed_file "$candidate" "$destination" 0644
  if ! rldyour::ubuntu_server::as_root sshd -t; then
    rldyour::log "error" "OpenSSH rejected the managed drop-in; restoring the previous state"
    rldyour::ubuntu_server::restore_managed_file "$previous" "$destination" "$had_previous"
    return 1
  fi
  if ! effective=$(rldyour::ubuntu_server::as_root sshd -T -C "$context") ||
    ! rldyour::ubuntu_server::ssh_effective_is_hardened "$effective"; then
    rldyour::log "error" "OpenSSH did not apply every target-user hardening setting; restoring the previous state"
    rldyour::ubuntu_server::restore_managed_file "$previous" "$destination" "$had_previous"
    return 1
  fi
  if ! root_effective=$(rldyour::ubuntu_server::as_root sshd -T -C "$root_context") ||
    ! grep -Fqx 'permitrootlogin no' <<<"$root_effective"; then
    rldyour::log "error" "OpenSSH Match rules leave root login enabled; restoring the previous state"
    rldyour::ubuntu_server::restore_managed_file "$previous" "$destination" "$had_previous"
    return 1
  fi
  if ! rldyour::ubuntu_server::reload_ssh_authentication; then
    rldyour::log "error" "OpenSSH reload failed; restoring the previous state"
    rldyour::ubuntu_server::restore_managed_file "$previous" "$destination" "$had_previous"
    rldyour::ubuntu_server::as_root sshd -t
    rldyour::ubuntu_server::reload_ssh_authentication || true
    return 1
  fi
  rldyour::log "warn" "verify a second key-authenticated SSH connection before closing this session"
)

rldyour::ubuntu_server::reload_ssh_authentication() {
  if systemctl is-active --quiet ssh.service; then
    rldyour::ubuntu_server::as_root systemctl reload ssh.service
    return
  fi
  if systemctl is-active --quiet ssh.socket; then
    # The managed drop-in changes only sshd authentication policy, not the
    # socket listener. Future socket-activated sshd processes read it directly;
    # restarting the socket would needlessly risk the current remote session.
    rldyour::log "ok" "ssh.socket is active; authentication policy applies to future sshd processes without a socket restart"
    return 0
  fi
  rldyour::log "error" "no active OpenSSH provider is available for the hardening handoff"
  return 1
}

rldyour::ubuntu_server::configure_fail2ban() (
  set -euo pipefail
  local port=$1
  local destination=/etc/fail2ban/jail.d/60-rldyour-sshd.local
  local candidate previous had_previous=0
  local was_installed=0 was_active=0 was_enabled=0 rollback_failed=0

  rldyour::section "Fail2ban sshd jail (explicit opt-in)"
  if [ "$RLDYOUR_DRY_RUN" -eq 0 ]; then
    rldyour::ubuntu_server::package_installed fail2ban && was_installed=1
    systemctl is-active --quiet fail2ban.service && was_active=1
    systemctl is-enabled --quiet fail2ban.service 2>/dev/null && was_enabled=1
  fi
  rldyour::ubuntu_server::apt_install fail2ban
  candidate=$(mktemp)
  previous=$(mktemp)
  trap 'rm -f -- "$candidate" "$previous" 2>/dev/null || rldyour::ubuntu_server::as_root rm -f -- "$candidate" "$previous"' EXIT
  cat >"$candidate" <<EOF
# Managed by macos-ubuntu-bootstrap.
[sshd]
enabled = true
backend = systemd
port = $port
EOF

  if [ "$RLDYOUR_DRY_RUN" -eq 1 ]; then
    rldyour::ubuntu_server::install_managed_file "$candidate" "$destination" 0644
    rldyour::log "info" "[DRY-RUN] fail2ban-client -t before restarting fail2ban.service"
    return 0
  fi

  if [ -e "$destination" ]; then
    had_previous=1
    rldyour::ubuntu_server::as_root cp -a -- "$destination" "$previous"
  fi

  rollback_fail2ban() {
    rollback_failed=0
    rldyour::ubuntu_server::restore_managed_file "$previous" "$destination" "$had_previous" || rollback_failed=1
    if [ "$was_installed" -eq 1 ] &&
      ! rldyour::ubuntu_server::as_root fail2ban-client -t; then
      rollback_failed=1
    fi
    if [ "$was_enabled" -eq 1 ]; then
      rldyour::ubuntu_server::as_root systemctl enable fail2ban.service || rollback_failed=1
    else
      rldyour::ubuntu_server::as_root systemctl disable fail2ban.service || rollback_failed=1
    fi
    if [ "$was_active" -eq 1 ]; then
      rldyour::ubuntu_server::as_root systemctl restart fail2ban.service || rollback_failed=1
    else
      rldyour::ubuntu_server::as_root systemctl stop fail2ban.service || rollback_failed=1
    fi
    if [ "$rollback_failed" -ne 0 ]; then
      rldyour::log "error" "Fail2ban rollback was incomplete; repair the service before ending the current SSH session"
      return 1
    fi
  }

  rldyour::ubuntu_server::install_managed_file "$candidate" "$destination" 0644
  if ! rldyour::ubuntu_server::as_root fail2ban-client -t; then
    rldyour::log "error" "Fail2ban rejected the managed jail; restoring the previous state"
    rollback_fail2ban || true
    return 1
  fi
  if ! rldyour::ubuntu_server::as_root systemctl enable --now fail2ban.service ||
    ! rldyour::ubuntu_server::as_root systemctl restart fail2ban.service ||
    ! systemctl is-active --quiet fail2ban.service ||
    ! rldyour::ubuntu_server::as_root fail2ban-client status sshd >/dev/null; then
    rldyour::log "error" "Fail2ban failed to activate the managed sshd jail; restoring the previous state"
    rollback_fail2ban || true
    return 1
  fi
  rldyour::log "ok" "Fail2ban sshd jail is active"
)

rldyour::ubuntu_server::run_verify() {
  local script_dir docker_mode port ssh_user
  local enable_ufw harden_ssh enable_fail2ban allow_cidr
  local -a args

  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  docker_mode=$1
  port=$2
  ssh_user=$3
  enable_ufw=$4
  harden_ssh=$5
  enable_fail2ban=$6
  allow_cidr=${7:-}
  args=(--docker-mode "$docker_mode")
  if [ -n "$port" ]; then
    args+=(--ssh-port "$port")
  fi
  if [ -n "$ssh_user" ]; then
    args+=(--ssh-user "$ssh_user")
  fi
  [ "$enable_ufw" -eq 1 ] && args+=(--expect-ufw)
  [ -z "$allow_cidr" ] || args+=(--ssh-allow-cidr "$allow_cidr")
  [ "$harden_ssh" -eq 1 ] && args+=(--expect-ssh-hardening)
  [ "$enable_fail2ban" -eq 1 ] && args+=(--expect-fail2ban)
  bash "$script_dir/verify-server.sh" "${args[@]}"
}

rldyour::ubuntu_server::main() (
  set -euo pipefail
  local docker_mode enable_ufw harden_ssh enable_fail2ban ufw_console_confirmed
  local ssh_port ssh_allow_cidr ssh_user ssh_match_address ssh_match_host ssh_local_address
  local skip_verify resolved_port="" resolved_user=

  RLDYOUR_DRY_RUN=${RLDYOUR_DRY_RUN:-1}
  docker_mode=${RLDYOUR_SERVER_DOCKER_MODE:-none}
  enable_ufw=${RLDYOUR_SERVER_ENABLE_UFW:-0}
  harden_ssh=${RLDYOUR_SERVER_HARDEN_SSH:-0}
  enable_fail2ban=${RLDYOUR_SERVER_ENABLE_FAIL2BAN:-0}
  ufw_console_confirmed=${RLDYOUR_SERVER_UFW_CONSOLE_CONFIRMED:-0}
  ssh_port=${RLDYOUR_SERVER_SSH_PORT:-}
  ssh_allow_cidr=${RLDYOUR_SERVER_SSH_ALLOW_CIDR:-}
  ssh_user=${RLDYOUR_SERVER_SSH_USER:-}
  ssh_match_address=${RLDYOUR_SERVER_SSH_MATCH_ADDRESS:-}
  ssh_match_host=${RLDYOUR_SERVER_SSH_MATCH_HOST:-}
  ssh_local_address=${RLDYOUR_SERVER_SSH_LOCAL_ADDRESS:-}
  skip_verify=${RLDYOUR_SERVER_SKIP_VERIFY:-0}

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan)
        RLDYOUR_DRY_RUN=1
        shift
        ;;
      --apply)
        RLDYOUR_DRY_RUN=0
        shift
        ;;
      --docker-mode)
        docker_mode=${2:?--docker-mode requires none|rootful|rootless}
        shift 2
        ;;
      --enable-ufw)
        enable_ufw=1
        shift
        ;;
      --ufw-console-confirmed)
        ufw_console_confirmed=1
        shift
        ;;
      --harden-ssh)
        harden_ssh=1
        shift
        ;;
      --enable-fail2ban)
        enable_fail2ban=1
        shift
        ;;
      --ssh-port)
        ssh_port=${2:?--ssh-port requires a port}
        shift 2
        ;;
      --ssh-allow-cidr)
        ssh_allow_cidr=${2:?--ssh-allow-cidr requires a CIDR}
        shift 2
        ;;
      --ssh-user)
        ssh_user=${2:?--ssh-user requires a user}
        shift 2
        ;;
      --ssh-match-address)
        ssh_match_address=${2:?--ssh-match-address requires an address}
        shift 2
        ;;
      --ssh-match-host)
        ssh_match_host=${2:?--ssh-match-host requires a hostname}
        shift 2
        ;;
      --ssh-local-address)
        ssh_local_address=${2:?--ssh-local-address requires an address}
        shift 2
        ;;
      --skip-verify)
        skip_verify=1
        shift
        ;;
      --help)
        rldyour::ubuntu_server::usage
        return 0
        ;;
      *)
        rldyour::log "error" "unknown option: $1"
        rldyour::ubuntu_server::usage >&2
        return 2
        ;;
    esac
  done

  rldyour::ubuntu_server::validate_bool RLDYOUR_DRY_RUN "$RLDYOUR_DRY_RUN"
  rldyour::ubuntu_server::validate_bool RLDYOUR_SERVER_ENABLE_UFW "$enable_ufw"
  rldyour::ubuntu_server::validate_bool RLDYOUR_SERVER_HARDEN_SSH "$harden_ssh"
  rldyour::ubuntu_server::validate_bool RLDYOUR_SERVER_ENABLE_FAIL2BAN "$enable_fail2ban"
  rldyour::ubuntu_server::validate_bool RLDYOUR_SERVER_UFW_CONSOLE_CONFIRMED "$ufw_console_confirmed"
  rldyour::ubuntu_server::validate_bool RLDYOUR_SERVER_SKIP_VERIFY "$skip_verify"
  rldyour::ubuntu_server::validate_docker_mode "$docker_mode"
  if [ -n "$ssh_allow_cidr" ]; then
    if ! ssh_allow_cidr=$(rldyour::ubuntu_server::canonicalize_cidr "$ssh_allow_cidr"); then
      rldyour::log "error" "--ssh-allow-cidr must be a valid IPv4 or IPv6 CIDR"
      return 2
    fi
    if [ "$enable_ufw" -ne 1 ]; then
      rldyour::log "error" "--ssh-allow-cidr requires --enable-ufw"
      return 2
    fi
  fi
  if [ "$ufw_console_confirmed" -eq 1 ] && [ "$enable_ufw" -ne 1 ]; then
    rldyour::log "error" "--ufw-console-confirmed requires --enable-ufw"
    return 2
  fi
  if [ -n "$ssh_match_address" ]; then
    export RLDYOUR_SERVER_SSH_MATCH_ADDRESS=$ssh_match_address
  fi
  if [ -n "$ssh_match_host" ]; then
    export RLDYOUR_SERVER_SSH_MATCH_HOST=$ssh_match_host
  fi
  if [ -n "$ssh_local_address" ]; then
    export RLDYOUR_SERVER_SSH_LOCAL_ADDRESS=$ssh_local_address
  fi
  export RLDYOUR_SERVER_UFW_CONSOLE_CONFIRMED=$ufw_console_confirmed
  rldyour::ubuntu_server::validate_os
  rldyour::ubuntu_server::require_apply_privilege
  if [ "$enable_ufw" -eq 1 ] || [ "$harden_ssh" -eq 1 ] ||
    [ "$enable_fail2ban" -eq 1 ] || [ -n "$ssh_port" ]; then
    resolved_port=$(rldyour::ubuntu_server::detect_ssh_port "$ssh_port")
  fi
  if [ "$harden_ssh" -eq 1 ]; then
    resolved_user=$(rldyour::ubuntu_server::resolve_ssh_user "$ssh_user")
  fi

  rldyour::section "Ubuntu server module"
  rldyour::log "info" "mode: $([ "$RLDYOUR_DRY_RUN" -eq 1 ] && echo plan || echo apply)"
  rldyour::log "info" "docker: $docker_mode; ufw: $enable_ufw; ssh hardening: $harden_ssh; fail2ban: $enable_fail2ban"
  if [ -n "$resolved_port" ]; then
    rldyour::log "info" "SSH port: $resolved_port${ssh_allow_cidr:+; allow CIDR: $ssh_allow_cidr}"
  fi

  rldyour::ubuntu_server::install_baseline
  rldyour::ubuntu_server::ensure_time_sync
  case "$docker_mode" in
    none) rldyour::log "info" "Docker mode none: no Docker state is managed" ;;
    rootful) rldyour::ubuntu_server::install_docker_rootful ;;
    rootless) rldyour::ubuntu_server::install_docker_rootless ;;
  esac
  [ "$harden_ssh" -eq 1 ] && rldyour::ubuntu_server::harden_ssh "$resolved_user" "$resolved_port"
  [ "$enable_ufw" -eq 1 ] && rldyour::ubuntu_server::configure_ufw "$resolved_port" "$ssh_allow_cidr"
  [ "$enable_fail2ban" -eq 1 ] && rldyour::ubuntu_server::configure_fail2ban "$resolved_port"

  if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && [ "$skip_verify" -eq 0 ]; then
    rldyour::ubuntu_server::run_verify "$docker_mode" "$resolved_port" "$resolved_user" "$enable_ufw" "$harden_ssh" "$enable_fail2ban" "$ssh_allow_cidr"
  fi
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rldyour::ubuntu_server::main "$@"
fi
