#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LANE="${1:?usage: platform-evidence.sh LANE OUTPUT_DIR}"
OUTPUT_DIR="${2:?usage: platform-evidence.sh LANE OUTPUT_DIR}"
EVIDENCE_SHA="${EVIDENCE_SHA:?EVIDENCE_SHA is required}"
EVIDENCE_STARTED_EPOCH="$(date +%s)"
CONTAINER_NAME=""
SANDBOX_SYSTEMD_STATE=""
SANDBOX_FAILED_UNITS=""

mkdir -p "$OUTPUT_DIR"
LOG="$OUTPUT_DIR/run.log"
OBSERVED_STEPS="$OUTPUT_DIR/observed-steps"
: >"$OBSERVED_STEPS"
exec > >(tee "$LOG") 2>&1

# Record one observable step. Called only AFTER the command that proves it has
# returned successfully -- under `set -e` a failing step aborts the lane before
# its name is written, so the ledger describes what the runner did rather than
# what the matrix declares. finalize_evidence fails a successful lane whose
# ledger does not cover every step its REQUIRED capabilities name.
evidence_step() {
  printf '%s\n' "${1:?evidence_step requires a step name}" >>"$OBSERVED_STEPS"
  echo "evidence step observed: $1"
}

record_metadata() {
  local lane_contract
  lane_contract="$(python3 "$REPO_ROOT/scripts/support_evidence.py" resolve --lane "$LANE")" || return 1
  EVIDENCE_LANE="$LANE" EVIDENCE_LANE_CONTRACT="$lane_contract" \
    EVIDENCE_OUTPUT="$OUTPUT_DIR/evidence.json" python3 - <<'PY'
import json
import os
import platform
from pathlib import Path

lane = os.environ["EVIDENCE_LANE"]
contract = json.loads(os.environ["EVIDENCE_LANE_CONTRACT"])

payload = {
    "schema_version": 2,
    "repository": os.environ.get("GITHUB_REPOSITORY", "local"),
    "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
    "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local"),
    "job": os.environ.get("GITHUB_JOB", "local"),
    "evidence_tier": contract["tier"],
    "environment": contract["environment"],
    "lane": lane,
    "capabilities": contract["capabilities"],
    "composition": {
        key: contract[key]
        for key in ("os", "release", "architecture", "profile", "gui", "docker", "privilege", "interaction")
    },
    "sha": os.environ["EVIDENCE_SHA"],
    "runner_name": os.environ.get("RUNNER_NAME", "local"),
    "runner_os": os.environ.get("RUNNER_OS", platform.system()),
    "runner_arch": os.environ.get("RUNNER_ARCH", platform.machine()),
    "uname": platform.uname()._asdict(),
    "not_proven": sorted(
        capability["id"] for capability in contract["capabilities"]
        if capability["status"] == "NOT_PROVEN"
    ),
}
Path(os.environ["EVIDENCE_OUTPUT"]).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY
}

finalize_evidence() {
  local rc=$?
  if [ -n "$CONTAINER_NAME" ]; then
    docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  EVIDENCE_RC="$rc" EVIDENCE_FINISHED_EPOCH="$(date +%s)" \
    EVIDENCE_STARTED_EPOCH="$EVIDENCE_STARTED_EPOCH" \
    EVIDENCE_SUPPORT_SCRIPT="$REPO_ROOT/scripts/support_evidence.py" \
    EVIDENCE_OBSERVED_STEPS="$OBSERVED_STEPS" \
    EVIDENCE_SANDBOX_SYSTEMD_STATE="$SANDBOX_SYSTEMD_STATE" \
    EVIDENCE_SANDBOX_FAILED_UNITS="$SANDBOX_FAILED_UNITS" \
    EVIDENCE_RELEASE="${RLDYOUR_EVIDENCE_RELEASE:-}" \
    EVIDENCE_RUNNER_STABILITY="${RLDYOUR_EVIDENCE_RUNNER_STABILITY:-generally-available}" \
    EVIDENCE_OUTPUT="$OUTPUT_DIR/evidence.json" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(os.environ["EVIDENCE_OUTPUT"])
payload = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
started = int(os.environ["EVIDENCE_STARTED_EPOCH"])
finished = int(os.environ["EVIDENCE_FINISHED_EPOCH"])
payload.update({
    "duration_seconds": finished - started,
    "finished_epoch": finished,
    "result": "success" if int(os.environ["EVIDENCE_RC"]) == 0 else "failure",
    "started_epoch": started,
    # Which release actually ran, and how trustworthy the runner label is. A
    # public-preview runner produces real evidence, but evidence that says so.
    "release": os.environ.get("EVIDENCE_RELEASE") or payload.get("composition", {}).get("release", ""),
    "runner_stability": os.environ["EVIDENCE_RUNNER_STABILITY"],
})
# systemd inside a container settles `degraded` on some releases because
# systemd-modules-load cannot load kernel modules there. That is recorded, not
# hidden: a lane that ran degraded says which units failed.
if os.environ.get("EVIDENCE_SANDBOX_SYSTEMD_STATE"):
    payload["sandbox_systemd_state"] = os.environ["EVIDENCE_SANDBOX_SYSTEMD_STATE"]
    failed = os.environ.get("EVIDENCE_SANDBOX_FAILED_UNITS", "")
    payload["sandbox_failed_units"] = sorted(filter(None, failed.split(",")))
sys.path.insert(0, str(Path(os.environ["EVIDENCE_SUPPORT_SCRIPT"]).parent))
import support_evidence

ledger = Path(os.environ["EVIDENCE_OBSERVED_STEPS"])
observed = ledger.read_text(encoding="utf-8").split() if ledger.exists() else []
support_evidence.finalize_evidence(payload, payload["result"], observed)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  echo "evidence lane=$LANE result=$([ "$rc" -eq 0 ] && echo success || echo failure) duration_seconds=$(($(date +%s) - EVIDENCE_STARTED_EPOCH))"
  exit "$rc"
}

assert_exact_source() {
  local actual
  actual="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  [ "$actual" = "$EVIDENCE_SHA" ] || {
    echo "checked-out SHA $actual does not match required evidence SHA $EVIDENCE_SHA" >&2
    return 1
  }
}

run_native_macos() {
  local gui_flag=$1
  local gui_enabled=1
  local -a verify_args=(--strict)
  if [ "$gui_flag" = --no-gui ]; then
    gui_enabled=0
    verify_args+=(--no-gui)
  fi
  [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]
  bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --profile desktop "$gui_flag" --plan --strict
  evidence_step plan
  bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --profile desktop "$gui_flag" --apply --strict
  evidence_step apply
  RLDYOUR_GUI_ENABLED="$gui_enabled" bash "$REPO_ROOT/scripts/macos/verify.sh" "${verify_args[@]}"
  evidence_step strict_verify
  bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --profile desktop "$gui_flag" --apply --strict
  evidence_step repeat_apply
  RLDYOUR_GUI_ENABLED="$gui_enabled" bash "$REPO_ROOT/scripts/macos/verify.sh" "${verify_args[@]}"
  evidence_step repeat_strict_verify
}

run_native_ubuntu_desktop() {
  [ "$(uname -s)" = Linux ]
  ensure_native_ubuntu_user
  native_ubuntu_cmd "bash scripts/bootstrap.sh --platform ubuntu --profile desktop --no-gui --plan --strict"
  evidence_step plan
  native_ubuntu_cmd "bash scripts/bootstrap.sh --platform ubuntu --profile desktop --no-gui --apply --strict"
  evidence_step apply
  native_ubuntu_cmd "RLDYOUR_PROFILE=desktop RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=none bash scripts/ubuntu/verify.sh --strict"
  evidence_step strict_verify
  native_ubuntu_cmd "bash scripts/bootstrap.sh --platform ubuntu --profile desktop --no-gui --apply --strict"
  evidence_step repeat_apply
  native_ubuntu_cmd "RLDYOUR_PROFILE=desktop RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=none bash scripts/ubuntu/verify.sh --strict"
  evidence_step repeat_strict_verify
}

run_arm_gui_refusal() {
  [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ]
  local output rc=0
  ensure_native_ubuntu_user
  output="$(native_ubuntu_cmd "bash scripts/bootstrap.sh --platform ubuntu --profile desktop --gui --apply" 2>&1)" || rc=$?
  printf '%s\n' "$output"
  evidence_step gui_apply_refused
  [ "$rc" -eq 2 ]
  evidence_step refusal_exit_code
  grep -Fq "Ubuntu GUI apply requires amd64" <<<"$output"
  evidence_step refusal_message
  [ ! -e /home/rldyourevidence/.config/rldyour ]
  [ ! -e /home/rldyourevidence/.local/share/rldyour ]
  evidence_step no_managed_state
}

ensure_native_ubuntu_user() {
  if ! id rldyourevidence >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash rldyourevidence
    printf 'rldyourevidence ALL=(ALL) NOPASSWD:ALL\n' | \
      sudo tee /etc/sudoers.d/rldyourevidence >/dev/null
    sudo chmod 0440 /etc/sudoers.d/rldyourevidence
  fi
  NATIVE_REPO_ROOT=/opt/rldyour-evidence-source
  if [ ! -d "$NATIVE_REPO_ROOT" ]; then
    sudo cp -a "$REPO_ROOT" "$NATIVE_REPO_ROOT"
    sudo chmod -R a+rX "$NATIVE_REPO_ROOT"
  fi
  # GitHub's developer image deliberately makes /usr/local a collaborative
  # package namespace. A clean Ubuntu target does not. This native lane models
  # the supported clean-system production authority before exercising the
  # strict root-owned publisher; it does not weaken publisher policy.
  sudo install -d -o root -g root -m 0755 \
    /usr/local/libexec /usr/local/share /usr/share/polkit-1/actions
  sudo chown root:root /usr/local /usr/local/share /usr/local/libexec \
    /usr/share /usr/share/polkit-1 /usr/share/polkit-1/actions
  sudo chmod 0755 /usr/local /usr/local/share /usr/local/libexec \
    /usr/share /usr/share/polkit-1 /usr/share/polkit-1/actions
  sudo /usr/bin/python3 -I - <<'PY'
import os, stat
for path in (
    "/usr", "/usr/local", "/usr/local/libexec", "/usr/local/share",
    "/usr/share", "/usr/share/polkit-1", "/usr/share/polkit-1/actions",
):
    value = os.stat(path, follow_symlinks=False)
    assert stat.S_ISDIR(value.st_mode) and value.st_uid == 0 and value.st_gid == 0
    assert not stat.S_IMODE(value.st_mode) & 0o022
PY
}

native_ubuntu_cmd() {
  sudo --user rldyourevidence --set-home env \
    HOME=/home/rldyourevidence USER=rldyourevidence LOGNAME=rldyourevidence \
    bash -c "cd $(printf '%q' "$NATIVE_REPO_ROOT") && $1"
}

container_exec_dev() {
  local uid
  uid="$(docker exec "$CONTAINER_NAME" id -u dev)"
  docker exec --user dev \
    --env HOME=/home/dev \
    --env USER=dev \
    --env LOGNAME=dev \
    --env XDG_RUNTIME_DIR="/run/user/$uid" \
    --env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    "$CONTAINER_NAME" bash -lc "$1"
}

start_systemd_container() {
  CONTAINER_NAME="rldyour-evidence-${GITHUB_RUN_ID:-local}-${RANDOM}"
  # The sandbox release is a lane property, not the runner's. A 26.04 container
  # runs on a 24.04 runner, so release coverage does not depend on a
  # public-preview runner label being available.
  local release="${RLDYOUR_EVIDENCE_RELEASE:-24.04}"
  local image="rldyour-evidence-systemd:${release}"
  docker build --build-arg "RELEASE=${release}" --tag "$image" - <<'DOCKERFILE'
ARG RELEASE=24.04
FROM ubuntu:${RELEASE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl dbus-user-session openssh-server python3 sudo systemd systemd-sysv \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash dev \
 && printf 'dev ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/dev \
 && chmod 0440 /etc/sudoers.d/dev
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE
  docker run --detach --privileged --cgroupns=host \
    --name "$CONTAINER_NAME" \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
    --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --volume "$REPO_ROOT:/repo:ro" \
    "$image"
  # `running` was never the property this lane needs, and requiring it is a
  # release-portability bug rather than a strictness. On 26.04
  # systemd-modules-load.service fails inside a container -- it cannot load
  # kernel modules -- so systemd settles at `degraded` and never reaches
  # `running`. The loop below would have timed out after 30 attempts and failed
  # a 26.04 lane for a reason that has nothing to do with the bootstrap.
  #
  # What the lane needs is that systemd finished booting, and that the
  # facilities it uses are up. Both settled states are accepted; a degraded one
  # is recorded with its failed units rather than tolerated silently, and the
  # facility assertions below still have to hold either way.
  local ready=0 state=""
  for _ in {1..60}; do
    state="$(docker exec "$CONTAINER_NAME" systemctl is-system-running 2>/dev/null || true)"
    case "$state" in
      running|degraded) ready=1; break ;;
    esac
    sleep 1
  done
  [ "$ready" -eq 1 ] || {
    echo "systemd did not settle inside the container; last state: ${state:-unknown}" >&2
    docker logs "$CONTAINER_NAME"
    docker exec "$CONTAINER_NAME" systemctl --failed || true
    return 1
  }
  SANDBOX_SYSTEMD_STATE="$state"
  if [ "$state" = degraded ]; then
    SANDBOX_FAILED_UNITS="$(docker exec "$CONTAINER_NAME" systemctl --failed --no-legend --plain 2>/dev/null |
      awk '{ print $1 }' | paste -sd, - || true)"
    echo "systemd settled degraded; failed units: ${SANDBOX_FAILED_UNITS:-none}"
  fi
  local dev_uid
  dev_uid="$(docker exec "$CONTAINER_NAME" id -u dev)"
  docker exec "$CONTAINER_NAME" loginctl enable-linger dev
  docker exec "$CONTAINER_NAME" systemctl start "user@${dev_uid}.service"
  docker exec "$CONTAINER_NAME" test -S "/run/user/${dev_uid}/bus"
  docker exec "$CONTAINER_NAME" install -d -m 0755 /run/sshd
}

run_sandbox_profile() {
  local profile=$1 docker_mode=$2
  start_systemd_container
  container_exec_dev "cd /repo && bash scripts/bootstrap.sh --platform ubuntu --profile $profile --no-gui --docker-mode $docker_mode --plan --strict"
  evidence_step plan
  container_exec_dev "cd /repo && bash scripts/bootstrap.sh --platform ubuntu --profile $profile --no-gui --docker-mode $docker_mode --apply --strict"
  evidence_step apply
  container_exec_dev "cd /repo && RLDYOUR_PROFILE=$profile RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=$docker_mode bash scripts/ubuntu/verify.sh --strict"
  evidence_step strict_verify
  container_exec_dev "cd /repo && bash scripts/bootstrap.sh --platform ubuntu --profile $profile --no-gui --docker-mode $docker_mode --apply --strict"
  evidence_step repeat_apply
  container_exec_dev "cd /repo && RLDYOUR_PROFILE=$profile RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=$docker_mode bash scripts/ubuntu/verify.sh --strict"
  evidence_step repeat_strict_verify
}

run_sandbox_hardening() {
  start_systemd_container
  docker exec "$CONTAINER_NAME" bash -lc \
    'install -d -m 0700 -o dev -g dev /home/dev/.ssh; ssh-keygen -q -t ed25519 -N "" -f /home/dev/.ssh/evidence; cat /home/dev/.ssh/evidence.pub >/home/dev/.ssh/authorized_keys; chown dev:dev /home/dev/.ssh/authorized_keys; chmod 0600 /home/dev/.ssh/authorized_keys'
  container_exec_dev "cd /repo && SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 22' RLDYOUR_SERVER_SSH_USER=dev bash scripts/bootstrap.sh --platform ubuntu --profile server --no-gui --docker-mode none --harden-ssh --enable-ufw --with-fail2ban --plan --strict"
  evidence_step plan
  container_exec_dev "cd /repo && SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 22' RLDYOUR_SERVER_SSH_USER=dev bash scripts/bootstrap.sh --platform ubuntu --profile server --no-gui --docker-mode none --harden-ssh --enable-ufw --with-fail2ban --apply --strict"
  evidence_step apply
  container_exec_dev "cd /repo && RLDYOUR_PROFILE=server RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=none bash scripts/ubuntu/verify.sh --strict"
  evidence_step strict_verify
  container_exec_dev "cd /repo && RLDYOUR_SERVER_SSH_MATCH_ADDRESS=192.0.2.10 RLDYOUR_SERVER_SSH_LOCAL_ADDRESS=192.0.2.20 bash scripts/ubuntu/verify-server.sh --docker-mode none --expect-ufw --expect-ssh-hardening --expect-fail2ban --ssh-port 22 --ssh-user dev"
  evidence_step server_verify
}

assert_exact_source
record_metadata
trap finalize_evidence EXIT

case "$LANE" in
  macos-gui) run_native_macos --gui ;;
  macos-no-gui) run_native_macos --no-gui ;;
  ubuntu-desktop-no-gui) run_native_ubuntu_desktop ;;
  ubuntu-arm-gui-refusal) run_arm_gui_refusal ;;
  sandbox-desktop-builds-rootful) run_sandbox_profile desktop-builds rootful ;;
  sandbox-server-none) run_sandbox_profile server none ;;
  sandbox-server-rootful) run_sandbox_profile server rootful ;;
  sandbox-server-rootless) run_sandbox_profile server rootless ;;
  sandbox-server-hardening) run_sandbox_hardening ;;
  *) echo "unknown evidence lane: $LANE" >&2; exit 2 ;;
esac

printf 'PASS\n' >"$OUTPUT_DIR/result"
