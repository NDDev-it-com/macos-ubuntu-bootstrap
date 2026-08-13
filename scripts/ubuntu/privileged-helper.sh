#!/bin/bash -p

# Root-only, fixed-operation Ubuntu helper. It accepts no paths, URLs, hashes,
# packages, environment overrides, or arbitrary commands from its caller.
set -euo pipefail
readonly EXPECTED_PATH=/usr/local/libexec/rldyour-bootstrap-privileged
readonly CONTRACT=/usr/local/share/rldyour-bootstrap/rldyour-contract.json
readonly SAFE_PATH=/usr/sbin:/usr/bin:/sbin:/bin
caller_uid=${PKEXEC_UID:-}
PATH=$SAFE_PATH
export PATH
unset BASH_ENV CDPATH ENV GLOBIGNORE IFS LD_LIBRARY_PATH LD_PRELOAD PYTHONHOME PYTHONPATH RUBYLIB PERL5LIB PKEXEC_UID
umask 022
tmp_dir=
DESKTOP_APT_PACKAGES=(
  ca-certificates curl gpg gnupg git jq python3 python3-venv
  shellcheck shfmt clangd zsh unzip xz-utils wget zip lsb-release yamllint fd-find bat
  fzf zoxide tmux btop duf hexyl gh ripgrep httpie miller software-properties-common
  wl-clipboard libsecret-tools
  build-essential
)
readonly -a DESKTOP_APT_PACKAGES
GUI_APT_PACKAGES=(fonts-jetbrains-mono google-chrome-stable)
readonly -a GUI_APT_PACKAGES

result() { /usr/bin/printf 'RLDYOUR_PRIVILEGE_RESULT=%s operation=%s\n' "$1" "${2:-redacted}" >&2; }
clean_env() { /usr/bin/env -i PATH="$SAFE_PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 "$@"; }
cleanup() { [ -z "$tmp_dir" ] || /bin/rm -rf -- "$tmp_dir"; }
on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if ! cleanup; then
    result CLEANUP_FAILED cleanup
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
on_signal() {
  local status=$1
  trap - EXIT HUP INT TERM
  cleanup || result CLEANUP_FAILED cleanup
  exit "$status"
}
fail() { result OPERATION_FAILED "${1:-unknown}"; return 1; }

trusted_file() {
  local path=$1 expected_mode=$2 bind_self=${3:-0} bound_fd=${4:-}
  # python-surface: helper-trusted-path
  clean_env /usr/bin/python3 -I - "$path" "$expected_mode" "$bind_self" "$bound_fd" <<'PY'
import os, stat, sys
path, expected_mode, bind_self, bound_fd = sys.argv[1], int(sys.argv[2], 8), sys.argv[3] == "1", sys.argv[4]
assert path.startswith("/") and path != "/" and ".." not in path.split("/")
fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
opened = []
try:
    root = os.fstat(fd)
    assert root.st_uid == 0 and not stat.S_IMODE(root.st_mode) & 0o022
    parts = [part for part in path.split("/") if part]
    for index, part in enumerate(parts):
        final = index == len(parts) - 1
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        if not final:
            flags |= os.O_DIRECTORY
        next_fd = os.open(part, flags, dir_fd=fd)
        opened.append(next_fd)
        value = os.fstat(next_fd)
        assert value.st_uid == 0 and not stat.S_IMODE(value.st_mode) & 0o022
        if final:
            assert stat.S_ISREG(value.st_mode) and value.st_gid == 0
            assert stat.S_IMODE(value.st_mode) == expected_mode
        else:
            os.close(fd)
            fd = next_fd
    if bind_self:
        expected = os.fstat(opened[-1])
        actual = os.stat(f"/proc/{os.getppid()}/fd/255")
        assert (expected.st_dev, expected.st_ino) == (actual.st_dev, actual.st_ino)
    if bound_fd:
        expected = os.fstat(opened[-1])
        actual = os.stat(f"/proc/{os.getppid()}/fd/{int(bound_fd)}")
        assert (expected.st_dev, expected.st_ino) == (actual.st_dev, actual.st_ino)
finally:
    for item in opened:
        try: os.close(item)
        except OSError: pass
    try: os.close(fd)
    except OSError: pass
PY
}

contract_values() {
  local contract_input=${1:-$CONTRACT}
  # python-surface: helper-contract-values
  clean_env /usr/bin/python3 -I - "$contract_input" <<'PY'
import json, pathlib, re, sys
from urllib.parse import urlsplit
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
p = data["privilege"]
assert p["schema_version"] == 1
assert p["system_python_minimum"] == "3.12"
assert len(p["system_python_surfaces"]) == 14
assert p["runtime"]["helper"] == "/usr/local/libexec/rldyour-bootstrap-privileged"
assert p["runtime"]["contract"] == "/usr/local/share/rldyour-bootstrap/rldyour-contract.json"
assert set(p["operations"]) == {
    "ubuntu-desktop-system", "ubuntu-desktop-gui-system", "ubuntu-server-system"
}
assert p["operation_owners"]["ubuntu-desktop-system"] == "scripts/ubuntu/privileged-helper.sh"
assert p["operation_owners"]["ubuntu-desktop-gui-system"] == "scripts/ubuntu/privileged-helper.sh"
assert p["operation_owners"]["ubuntu-server-system"] == "scripts/ubuntu/server.sh"
apps = {x["name"]: x for x in data["ubuntu_apt_packages"]["desktop_apps"]}
chrome = apps["google-chrome-stable"]["apt_source"]
rustdesk = apps["rustdesk"]
identities = chrome["accepted_source_identities"]
assert isinstance(identities, list) and len(identities) == 2
normalized = []
for identity in identities:
    assert set(identity) == {"scheme", "host", "path"}
    assert identity["scheme"] == "https" and identity["host"] == "dl.google.com"
    assert re.fullmatch(r"/linux/[a-z-]+/deb", identity["path"])
    normalized.append((identity["scheme"], identity["host"], identity["path"]))
assert len(set(normalized)) == len(normalized)
canonical = urlsplit(chrome["uri"])
assert canonical.username is None and canonical.password is None and canonical.port is None
assert (canonical.scheme, canonical.hostname, canonical.path.rstrip("/")) == normalized[0]
assert not canonical.query and not canonical.fragment
values = (
    chrome["key_url"], re.sub(r"[^0-9A-Fa-f]", "", chrome["key_fingerprint"]).upper(),
    chrome["uri"], chrome["managed_keyring"], chrome["managed_source"],
    rustdesk["url"]["x64"], rustdesk["sha256"]["x64"],
)
assert re.fullmatch(r"[0-9A-F]{40}", values[1])
assert re.fullmatch(r"[0-9a-f]{64}", values[6])
for url in (values[0], values[2], values[5]):
    parsed = urlsplit(url)
    assert parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password
    assert not parsed.fragment
assert pathlib.PurePosixPath(values[3]).parent == pathlib.PurePosixPath("/etc/apt/keyrings")
assert pathlib.PurePosixPath(values[4]).parent == pathlib.PurePosixPath("/etc/apt/sources.list.d")
names = ("chrome_key_url", "chrome_fingerprint", "chrome_repo_uri", "chrome_keyring", "chrome_source", "rustdesk_url", "rustdesk_sha256")
assert len(names) == 7 and len(values) == 7
for name, value in zip(names, values):
    assert "\n" not in value and "=" not in value
    print(f"{name}={value}")
PY
}

load_contract_values() {
  local capture=$1 contract_input=${2:-$CONTRACT} status=0 size line key value
  : >"$capture"
  (ulimit -f 8; contract_values "$contract_input" >"$capture") || status=$?
  [ "$status" -eq 0 ] || return "$status"
  size=$(LC_ALL=C /usr/bin/wc -c <"$capture") || return 1
  size=${size//[[:space:]]/}
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  if [ "$size" -le 0 ] || [ "$size" -gt 4096 ]; then
    return 1
  fi
  CONTRACT_RECORDS=()
  while IFS= read -r line; do
    if [ -z "$line" ] || [[ "$line" == *$'\r'* ]]; then
      return 1
    fi
    key=${line%%=*}; value=${line#*=}
    if [ "$key" = "$line" ] || [ -z "$value" ]; then
      return 1
    fi
    CONTRACT_RECORDS+=("$key=$value")
  done <"$capture"
  [ "${#CONTRACT_RECORDS[@]}" -eq 7 ] || return 1
  if [ "${CONTRACT_RECORDS[0]%%=*}" = chrome_key_url ] &&
    [ "${CONTRACT_RECORDS[1]%%=*}" = chrome_fingerprint ] &&
    [ "${CONTRACT_RECORDS[2]%%=*}" = chrome_repo_uri ] &&
    [ "${CONTRACT_RECORDS[3]%%=*}" = chrome_keyring ] &&
    [ "${CONTRACT_RECORDS[4]%%=*}" = chrome_source ] &&
    [ "${CONTRACT_RECORDS[5]%%=*}" = rustdesk_url ] &&
    [ "${CONTRACT_RECORDS[6]%%=*}" = rustdesk_sha256 ]; then
    return 0
  else
    return 1
  fi
}

policykit_subject_valid() {
  local uid=$1 runtime state
  if [[ ! "$uid" =~ ^[0-9]+$ ]] || [ "$uid" -le 0 ]; then
    return 1
  fi
  trusted_file /usr/bin/pkexec 4755 || return 1
  # python-surface: helper-pkexec-parent
  clean_env /usr/bin/python3 -I - "$PPID" <<'PY' || return 1
import os, sys
expected = os.stat("/usr/bin/pkexec")
actual = os.stat(f"/proc/{int(sys.argv[1])}/exe")
assert (expected.st_dev, expected.st_ino) == (actual.st_dev, actual.st_ino)
PY
  [ "$(/usr/bin/getent passwd "$uid" | /usr/bin/wc -l)" -eq 1 ] || return 1
  runtime=/run/user/$uid
  if [ ! -d "$runtime" ] || [ -L "$runtime" ]; then
    return 1
  fi
  [ "$(/usr/bin/stat -c '%u' -- "$runtime")" = "$uid" ] || return 1
  state=$(/usr/bin/loginctl show-user "$uid" --property=State --value 2>/dev/null) || return 1
  [ "$state" = active ]
}

chrome_key_fingerprint() {
  clean_env /usr/bin/gpg --batch --show-keys --with-colons "$1" 2>/dev/null |
    /usr/bin/awk -F: '$1=="pub"{n++;want=1;next}$1=="fpr"&&want{f=toupper($10);want=0}END{if(n!=1||f=="")exit 1;print f}'
}

chrome_key_matches() {
  local key=$1 expected=$2 observed
  observed=$(chrome_key_fingerprint "$key") || return 1
  [ "$observed" = "$expected" ]
}

apt_install() {
  apt_arguments_allowed "$@" || { result INTERNAL_ALLOWLIST_REJECTED apt-install; return 2; }
  /usr/bin/env -i PATH="$SAFE_PATH" DEBIAN_FRONTEND=noninteractive \
    /usr/bin/apt-get install -y --no-install-recommends --no-upgrade "$@"
}

apt_arguments_allowed() {
  local argument allowed match
  [ "$#" -gt 0 ] || return 1
  for argument in "$@"; do
    [ "$argument" = -f ] && continue
    match=0
    for allowed in "${DESKTOP_APT_PACKAGES[@]}" "${GUI_APT_PACKAGES[@]}"; do
      if [ "$argument" = "$allowed" ]; then match=1; break; fi
    done
    [ "$match" -eq 1 ] || return 1
  done
}

desktop_baseline() {
  /usr/bin/apt-get update
  apt_install "${DESKTOP_APT_PACKAGES[@]}"
}

install_rustdesk() {
  local url=$1 sha=$2
  /usr/bin/dpkg-query -W -f='${Status}' rustdesk 2>/dev/null | /usr/bin/grep -q 'install ok installed' && return 0
  clean_env /usr/bin/curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location "$url" --output "$tmp_dir/rustdesk.deb"
  [ "$(/usr/bin/sha256sum "$tmp_dir/rustdesk.deb" | /usr/bin/awk '{print $1}')" = "$sha" ] || return 1
  /usr/bin/dpkg -i "$tmp_dir/rustdesk.deb" >/dev/null 2>&1 || apt_install -f
}

install_chrome() {
  local key_url=$1 fingerprint=$2 repo_uri=$3 keyring=$4 source=$5
  clean_env /usr/bin/curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location "$key_url" --output "$tmp_dir/chrome-key"
  chrome_key_matches "$tmp_dir/chrome-key" "$fingerprint" || return 1
  /usr/bin/install -d -o root -g root -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d /etc/default
  /usr/bin/install -o root -g root -m 0644 "$tmp_dir/chrome-key" "$keyring"
  /usr/bin/printf '%s\n' '# Managed by macos-ubuntu-bootstrap: desktop-app-google-chrome-v1' \
    'Types: deb' "URIs: $repo_uri" 'Suites: stable' 'Components: main' 'Architectures: amd64' \
    "Signed-By: $keyring" >"$tmp_dir/chrome.sources"
  /usr/bin/install -o root -g root -m 0644 "$tmp_dir/chrome.sources" "$source"
  /usr/bin/printf 'repo_add_once="false"\nrepo_reenable_on_distupgrade="true"\n' >"$tmp_dir/google-chrome"
  /usr/bin/install -o root -g root -m 0644 "$tmp_dir/google-chrome" /etc/default/google-chrome
  /usr/bin/apt-get update -qq
  apt_install google-chrome-stable
}

desktop_gui() {
  local key_url=$1 fingerprint=$2 repo_uri=$3 keyring=$4 source=$5 rustdesk_url=$6 rustdesk_sha=$7
  [ "$(/usr/bin/dpkg --print-architecture)" = amd64 ] || return 1
  apt_install fonts-jetbrains-mono
  /usr/bin/sed -i 's/^# *ru_RU\.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
  /usr/sbin/locale-gen >/dev/null
  /usr/bin/localectl --no-convert set-x11-keymap us,ru pc105 '' grp:alt_shift_toggle
  install_rustdesk "$rustdesk_url" "$rustdesk_sha"
  install_chrome "$key_url" "$fingerprint" "$repo_uri" "$keyring" "$source"
  if /usr/bin/snap list firefox >/dev/null 2>&1; then /usr/bin/snap remove --purge firefox; fi
  if /usr/bin/dpkg-query -W -f='${Status}' firefox 2>/dev/null | /usr/bin/grep -q 'install ok installed'; then
    apt_install --purge firefox
    /usr/bin/env -i PATH="$SAFE_PATH" DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get autoremove -y
  fi
}

main() {
  local operation contract_fd
  trap on_exit EXIT
  trap 'on_signal 129' HUP
  trap 'on_signal 130' INT
  trap 'on_signal 143' TERM
  [ "$(/usr/bin/id -u)" -eq 0 ] || { result NOT_ROOT bootstrap; return 1; }
  [ "$0" = "$EXPECTED_PATH" ] || { result UNTRUSTED_EXECUTABLE bootstrap; return 1; }
  exec {contract_fd}<"$CONTRACT" || { result TRUST_BOUNDARY_INVALID bootstrap; return 1; }
  if ! trusted_runtime_inputs "$contract_fd"; then
    result TRUST_BOUNDARY_INVALID bootstrap
    return 1
  fi
  validate_external_request "$@" || return $?
  operation=$1
  tmp_dir=$(/usr/bin/mktemp -d /var/tmp/rldyour-privilege.XXXXXX)
  /usr/bin/chmod 0700 "$tmp_dir"
  load_contract_values "$tmp_dir/contract.records" "/proc/$$/fd/$contract_fd" || { result CONTRACT_INVALID "$operation"; return 1; }
  local -a values=()
  local record
  for record in "${CONTRACT_RECORDS[@]}"; do values+=("${record#*=}"); done
  case "$operation" in
    ubuntu-desktop-system) desktop_baseline ;;
    ubuntu-desktop-gui-system) desktop_baseline; desktop_gui "${values[@]}" ;;
    ubuntu-server-system) result DELEGATED_TO_SERVER_MODULE "$operation"; return 2 ;;
    *) result UNKNOWN_OPERATION redacted; return 2 ;;
  esac
  result AUTHORIZED "$operation"
}

trusted_runtime_inputs() {
  local contract_fd=$1
  if ! trusted_file "$EXPECTED_PATH" 755 1; then
    return 1
  fi
  if ! trusted_file "$CONTRACT" 644 0 "$contract_fd"; then
    return 1
  fi
}

validate_external_request() {
  local operation=${1:-unknown}
  [ "$#" -eq 1 ] || { result INVALID_ARGUMENTS unknown; return 2; }
  case "$operation" in
    ubuntu-desktop-system|ubuntu-desktop-gui-system|ubuntu-server-system) ;;
    *) result UNKNOWN_OPERATION redacted; return 2 ;;
  esac
  if [ -n "$caller_uid" ]; then
    policykit_subject_valid "$caller_uid" || { result INVALID_PKEXEC_SUBJECT "$operation"; return 2; }
    [ "$operation" = ubuntu-desktop-gui-system ] || { result POLICYKIT_OPERATION_DENIED "$operation"; return 2; }
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
