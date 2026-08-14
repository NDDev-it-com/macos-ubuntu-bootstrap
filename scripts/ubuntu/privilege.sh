#!/usr/bin/env bash

# Ubuntu privilege state machine. Source only. Authentication secrets remain
# exclusively inside sudo/polkit; this API never accepts a password channel.

RLDYOUR_PRIVILEGE_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RLDYOUR_PRIVILEGE_REPO_ROOT="$(cd -- "$RLDYOUR_PRIVILEGE_SOURCE_DIR/../.." && pwd)"
readonly RLDYOUR_PRIVILEGE_SOURCE_DIR RLDYOUR_PRIVILEGE_REPO_ROOT
readonly RLDYOUR_PRIVILEGE_SOURCE_HELPER="$RLDYOUR_PRIVILEGE_SOURCE_DIR/privileged-helper.sh"
readonly RLDYOUR_PRIVILEGE_SOURCE_CONTRACT="$RLDYOUR_PRIVILEGE_REPO_ROOT/config/rldyour-contract.json"
readonly RLDYOUR_PRIVILEGE_SOURCE_POLICY="$RLDYOUR_PRIVILEGE_REPO_ROOT/templates/polkit/com.nddev.rldyour.bootstrap.policy"
readonly RLDYOUR_PRIVILEGE_SOURCE_PUBLISHER="$RLDYOUR_PRIVILEGE_SOURCE_DIR/secure-publish.py"
readonly RLDYOUR_PRIVILEGE_HELPER="/usr/local/libexec/rldyour-bootstrap-privileged"
readonly RLDYOUR_PRIVILEGE_CONTRACT="/usr/local/share/rldyour-bootstrap/rldyour-contract.json"
readonly RLDYOUR_PRIVILEGE_RECEIPT="/usr/local/share/rldyour-bootstrap/privilege-receipt"
readonly RLDYOUR_PRIVILEGE_TRANSACTION="/usr/local/share/rldyour-bootstrap/privilege-transaction"
readonly RLDYOUR_PRIVILEGE_POLICY="/usr/share/polkit-1/actions/com.nddev.rldyour.bootstrap.policy"
readonly RLDYOUR_PRIVILEGE_AUTH_TIMEOUT=300
RLDYOUR_PRIVILEGE_MODE="${RLDYOUR_PRIVILEGE_MODE:-uninitialized}"
RLDYOUR_PRIVILEGE_RESULT="${RLDYOUR_PRIVILEGE_RESULT:-NOT_CHECKED}"
RLDYOUR_PRIVILEGE_PROFILE="${RLDYOUR_PRIVILEGE_PROFILE:-}"
RLDYOUR_PRIVILEGE_GUI="${RLDYOUR_PRIVILEGE_GUI:-}"

rldyour::privilege::result() {
  RLDYOUR_PRIVILEGE_RESULT=$1
  export RLDYOUR_PRIVILEGE_RESULT
  rldyour::log "privilege" "mode=${RLDYOUR_PRIVILEGE_MODE} result=${RLDYOUR_PRIVILEGE_RESULT}"
}

rldyour::privilege::set_mode() {
  RLDYOUR_PRIVILEGE_MODE=$1
  export RLDYOUR_PRIVILEGE_MODE
}

rldyour::privilege::trusted_root_path() {
  local path=$1 component metadata owner mode
  if [ "${path#/}" = "$path" ] || [ ! -e "$path" ] || [ -L "$path" ]; then
    return 1
  fi
  metadata=$(/usr/bin/stat -c '%u %a' -- / 2>/dev/null) || return 1
  [ "${metadata%% *}" = 0 ] || return 1
  mode=$((8#${metadata##* }))
  [ $((mode & 0022)) -eq 0 ] || return 1
  component=$path
  while [ "$component" != / ]; do
    [ ! -L "$component" ] || return 1
    metadata=$(/usr/bin/stat -c '%u %a' -- "$component" 2>/dev/null) || return 1
    owner=${metadata%% *}
    mode=${metadata##* }
    [ "$owner" = 0 ] || return 1
    mode=$((8#$mode))
    [ $((mode & 0022)) -eq 0 ] || return 1
    component=${component%/*}
    [ -n "$component" ] || component=/
  done
}

# Validate a distribution-managed tool, following an alternatives chain.
#
# `trusted_root_path` refuses symlinks outright, which is right for artifacts
# this repository publishes: ours are real files and a symlink there would be
# an indirection nobody asked for. It is wrong for a tool the distribution owns.
#
# Ubuntu 26.04 ships sudo through the alternatives system, because it carries
# both the classic implementation and sudo-rs:
#
#     /usr/bin/sudo -> /etc/alternatives/sudo -> /usr/bin/sudo.ws  (4755 root root)
#
# On 24.04 `/usr/bin/sudo` is that setuid file directly. So the strict check
# refused sudo on 26.04, the sudo-noninteractive branch was skipped, and a
# non-TTY 26.04 host fell through to NONINTERACTIVE_AUTH_UNAVAILABLE -- the
# privilege state machine could not use sudo at all on a release the contract
# claims to support. Every 26.04 sandbox lane failed on exactly that.
#
# The property worth keeping is not "no symlinks"; it is "nobody but root can
# change where this path leads". A symlink owned by root, in a directory only
# root can write, satisfies it: repointing it needs root, and root does not
# need to attack sudo. Symlink *modes* are not consulted because Linux does not
# enforce them -- they are always 0777 -- so ownership and the writability of
# each containing directory are what carry the guarantee.
readonly RLDYOUR_PRIVILEGE_MAX_LINK_DEPTH=8

rldyour::privilege::absolute_tool() {
  local path=$1 depth=0 target parent

  while :; do
    case $path in
      /*) ;;
      *) return 1 ;;
    esac
    [ -e "$path" ] || return 1
    # Every directory above it must be root-owned and closed to others,
    # whatever the leaf turns out to be.
    parent=${path%/*}
    [ -n "$parent" ] || parent=/
    rldyour::privilege::trusted_root_path "$parent" || return 1
    # The leaf itself must be root-owned; a link nobody but root can repoint
    # is as trustworthy as the file it names.
    [ "$(/usr/bin/stat -c '%u' -- "$path" 2>/dev/null)" = 0 ] || return 1

    [ -L "$path" ] || break
    depth=$((depth + 1))
    [ "$depth" -le "$RLDYOUR_PRIVILEGE_MAX_LINK_DEPTH" ] || return 1
    target=$(/usr/bin/readlink -- "$path") || return 1
    case $target in
      /*) path=$target ;;
      *) path=${path%/*}/$target ;;
    esac
  done

  # The resolved file, with the same mode contract the strict check applies.
  if [ ! -f "$path" ] || [ ! -x "$path" ]; then
    return 1
  fi
  local metadata mode
  metadata=$(/usr/bin/stat -c '%u %a' -- "$path" 2>/dev/null) || return 1
  [ "${metadata%% *}" = 0 ] || return 1
  mode=$((8#${metadata##* }))
  [ $((mode & 0022)) -eq 0 ]
}

rldyour::privilege::source_contract_valid() {
  # python-surface: privilege-source-contract
  /usr/bin/python3 -I - "$RLDYOUR_PRIVILEGE_SOURCE_CONTRACT" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
p = data["privilege"]
assert p["schema_version"] == 1
assert p["system_python_minimum"] == "3.12"
assert p["authority_diagnostics"] == {
    "schema": "rldyour.secure-publish-authority/v1",
    "maximum_bytes": 4096,
    "path_disclosure": "class-and-component-index-only",
    "directory_replacement_identity": ["device", "inode", "type"],
    "directory_policy_revalidation": ["uid", "gid", "mode"],
    "directory_operational_metadata": ["nlink", "size", "timestamps"],
}
assert p["publication_authorities"] == {
    "root-production": {
        "owner": "root", "group": "root", "ancestor_writable_mask": "0022",
        "destination_scope": "canonical-absolute-production",
    },
    "actor-sandbox": {
        "owner": "effective-actor", "group": "effective-actor-primary-group", "anchor_mode": "0700",
        "ancestor_writable_mask": "0022",
        "destination_scope": "strictly-beneath-explicit-fd-anchored-root",
        "production_paths": "forbidden",
    },
}
assert {item["id"] for item in p["system_python_surfaces"]} == {
    "privilege-source-contract", "privilege-profile-allowance",
    "publisher-record", "publisher-file", "publisher-directory",
    "helper-trusted-path", "helper-contract-values", "helper-pkexec-parent",
    "verifier-runtime-contract", "verifier-herdr-contract", "verifier-chrome-trust",
    "server-cidr", "server-operator-source",
    "server-ssh-address",
}
assert p["runtime"]["helper"] == "/usr/local/libexec/rldyour-bootstrap-privileged"
assert p["runtime"]["contract"] == "/usr/local/share/rldyour-bootstrap/rldyour-contract.json"
assert p["runtime"]["policy"] == "/usr/share/polkit-1/actions/com.nddev.rldyour.bootstrap.policy"
apps = {item["name"]: item for item in data["ubuntu_apt_packages"]["desktop_apps"]}
fingerprint = apps["google-chrome-stable"]["apt_source"]["key_fingerprint"]
assert re.fullmatch(r"[0-9A-F]{40}", fingerprint)
assert set(p["operations"]) == {"ubuntu-desktop-system", "ubuntu-desktop-gui-system", "ubuntu-server-system"}
assert p["operation_owners"] == {
    "ubuntu-desktop-system": "scripts/ubuntu/privileged-helper.sh",
    "ubuntu-desktop-gui-system": "scripts/ubuntu/privileged-helper.sh",
    "ubuntu-server-system": "scripts/ubuntu/server.sh",
}
assert set(p["profiles"]) == {"desktop:gui-0", "desktop:gui-1", "desktop-builds:gui-0", "desktop-builds:gui-1", "server:gui-0"}
allowed = {"plan", "root", "sudo-noninteractive", "sudo-tty", "policykit"}
for key, entry in p["profiles"].items():
    assert set(entry) == {"operations", "mechanisms"}
    assert set(entry["operations"]) <= set(p["operations"])
    assert set(entry["mechanisms"]) <= allowed
    assert "policykit" not in entry["mechanisms"] or key == "desktop:gui-1"
PY
}

rldyour::privilege::source_contract_allows() {
  local profile=$1 gui=$2 mechanism=$3 operation=${4:-}
  # python-surface: privilege-profile-allowance
  /usr/bin/python3 -I - "$RLDYOUR_PRIVILEGE_SOURCE_CONTRACT" "$profile" "$gui" "$mechanism" "$operation" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))["privilege"]
key = f"{sys.argv[2]}:gui-{sys.argv[3]}"
entry = data["profiles"].get(key)
if not entry or sys.argv[4] not in entry["mechanisms"]:
    raise SystemExit(1)
if sys.argv[5] and sys.argv[5] not in entry["operations"]:
    raise SystemExit(1)
PY
}

rldyour::privilege::root_exec() {
  case "$RLDYOUR_PRIVILEGE_MODE" in
    root) "$@" ;;
    sudo-noninteractive|sudo-tty)
      /usr/bin/sudo -n -- "$@"
      ;;
    *) return 1 ;;
  esac
}

rldyour::privilege::file_sha256() {
  /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
}

rldyour::privilege::receipt_value() {
  local file=$1 key=$2
  rldyour::privilege::read_record "$file" | /usr/bin/sed -n "s/^${key}=//p" | /usr/bin/head -n 1
}

rldyour::privilege::read_record() {
  local file=$1
  case "$file" in
    "$RLDYOUR_PRIVILEGE_RECEIPT"|"$RLDYOUR_PRIVILEGE_TRANSACTION") ;;
    *) return 1 ;;
  esac
  if [ -r "$file" ]; then
    /bin/cat -- "$file"
  else
    rldyour::privilege::root_exec /bin/cat -- "$file"
  fi
}

rldyour::privilege::record_valid() {
  local record=$1 expected key
  if ! rldyour::privilege::trusted_root_path "$record" || [ ! -f "$record" ]; then
    return 1
  fi
  [ "$(/usr/bin/stat -c '%u:%g:%a' -- "$record")" = 0:0:600 ] || return 1
  [ "$(rldyour::privilege::receipt_value "$record" marker)" = "macos-ubuntu-bootstrap-privilege-v1" ] || return 1
  for key in helper contract policy; do
    expected=$(rldyour::privilege::receipt_value "$record" "${key}_sha256")
    printf '%s' "$expected" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' || return 1
    [ "$(rldyour::privilege::receipt_value "$record" "${key}_sha256" | /usr/bin/wc -l)" -eq 1 ] || return 1
  done
  [ "$(rldyour::privilege::read_record "$record" | /usr/bin/wc -l)" -eq 4 ]
}

rldyour::privilege::bundle_matches_record() {
  local record=$1 expected actual key path mode
  rldyour::privilege::record_valid "$record" || return 1
  for key in helper contract policy; do
    case "$key" in
      helper) path=$RLDYOUR_PRIVILEGE_HELPER; mode=755 ;;
      contract) path=$RLDYOUR_PRIVILEGE_CONTRACT; mode=644 ;;
      policy) path=$RLDYOUR_PRIVILEGE_POLICY; mode=644 ;;
    esac
    expected=$(rldyour::privilege::receipt_value "$record" "${key}_sha256")
    if ! rldyour::privilege::trusted_root_path "$path" || [ ! -f "$path" ]; then
      return 1
    fi
    [ "$(/usr/bin/stat -c '%u:%g:%a' -- "$path")" = "0:0:$mode" ] || return 1
    actual=$(rldyour::privilege::file_sha256 "$path") || return 1
    [ "$actual" = "$expected" ] || return 1
  done
}

rldyour::privilege::bundle_current() {
  local source actual key path
  rldyour::privilege::bundle_matches_record "$RLDYOUR_PRIVILEGE_RECEIPT" || return 1
  for key in helper contract policy; do
    case "$key" in
      helper) source=$RLDYOUR_PRIVILEGE_SOURCE_HELPER; path=$RLDYOUR_PRIVILEGE_HELPER ;;
      contract) source=$RLDYOUR_PRIVILEGE_SOURCE_CONTRACT; path=$RLDYOUR_PRIVILEGE_CONTRACT ;;
      policy) source=$RLDYOUR_PRIVILEGE_SOURCE_POLICY; path=$RLDYOUR_PRIVILEGE_POLICY ;;
    esac
    actual=$(rldyour::privilege::file_sha256 "$source") || return 1
    [ "$(rldyour::privilege::file_sha256 "$path")" = "$actual" ] || return 1
  done
}

rldyour::privilege::write_record_source() {
  local destination=$1 helper_sha=$2 contract_sha=$3 policy_sha=$4
  local tmp
  tmp=$(/usr/bin/mktemp) || return 1
  /usr/bin/chmod 0600 "$tmp" || { /bin/rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' 'marker=macos-ubuntu-bootstrap-privilege-v1'
    printf 'helper_sha256=%s\n' "$helper_sha"
    printf 'contract_sha256=%s\n' "$contract_sha"
    printf 'policy_sha256=%s\n' "$policy_sha"
  } >"$tmp" || { /bin/rm -f -- "$tmp"; return 1; }
  local digest
  digest=$(rldyour::privilege::file_sha256 "$tmp") || { /bin/rm -f -- "$tmp"; return 1; }
  # python-surface: publisher-record
  rldyour::privilege::root_exec /usr/bin/python3 -I "$RLDYOUR_PRIVILEGE_SOURCE_PUBLISHER" \
    --source "$tmp" --destination "$destination" --sha256 "$digest" --mode 0600
  local status=$?
  /bin/rm -f -- "$tmp"
  return "$status"
}

rldyour::privilege::secure_publish() {
  local source=$1 destination=$2 mode=$3 digest
  digest=$(rldyour::privilege::file_sha256 "$source") || return 1
  # python-surface: publisher-file
  rldyour::privilege::root_exec /usr/bin/python3 -I "$RLDYOUR_PRIVILEGE_SOURCE_PUBLISHER" \
    --source "$source" --destination "$destination" --sha256 "$digest" --mode "$mode"
}

rldyour::privilege::transaction_matches_sources() {
  local record=$1 helper_sha=$2 contract_sha=$3 policy_sha=$4 actual
  actual=$(rldyour::privilege::receipt_value "$record" helper_sha256) || return 1
  [ "$actual" = "$helper_sha" ] || return 1
  actual=$(rldyour::privilege::receipt_value "$record" contract_sha256) || return 1
  [ "$actual" = "$contract_sha" ] || return 1
  actual=$(rldyour::privilege::receipt_value "$record" policy_sha256) || return 1
  [ "$actual" = "$policy_sha" ]
}

rldyour::privilege::provision_bundle() {
  local helper_sha contract_sha policy_sha key source destination mode current expected
  helper_sha=$(rldyour::privilege::file_sha256 "$RLDYOUR_PRIVILEGE_SOURCE_HELPER") || return 1
  contract_sha=$(rldyour::privilege::file_sha256 "$RLDYOUR_PRIVILEGE_SOURCE_CONTRACT") || return 1
  policy_sha=$(rldyour::privilege::file_sha256 "$RLDYOUR_PRIVILEGE_SOURCE_POLICY") || return 1

  for destination in /usr/local/libexec /usr/local/share/rldyour-bootstrap /usr/share/polkit-1/actions; do
    # python-surface: publisher-directory
    rldyour::privilege::root_exec /usr/bin/python3 -I "$RLDYOUR_PRIVILEGE_SOURCE_PUBLISHER" \
      --ensure-directory "$destination" --mode 0755 || return 1
  done

  if [ -e "$RLDYOUR_PRIVILEGE_TRANSACTION" ] || [ -L "$RLDYOUR_PRIVILEGE_TRANSACTION" ]; then
    rldyour::privilege::record_valid "$RLDYOUR_PRIVILEGE_TRANSACTION" || {
      rldyour::log "error" "partial privilege transaction is invalid; preserving it unchanged"
      return 1
    }
    if ! rldyour::privilege::transaction_matches_sources \
      "$RLDYOUR_PRIVILEGE_TRANSACTION" "$helper_sha" "$contract_sha" "$policy_sha"; then
      rldyour::log "error" "partial privilege transaction targets another source revision"
      return 1
    fi
  else
    if [ -e "$RLDYOUR_PRIVILEGE_RECEIPT" ] || [ -L "$RLDYOUR_PRIVILEGE_RECEIPT" ]; then
      rldyour::privilege::bundle_matches_record "$RLDYOUR_PRIVILEGE_RECEIPT" || {
        rldyour::log "error" "managed privilege bundle is divergent; preserving it unchanged"
        return 1
      }
    else
      for destination in "$RLDYOUR_PRIVILEGE_HELPER" "$RLDYOUR_PRIVILEGE_CONTRACT" "$RLDYOUR_PRIVILEGE_POLICY"; do
        if [ -e "$destination" ] || [ -L "$destination" ]; then
          rldyour::log "error" "unmanaged privilege destination exists; preserved: $destination"
          return 1
        fi
      done
    fi
    rldyour::privilege::write_record_source "$RLDYOUR_PRIVILEGE_TRANSACTION" \
      "$helper_sha" "$contract_sha" "$policy_sha" || return 1
  fi

  for key in helper contract policy; do
    case "$key" in
      helper) source=$RLDYOUR_PRIVILEGE_SOURCE_HELPER; destination=$RLDYOUR_PRIVILEGE_HELPER; mode=0755 ;;
      contract) source=$RLDYOUR_PRIVILEGE_SOURCE_CONTRACT; destination=$RLDYOUR_PRIVILEGE_CONTRACT; mode=0644 ;;
      policy) source=$RLDYOUR_PRIVILEGE_SOURCE_POLICY; destination=$RLDYOUR_PRIVILEGE_POLICY; mode=0644 ;;
    esac
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      if [ -L "$destination" ] || [ ! -f "$destination" ]; then
        return 1
      fi
      current=$(rldyour::privilege::file_sha256 "$destination") || return 1
      expected=$(rldyour::privilege::file_sha256 "$source") || return 1
      if [ "$current" != "$expected" ]; then
        rldyour::log "error" "managed privilege target differs from this source; no-replace policy preserves it"
        return 1
      fi
      continue
    fi
    rldyour::privilege::secure_publish "$source" "$destination" "$mode" || return 1
  done
  rldyour::privilege::write_record_source "$RLDYOUR_PRIVILEGE_RECEIPT" \
    "$helper_sha" "$contract_sha" "$policy_sha" || return 1
  # Keep the immutable transaction record. Removing a pathname cannot be made
  # compare-and-delete with POSIX unlink; retaining it avoids deleting a
  # concurrently replaced object and provides recovery evidence.
  rldyour::privilege::bundle_current
}

rldyour::privilege::provision_for_profile() {
  local profile=$1
  [ "$profile" = server ] && return 0
  rldyour::privilege::provision_bundle
}

rldyour::privilege::preflight() {
  local profile=$1 gui=$2 needs_root=$3
  RLDYOUR_PRIVILEGE_PROFILE=$profile
  RLDYOUR_PRIVILEGE_GUI=$gui
  export RLDYOUR_PRIVILEGE_PROFILE RLDYOUR_PRIVILEGE_GUI
  rldyour::privilege::source_contract_valid || { rldyour::privilege::result CONTRACT_INVALID; return 1; }
  if [ "$needs_root" -eq 0 ]; then
    rldyour::privilege::set_mode none
    rldyour::privilege::result NOT_REQUIRED
    return 0
  fi
  if [ "${RLDYOUR_DRY_RUN:-1}" -eq 1 ]; then
    rldyour::privilege::set_mode plan
    rldyour::privilege::result PLANNED
    return 0
  fi
  case "$RLDYOUR_PRIVILEGE_MODE" in
    root|sudo-noninteractive|sudo-tty|policykit) return 0 ;;
  esac
  if [ "${EUID:-$(/usr/bin/id -u)}" -eq 0 ]; then
    rldyour::privilege::source_contract_allows "$profile" "$gui" root || {
      rldyour::privilege::result ROOT_PROFILE_UNSUPPORTED
      return 1
    }
    rldyour::privilege::set_mode root
    rldyour::privilege::provision_for_profile "$profile" || {
      rldyour::privilege::result BUNDLE_PROVISION_FAILED
      return 1
    }
    rldyour::privilege::result AUTHORIZED
    return 0
  fi
  if rldyour::privilege::absolute_tool /usr/bin/sudo && /usr/bin/sudo -n -- /usr/bin/true 2>/dev/null; then
    rldyour::privilege::source_contract_allows "$profile" "$gui" sudo-noninteractive || return 1
    rldyour::privilege::set_mode sudo-noninteractive
    rldyour::privilege::provision_for_profile "$profile" || { rldyour::privilege::result BUNDLE_PROVISION_FAILED; return 1; }
    rldyour::privilege::result AUTHORIZED
    return 0
  fi
  if [ -t 0 ] && [ -t 1 ]; then
    rldyour::privilege::absolute_tool /usr/bin/sudo || { rldyour::privilege::result SUDO_UNAVAILABLE; return 1; }
    rldyour::privilege::source_contract_allows "$profile" "$gui" sudo-tty || return 1
    rldyour::privilege::set_mode sudo-tty
    rldyour::log "info" "Authenticate once with sudo; every later privileged command is non-interactive."
    /usr/bin/sudo -v || { rldyour::privilege::result AUTH_DENIED; return 1; }
    /usr/bin/sudo -n -- /usr/bin/true >/dev/null 2>&1 || { rldyour::privilege::result CACHE_UNAVAILABLE; return 1; }
    rldyour::privilege::provision_for_profile "$profile" || { rldyour::privilege::result BUNDLE_PROVISION_FAILED; return 1; }
    rldyour::privilege::result AUTHORIZED
    return 0
  fi
  if [ "$profile" = desktop ] && [ "$gui" -eq 1 ] &&
    rldyour::privilege::source_contract_allows "$profile" "$gui" policykit &&
    rldyour::privilege::absolute_tool /usr/bin/pkexec &&
    rldyour::privilege::absolute_tool /usr/bin/timeout &&
    rldyour::privilege::bundle_current; then
    rldyour::privilege::set_mode policykit
    rldyour::privilege::result AUTH_AVAILABLE_UNPROVEN
    return 0
  fi
  rldyour::privilege::set_mode unavailable
  rldyour::privilege::result NONINTERACTIVE_AUTH_UNAVAILABLE
  rldyour::log "error" "privilege preflight stopped before mutation; use root for the server layer, a TTY sudo-capable owner, NOPASSWD/cached sudo, or an already provisioned GUI helper"
  return 1
}

rldyour::privilege::refresh() {
  case "$RLDYOUR_PRIVILEGE_MODE" in
    root|policykit|none|plan) return 0 ;;
    sudo-noninteractive|sudo-tty)
      /usr/bin/sudo -n -- /usr/bin/true >/dev/null 2>&1 || {
        rldyour::privilege::result CACHE_EXPIRED
        return 1
      }
      ;;
    *) rldyour::privilege::result STATE_INVALID; return 1 ;;
  esac
}

rldyour::privilege::as_root() {
  case "$RLDYOUR_PRIVILEGE_MODE" in
    root) "$@" ;;
    sudo-noninteractive|sudo-tty)
      rldyour::privilege::refresh || return 1
      /usr/bin/sudo -n -- "$@"
      ;;
    plan) rldyour::run /usr/bin/sudo -n -- "$@" ;;
    *) rldyour::privilege::result OPERATION_NOT_ALLOWED; return 1 ;;
  esac
}

# Wait for one pkexec-authorized operation, bounded by the authentication
# timeout, and distinguish "never authorized" from "authorized and still
# running". The helper announces itself on stderr before it mutates anything, so
# the marker is what separates the two states -- not a guess from elapsed time.
rldyour::privilege::policykit_wait() {
  local operation=$1 marker pid waited=0 status
  marker="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$marker'" RETURN

  # Preserve the helper's stderr for the caller while also recording it, so the
  # started marker can be observed without swallowing the result lines.
  { /usr/bin/pkexec --disable-internal-agent \
      "$RLDYOUR_PRIVILEGE_HELPER" "$operation" 2>&1 1>&3 \
      | /usr/bin/tee -a "$marker" >&2; } 3>&1 &
  pid=$!

  while [ "$waited" -lt "$RLDYOUR_PRIVILEGE_AUTH_TIMEOUT" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    # Still running at the deadline. Which state depends on whether the root
    # helper ever started, and that is recorded rather than inferred.
    if grep -Fq 'RLDYOUR_PRIVILEGE_RESULT=STARTED' "$marker"; then
      return 125
    fi
    return 124
  fi

  wait "$pid"
  status=$?
  return "$status"
}

rldyour::privilege::operation() {
  local operation=$1 status
  rldyour::privilege::source_contract_allows "$RLDYOUR_PRIVILEGE_PROFILE" \
    "$RLDYOUR_PRIVILEGE_GUI" "$RLDYOUR_PRIVILEGE_MODE" "$operation" || {
    rldyour::privilege::result UNKNOWN_OR_INCOMPATIBLE_OPERATION
    return 2
  }
  case "$RLDYOUR_PRIVILEGE_MODE" in
    root) "$RLDYOUR_PRIVILEGE_HELPER" "$operation" ;;
    sudo-noninteractive|sudo-tty)
      rldyour::privilege::refresh || return 1
      /usr/bin/sudo -n -- "$RLDYOUR_PRIVILEGE_HELPER" "$operation"
      ;;
    policykit)
      # This wait is an AUTHENTICATION bound and says so. It is not, and cannot
      # be, an operation bound.
      #
      # The previous code used `timeout --foreground`, which promised neither.
      # GNU coreutils documents that mode as "children of COMMAND will not be
      # timed out", so apt-get, dpkg and curl were outside it by design. Worse,
      # the signal it does send goes to pkexec -- a setuid-root process this
      # unprivileged launcher may not signal at all, so the TERM fails with
      # EPERM while `timeout` still exits 124 on the deadline. The launcher
      # reported AUTH_TIMEOUT while a root transaction kept running.
      #
      # Only root can bound root, so the descendant guarantee lives in the
      # helper (see terminate_descendants there), which owns its process group
      # and escalates TERM -> KILL over it. What is left here is the honest
      # part: stop waiting, and report which of the two states this is.
      rldyour::privilege::policykit_wait "$operation"
      status=$?
      case "$status" in
        0) rldyour::privilege::result AUTHORIZED; return 0 ;;
        # Nothing was authorized, so nothing privileged began. Provable: pkexec
        # exits before exec'ing the helper when authentication does not complete.
        124) rldyour::privilege::result AUTH_TIMEOUT ;;
        # The helper had already started. This process cannot signal it, and the
        # helper bounds itself; saying "timeout" alone would claim a guarantee
        # this side does not have.
        125) rldyour::privilege::result AUTH_TIMEOUT_OPERATION_RESIDUAL ;;
        126) rldyour::privilege::result AUTH_CANCELLED ;;
        127) rldyour::privilege::result AUTH_DENIED_OR_UNAVAILABLE ;;
        *) rldyour::privilege::result OPERATION_FAILED ;;
      esac
      return "$status"
      ;;
    plan) rldyour::log "info" "[DRY-RUN] privileged operation: $operation" ;;
    *) rldyour::privilege::result STATE_INVALID; return 1 ;;
  esac
}
