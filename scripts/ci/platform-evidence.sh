#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LANE="${1:?usage: platform-evidence.sh LANE OUTPUT_DIR}"
OUTPUT_DIR="${2:?usage: platform-evidence.sh LANE OUTPUT_DIR}"
EVIDENCE_SHA="${EVIDENCE_SHA:?EVIDENCE_SHA is required}"
EVIDENCE_STARTED_EPOCH="$(date +%s)"
CONTAINER_NAME=""

mkdir -p "$OUTPUT_DIR"
LOG="$OUTPUT_DIR/run.log"
exec > >(tee "$LOG") 2>&1

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
})
sys.path.insert(0, str(Path(os.environ["EVIDENCE_SUPPORT_SCRIPT"]).parent))
import support_evidence
support_evidence.finalize_evidence(payload, payload["result"])
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
  bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --profile desktop "$gui_flag" --apply --strict
  RLDYOUR_GUI_ENABLED="$gui_enabled" bash "$REPO_ROOT/scripts/macos/verify.sh" "${verify_args[@]}"
  bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --profile desktop "$gui_flag" --apply --strict
  RLDYOUR_GUI_ENABLED="$gui_enabled" bash "$REPO_ROOT/scripts/macos/verify.sh" "${verify_args[@]}"
}

run_native_ubuntu_desktop() {
  [ "$(uname -s)" = Linux ]
  ensure_native_ubuntu_user
  native_ubuntu_cmd "bash scripts/bootstrap.sh --platform ubuntu --profile desktop --no-gui --plan --strict"
  native_ubuntu_cmd "bash scripts/bootstrap.sh --platform ubuntu --profile desktop --no-gui --apply --strict"
  native_ubuntu_cmd "RLDYOUR_PROFILE=desktop RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=none bash scripts/ubuntu/verify.sh --strict"
  native_ubuntu_cmd "bash scripts/bootstrap.sh --platform ubuntu --profile desktop --no-gui --apply --strict"
  native_ubuntu_cmd "RLDYOUR_PROFILE=desktop RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=none bash scripts/ubuntu/verify.sh --strict"
}

run_arm_gui_refusal() {
  [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ]
  local output rc=0
  ensure_native_ubuntu_user
  output="$(native_ubuntu_cmd "bash scripts/bootstrap.sh --platform ubuntu --profile desktop --gui --apply" 2>&1)" || rc=$?
  printf '%s\n' "$output"
  [ "$rc" -eq 2 ]
  grep -Fq "Ubuntu GUI apply requires amd64" <<<"$output"
  [ ! -e /home/rldyourevidence/.config/rldyour ]
  [ ! -e /home/rldyourevidence/.local/share/rldyour ]
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
    /usr/share/polkit-1 /usr/share/polkit-1/actions
  sudo chmod 0755 /usr/local /usr/local/share /usr/local/libexec \
    /usr/share/polkit-1 /usr/share/polkit-1/actions
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
  local image="rldyour-evidence-systemd:24.04"
  docker build --tag "$image" - <<'DOCKERFILE'
FROM ubuntu:24.04
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
  local ready=0
  for _ in {1..30}; do
    if docker exec "$CONTAINER_NAME" systemctl is-system-running --quiet 2>/dev/null; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || {
    docker logs "$CONTAINER_NAME"
    docker exec "$CONTAINER_NAME" systemctl --failed || true
    return 1
  }
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
  container_exec_dev "cd /repo && bash scripts/bootstrap.sh --platform ubuntu --profile $profile --no-gui --docker-mode $docker_mode --apply --strict"
  container_exec_dev "cd /repo && RLDYOUR_PROFILE=$profile RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=$docker_mode bash scripts/ubuntu/verify.sh --strict"
  container_exec_dev "cd /repo && bash scripts/bootstrap.sh --platform ubuntu --profile $profile --no-gui --docker-mode $docker_mode --apply --strict"
  container_exec_dev "cd /repo && RLDYOUR_PROFILE=$profile RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=$docker_mode bash scripts/ubuntu/verify.sh --strict"
}

run_sandbox_hardening() {
  start_systemd_container
  docker exec "$CONTAINER_NAME" bash -lc \
    'install -d -m 0700 -o dev -g dev /home/dev/.ssh; ssh-keygen -q -t ed25519 -N "" -f /home/dev/.ssh/evidence; cat /home/dev/.ssh/evidence.pub >/home/dev/.ssh/authorized_keys; chown dev:dev /home/dev/.ssh/authorized_keys; chmod 0600 /home/dev/.ssh/authorized_keys'
  container_exec_dev "cd /repo && SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 22' RLDYOUR_SERVER_SSH_USER=dev bash scripts/bootstrap.sh --platform ubuntu --profile server --no-gui --docker-mode none --harden-ssh --enable-ufw --with-fail2ban --plan --strict"
  container_exec_dev "cd /repo && SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 22' RLDYOUR_SERVER_SSH_USER=dev bash scripts/bootstrap.sh --platform ubuntu --profile server --no-gui --docker-mode none --harden-ssh --enable-ufw --with-fail2ban --apply --strict"
  container_exec_dev "cd /repo && RLDYOUR_PROFILE=server RLDYOUR_GUI_ENABLED=0 RLDYOUR_DOCKER_MODE=none bash scripts/ubuntu/verify.sh --strict"
  container_exec_dev "cd /repo && RLDYOUR_SERVER_SSH_MATCH_ADDRESS=192.0.2.10 RLDYOUR_SERVER_SSH_LOCAL_ADDRESS=192.0.2.20 bash scripts/ubuntu/verify-server.sh --docker-mode none --expect-ufw --expect-ssh-hardening --expect-fail2ban --ssh-port 22 --ssh-user dev"
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
