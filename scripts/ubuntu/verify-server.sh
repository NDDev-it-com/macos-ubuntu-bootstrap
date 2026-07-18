#!/usr/bin/env bash

# Read-only verification companion for scripts/ubuntu/server.sh.

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/server.sh"

rldyour::ubuntu_server_verify::usage() {
  cat <<'EOF'
Usage: scripts/ubuntu/verify-server.sh [options]

  --docker-mode MODE             none|rootful|rootless (default: none)
  --expect-ufw                   Require UFW to be active with the SSH port allowed
  --expect-ssh-hardening         Require root/password SSH login to be disabled
  --expect-fail2ban              Require an active Fail2ban sshd jail
  --ssh-port PORT                SSH port; otherwise detect with sshd -T
  --ssh-user USER                User whose authorized_keys should remain valid
  --ssh-allow-cidr CIDR          Expected UFW source restriction for SSH
  --help                         Show this help

Environment equivalents use the same RLDYOUR_SERVER_* keys as server.sh.
The verifier is read-only and never pulls images or changes service state.
EOF
}

rldyour::ubuntu_server_verify::pass() {
  rldyour::log "ok" "$*"
}

rldyour::ubuntu_server_verify::fail() {
  RLDYOUR_SERVER_VERIFY_FAILURES=$((RLDYOUR_SERVER_VERIFY_FAILURES + 1))
  rldyour::log "fail" "$*"
}

rldyour::ubuntu_server_verify::check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    rldyour::ubuntu_server_verify::pass "$description"
  else
    rldyour::ubuntu_server_verify::fail "$description"
  fi
}

rldyour::ubuntu_server_verify::as_root() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 1
  fi
}

rldyour::ubuntu_server_verify::package() {
  local package=$1
  if rldyour::ubuntu_server::package_installed "$package"; then
    rldyour::ubuntu_server_verify::pass "package installed: $package"
  else
    rldyour::ubuntu_server_verify::fail "package missing: $package"
  fi
}

rldyour::ubuntu_server_verify::service_or_socket_active() {
  systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket
}

rldyour::ubuntu_server_verify::time_provider_active() {
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] ||
    systemctl is-active --quiet chrony.service ||
    systemctl is-active --quiet systemd-timesyncd.service ||
    systemctl list-units --type=service --state=active --no-legend 2>/dev/null |
      awk 'tolower($1) ~ /(chron|ntp|timesync|ptp4l|phc2sys)/ { found=1 } END { exit(found ? 0 : 1) }'
}

rldyour::ubuntu_server_verify::time_synchronized() {
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]
}

rldyour::ubuntu_server_verify::unattended_upgrades_enabled() {
  local effective

  effective=$(apt-config dump 2>/dev/null) || return 1
  grep -Fqx 'APT::Periodic::Update-Package-Lists "1";' <<<"$effective" &&
    grep -Fqx 'APT::Periodic::Unattended-Upgrade "1";' <<<"$effective"
}

rldyour::ubuntu_server_verify::base() {
  rldyour::section "Verify Ubuntu server baseline"
  if rldyour::ubuntu_server::validate_os; then
    rldyour::ubuntu_server_verify::pass "supported Ubuntu release"
  else
    rldyour::ubuntu_server_verify::fail "supported Ubuntu release"
  fi

  rldyour::ubuntu_server_verify::package ca-certificates
  rldyour::ubuntu_server_verify::package curl
  rldyour::ubuntu_server_verify::package gnupg
  rldyour::ubuntu_server_verify::package openssh-server
  rldyour::ubuntu_server_verify::package unattended-upgrades
  rldyour::ubuntu_server_verify::check "unattended security updates enabled" rldyour::ubuntu_server_verify::unattended_upgrades_enabled
  rldyour::ubuntu_server_verify::check "apt-daily.timer enabled" systemctl is-enabled --quiet apt-daily.timer
  rldyour::ubuntu_server_verify::check "apt-daily-upgrade.timer enabled" systemctl is-enabled --quiet apt-daily-upgrade.timer
  rldyour::ubuntu_server_verify::check "OpenSSH service or socket active" rldyour::ubuntu_server_verify::service_or_socket_active
  rldyour::ubuntu_server_verify::check "OpenSSH configuration valid" rldyour::ubuntu_server_verify::as_root sshd -t
  rldyour::ubuntu_server_verify::check "time synchronization provider active" rldyour::ubuntu_server_verify::time_provider_active
  rldyour::ubuntu_server_verify::check "system clock synchronized" rldyour::ubuntu_server_verify::time_synchronized
}

rldyour::ubuntu_server_verify::docker_packages() {
  local package
  for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    rldyour::ubuntu_server_verify::package "$package"
  done
}

rldyour::ubuntu_server_verify::docker_cli_plugins() {
  rldyour::ubuntu_server_verify::check "Docker CLI available" command -v docker
  rldyour::ubuntu_server_verify::check "Docker Buildx plugin available" docker buildx version
  rldyour::ubuntu_server_verify::check "Docker Compose plugin available" docker compose version
}

rldyour::ubuntu_server_verify::docker_owned_marker_valid() (
  local destination=$1
  local kind=$2
  local expected

  expected=$(mktemp)
  trap 'rm -f -- "$expected"' EXIT
  rldyour::ubuntu_server::docker_repo_owner_marker "$kind" >"$expected"
  [ ! -L "${destination}.rldyour-owner" ] &&
    [ -f "${destination}.rldyour-owner" ] &&
    rldyour::ubuntu_server::root_file_equals "$expected" "${destination}.rldyour-owner"
)

rldyour::ubuntu_server_verify::docker_repo_source_current() (
  local source_path=/etc/apt/sources.list.d/rldyour-docker.sources
  local key_path=/etc/apt/keyrings/rldyour-docker.asc
  local expected

  [ -n "${RLDYOUR_SERVER_OS_CODENAME:-}" ] || return 1
  [ -n "${RLDYOUR_SERVER_ARCH:-}" ] || return 1
  expected=$(mktemp)
  trap 'rm -f -- "$expected"' EXIT
  cat >"$expected" <<EOF
# Managed by macos-ubuntu-bootstrap; exact ownership is recorded in a sidecar.
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $RLDYOUR_SERVER_OS_CODENAME
Components: stable
Architectures: $RLDYOUR_SERVER_ARCH
Signed-By: $key_path
EOF
  [ ! -L "$source_path" ] && [ -f "$source_path" ] &&
    rldyour::ubuntu_server::root_file_equals "$expected" "$source_path"
)

rldyour::ubuntu_server_verify::docker_repo_key_trusted() {
  local key_path=/etc/apt/keyrings/rldyour-docker.asc
  local expected_fingerprint=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
  local primary_fingerprint

  [ ! -L "$key_path" ] && [ -f "$key_path" ] || return 1
  primary_fingerprint=$(gpg --batch --show-keys --with-colons "$key_path" 2>/dev/null |
    awk -F: '
      $1 == "pub" { primary_count++; awaiting_primary_fpr=1; next }
      $1 == "fpr" && awaiting_primary_fpr { primary_fpr=toupper($10); awaiting_primary_fpr=0 }
      END {
        if (primary_count != 1 || primary_fpr == "") exit 1
        print primary_fpr
      }
    ') || return 1
  [ "$primary_fingerprint" = "$expected_fingerprint" ]
}

rldyour::ubuntu_server_verify::root_owned_0644() {
  [ "$(stat -c '%U:%G:%a' "$1" 2>/dev/null)" = root:root:644 ]
}

rldyour::ubuntu_server_verify::docker_repository_if_managed() {
  local key_path=/etc/apt/keyrings/rldyour-docker.asc
  local source_path=/etc/apt/sources.list.d/rldyour-docker.sources

  if [ ! -e "$key_path" ] && [ ! -e "${key_path}.rldyour-owner" ] &&
    [ ! -e "$source_path" ] && [ ! -e "${source_path}.rldyour-owner" ]; then
    rldyour::log "warn" "namespaced Docker apt repository is absent; packages may be externally managed"
    return 0
  fi
  rldyour::ubuntu_server_verify::check "Docker apt key has an exact ownership marker" rldyour::ubuntu_server_verify::docker_owned_marker_valid "$key_path" key
  rldyour::ubuntu_server_verify::check "Docker apt source has an exact ownership marker" rldyour::ubuntu_server_verify::docker_owned_marker_valid "$source_path" source
  rldyour::ubuntu_server_verify::check "Docker apt source matches this Ubuntu release and architecture" rldyour::ubuntu_server_verify::docker_repo_source_current
  rldyour::ubuntu_server_verify::check "Docker apt key matches the fixed trust fingerprint" rldyour::ubuntu_server_verify::docker_repo_key_trusted
  rldyour::ubuntu_server_verify::check "Docker apt key metadata is root:root 0644" rldyour::ubuntu_server_verify::root_owned_0644 "$key_path"
  rldyour::ubuntu_server_verify::check "Docker apt source metadata is root:root 0644" rldyour::ubuntu_server_verify::root_owned_0644 "$source_path"
  rldyour::ubuntu_server_verify::check "Docker apt key marker metadata is root:root 0644" rldyour::ubuntu_server_verify::root_owned_0644 "${key_path}.rldyour-owner"
  rldyour::ubuntu_server_verify::check "Docker apt source marker metadata is root:root 0644" rldyour::ubuntu_server_verify::root_owned_0644 "${source_path}.rldyour-owner"
}

rldyour::ubuntu_server_verify::no_tcp_daemon_socket() {
  command -v ss >/dev/null 2>&1 || return 1
  ! ss -lnt 2>/dev/null | awk '{ print $4 }' | grep -Eq '(^|:)(2375|2376)$'
}

rldyour::ubuntu_server_verify::docker_rootful() {
  rldyour::section "Verify rootful Docker"
  rldyour::ubuntu_server_verify::docker_packages
  rldyour::ubuntu_server_verify::docker_repository_if_managed
  rldyour::ubuntu_server_verify::docker_cli_plugins
  rldyour::ubuntu_server_verify::check "docker.service active" systemctl is-active --quiet docker.service
  rldyour::ubuntu_server_verify::check "containerd.service active" systemctl is-active --quiet containerd.service
  rldyour::ubuntu_server_verify::check "Docker daemon responds" rldyour::ubuntu_server_verify::as_root docker info
  rldyour::ubuntu_server_verify::check "Docker daemon is not listening on TCP 2375/2376" rldyour::ubuntu_server_verify::no_tcp_daemon_socket
}

rldyour::ubuntu_server_verify::rootless_security_option() {
  docker --context rootless info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q 'rootless'
}

rldyour::ubuntu_server_verify::rootless_context_uses_user_socket() {
  [ "$(docker context inspect rootless --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" = "unix:///run/user/${UID}/docker.sock" ]
}

rldyour::ubuntu_server_verify::docker_rootless() {
  rldyour::section "Verify rootless Docker"
  rldyour::ubuntu_server_verify::docker_packages
  rldyour::ubuntu_server_verify::package docker-ce-rootless-extras
  rldyour::ubuntu_server_verify::package uidmap
  rldyour::ubuntu_server_verify::package dbus-user-session
  rldyour::ubuntu_server_verify::package slirp4netns
  rldyour::ubuntu_server_verify::docker_repository_if_managed
  rldyour::ubuntu_server_verify::docker_cli_plugins
  if [ "$EUID" -eq 0 ]; then
    rldyour::ubuntu_server_verify::fail "rootless verification must run as the target non-root user"
    return
  fi
  rldyour::ubuntu_server_verify::check "Docker rootless context exists" docker context inspect rootless
  rldyour::ubuntu_server_verify::check "Docker rootless context uses the target user's socket" rldyour::ubuntu_server_verify::rootless_context_uses_user_socket
  rldyour::ubuntu_server_verify::check "rootless user docker.service active" systemctl --user is-active --quiet docker.service
  rldyour::ubuntu_server_verify::check "Docker reports the rootless security option" rldyour::ubuntu_server_verify::rootless_security_option
  if rldyour::ubuntu_server::docker_rootful_runtime_active; then
    rldyour::log "warn" "rootful Docker/containerd runtime is also active; verifier preserves coexistence and never migrates it"
  else
    rldyour::ubuntu_server_verify::pass "no active rootful Docker/containerd runtime"
  fi
  rldyour::ubuntu_server_verify::check "Docker daemon is not listening on TCP 2375/2376" rldyour::ubuntu_server_verify::no_tcp_daemon_socket
}

rldyour::ubuntu_server_verify::ufw() {
  local port=$1
  local allow_cidr=${2:-}
  local status

  rldyour::section "Verify UFW"
  if ! status=$(rldyour::ubuntu_server_verify::as_root env LC_ALL=C ufw status 2>/dev/null); then
    rldyour::ubuntu_server_verify::fail "UFW status readable"
    return
  fi
  if grep -q '^Status: active' <<<"$status"; then
    rldyour::ubuntu_server_verify::pass "UFW active"
  else
    rldyour::ubuntu_server_verify::fail "UFW active"
  fi
  if rldyour::ubuntu_server::ufw_status_has_ssh_rule "$status" "$port" "$allow_cidr"; then
    rldyour::ubuntu_server_verify::pass "UFW includes an SSH port $port rule"
  else
    rldyour::ubuntu_server_verify::fail "UFW includes an SSH port $port rule"
  fi
  rldyour::log "warn" "UFW status does not prove Docker-published ports are filtered; test exposure externally"
}

rldyour::ubuntu_server_verify::ssh_hardening() {
  local user=$1
  local port=${2:-}
  local effective root_effective context root_context

  rldyour::section "Verify OpenSSH hardening"
  if [ -z "$user" ]; then
    rldyour::ubuntu_server_verify::fail "target SSH user resolved"
    return
  fi
  if ! context=$(rldyour::ubuntu_server::ssh_match_context "$user" "$port") ||
    ! root_context=$(rldyour::ubuntu_server::ssh_match_context root "$port"); then
    rldyour::ubuntu_server_verify::fail "SSH Match validation context resolved"
    return
  fi
  if ! effective=$(rldyour::ubuntu_server_verify::as_root sshd -T -C "$context" 2>/dev/null); then
    rldyour::ubuntu_server_verify::fail "effective OpenSSH configuration readable"
    return
  fi
  if grep -q '^permitrootlogin no$' <<<"$effective"; then
    rldyour::ubuntu_server_verify::pass "SSH root login disabled"
  else
    rldyour::ubuntu_server_verify::fail "SSH root login disabled"
  fi
  if grep -q '^pubkeyauthentication yes$' <<<"$effective"; then
    rldyour::ubuntu_server_verify::pass "SSH public-key authentication enabled"
  else
    rldyour::ubuntu_server_verify::fail "SSH public-key authentication enabled"
  fi
  if grep -q '^passwordauthentication no$' <<<"$effective"; then
    rldyour::ubuntu_server_verify::pass "SSH password authentication disabled"
  else
    rldyour::ubuntu_server_verify::fail "SSH password authentication disabled"
  fi
  if grep -q '^kbdinteractiveauthentication no$' <<<"$effective"; then
    rldyour::ubuntu_server_verify::pass "SSH keyboard-interactive authentication disabled"
  else
    rldyour::ubuntu_server_verify::fail "SSH keyboard-interactive authentication disabled"
  fi
  if grep -q '^authenticationmethods publickey$' <<<"$effective"; then
    rldyour::ubuntu_server_verify::pass "SSH authentication requires a public key"
  else
    rldyour::ubuntu_server_verify::fail "SSH authentication requires a public key"
  fi
  if rldyour::ubuntu_server::validate_authorized_keys "$user"; then
    rldyour::ubuntu_server_verify::pass "parseable StrictModes-safe authorized key remains available for $user"
    if rldyour::ubuntu_server::ssh_effective_accepts_validated_key "$effective"; then
      rldyour::ubuntu_server_verify::pass "effective SSH policy accepts at least one authorized key family"
    else
      rldyour::ubuntu_server_verify::fail "effective SSH policy accepts at least one authorized key family"
    fi
  else
    rldyour::ubuntu_server_verify::fail "parseable StrictModes-safe authorized key remains available for $user"
  fi
  if root_effective=$(rldyour::ubuntu_server_verify::as_root sshd -T -C "$root_context" 2>/dev/null) &&
    grep -q '^permitrootlogin no$' <<<"$root_effective"; then
    rldyour::ubuntu_server_verify::pass "SSH root login disabled under Match evaluation"
  else
    rldyour::ubuntu_server_verify::fail "SSH root login disabled under Match evaluation"
  fi
}

rldyour::ubuntu_server_verify::fail2ban() {
  rldyour::section "Verify Fail2ban"
  rldyour::ubuntu_server_verify::package fail2ban
  rldyour::ubuntu_server_verify::check "Fail2ban configuration valid" rldyour::ubuntu_server_verify::as_root fail2ban-client -t
  rldyour::ubuntu_server_verify::check "fail2ban.service active" systemctl is-active --quiet fail2ban.service
  rldyour::ubuntu_server_verify::check "Fail2ban sshd jail active" rldyour::ubuntu_server_verify::as_root fail2ban-client status sshd
}

rldyour::ubuntu_server_verify::main() (
  set -euo pipefail
  local docker_mode expect_ufw expect_ssh_hardening expect_fail2ban
  local ssh_port ssh_user ssh_allow_cidr resolved_port

  export RLDYOUR_DRY_RUN=0
  RLDYOUR_SERVER_VERIFY_FAILURES=0
  docker_mode=${RLDYOUR_SERVER_DOCKER_MODE:-none}
  expect_ufw=${RLDYOUR_SERVER_ENABLE_UFW:-0}
  expect_ssh_hardening=${RLDYOUR_SERVER_HARDEN_SSH:-0}
  expect_fail2ban=${RLDYOUR_SERVER_ENABLE_FAIL2BAN:-0}
  ssh_port=${RLDYOUR_SERVER_SSH_PORT:-}
  ssh_user=${RLDYOUR_SERVER_SSH_USER:-}
  ssh_allow_cidr=${RLDYOUR_SERVER_SSH_ALLOW_CIDR:-}

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --docker-mode)
        docker_mode=${2:?--docker-mode requires none|rootful|rootless}
        shift 2
        ;;
      --expect-ufw)
        expect_ufw=1
        shift
        ;;
      --expect-ssh-hardening)
        expect_ssh_hardening=1
        shift
        ;;
      --expect-fail2ban)
        expect_fail2ban=1
        shift
        ;;
      --ssh-port)
        ssh_port=${2:?--ssh-port requires a port}
        shift 2
        ;;
      --ssh-user)
        ssh_user=${2:?--ssh-user requires a user}
        shift 2
        ;;
      --ssh-allow-cidr)
        ssh_allow_cidr=${2:?--ssh-allow-cidr requires a CIDR}
        shift 2
        ;;
      --help)
        rldyour::ubuntu_server_verify::usage
        return 0
        ;;
      *)
        rldyour::log "error" "unknown option: $1"
        rldyour::ubuntu_server_verify::usage >&2
        return 2
        ;;
    esac
  done

  rldyour::ubuntu_server::validate_bool RLDYOUR_SERVER_ENABLE_UFW "$expect_ufw"
  rldyour::ubuntu_server::validate_bool RLDYOUR_SERVER_HARDEN_SSH "$expect_ssh_hardening"
  rldyour::ubuntu_server::validate_bool RLDYOUR_SERVER_ENABLE_FAIL2BAN "$expect_fail2ban"
  rldyour::ubuntu_server::validate_docker_mode "$docker_mode"
  if [ "$expect_ssh_hardening" -eq 1 ] && [ -z "$ssh_user" ]; then
    ssh_user=$(rldyour::ubuntu_server::resolve_ssh_user "")
  fi
  resolved_port=""
  if [ "$expect_ufw" -eq 1 ] || [ "$expect_ssh_hardening" -eq 1 ] ||
    [ "$expect_fail2ban" -eq 1 ] || [ -n "$ssh_port" ]; then
    resolved_port=$(rldyour::ubuntu_server::detect_ssh_port "$ssh_port")
  fi

  rldyour::ubuntu_server_verify::base
  case "$docker_mode" in
    none) rldyour::log "info" "Docker mode none: Docker state is outside this verification contract" ;;
    rootful) rldyour::ubuntu_server_verify::docker_rootful ;;
    rootless) rldyour::ubuntu_server_verify::docker_rootless ;;
  esac
  [ "$expect_ufw" -eq 1 ] && rldyour::ubuntu_server_verify::ufw "$resolved_port" "$ssh_allow_cidr"
  [ "$expect_ssh_hardening" -eq 1 ] &&
    rldyour::ubuntu_server_verify::ssh_hardening "$ssh_user" "$resolved_port"
  [ "$expect_fail2ban" -eq 1 ] && rldyour::ubuntu_server_verify::fail2ban

  if [ "$RLDYOUR_SERVER_VERIFY_FAILURES" -gt 0 ]; then
    rldyour::log "error" "Ubuntu server verification failed: $RLDYOUR_SERVER_VERIFY_FAILURES check(s)"
    return 1
  fi
  rldyour::log "ok" "Ubuntu server verification passed"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rldyour::ubuntu_server_verify::main "$@"
fi
