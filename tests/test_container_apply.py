"""Real apply-time evidence for the Ubuntu paths, inside a disposable container.

The deterministic suites elsewhere prove logic against stubs. They cannot prove
that an install branch works against a real apt, a real dpkg and a real vendor
package -- and the branches that had never once been executed are exactly where
this session found defects (a URL pattern that missed the device's own source,
a `grep` that aborted the verifier under `pipefail`).

This lane closes that gap for the paths a container can host. It does not
replace the deterministic tests and it is not a substitute for a VM: anything
needing systemd, a GNOME session, or macOS is still out of reach and is named
as such rather than quietly skipped.

Run it explicitly, because each case pulls packages and takes minutes:

    RLDYOUR_CONTAINER_TESTS=1 python3 -m pytest tests/test_container_apply.py
"""

from __future__ import annotations

import os
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "ubuntu:26.04"
CHROME_FINGERPRINT = next(
    item for item in json.loads((ROOT / "config/rldyour-contract.json").read_text())["ubuntu_apt_packages"]["desktop_apps"]
    if item["name"] == "google-chrome-stable"
)["apt_source"]["key_fingerprint"]

_OPT_IN = os.environ.get("RLDYOUR_CONTAINER_TESTS") == "1"
_DOCKER = shutil.which("docker")


def _docker_usable() -> bool:
    if not _DOCKER:
        return False
    probe = subprocess.run(
        [_DOCKER, "info"], capture_output=True, text=True, check=False, timeout=60
    )
    return probe.returncode == 0


requires_container = pytest.mark.skipif(
    not _OPT_IN or not _docker_usable(),
    reason=(
        "real-target lane: set RLDYOUR_CONTAINER_TESTS=1 and provide a reachable "
        "Docker daemon to run the apply paths against a real Ubuntu 26.04"
    ),
)

# Everything a desktop step touches before it reaches its own logic. Installed
# once per case so a failure is attributable to the step, not to the fixture.
PRELUDE = """
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends curl gpg ca-certificates sudo >/dev/null
useradd -m -s /bin/bash dev
echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev
cd /repo
install -d -m 0755 /usr/local/libexec /usr/local/share/rldyour-bootstrap
install -m 0755 scripts/ubuntu/privileged-helper.sh /usr/local/libexec/rldyour-bootstrap-privileged
install -m 0644 config/rldyour-contract.json /usr/local/share/rldyour-bootstrap/rldyour-contract.json
"""


def run_in_container(script: str, *, timeout: int = 900) -> subprocess.CompletedProcess[str]:
    assert _DOCKER
    return subprocess.run(
        [
            _DOCKER, "run", "--rm",
            "-v", f"{ROOT}:/repo:ro",
            IMAGE, "bash", "-c", PRELUDE + script,
        ],
        capture_output=True, text=True, check=False, timeout=timeout,
    )


@requires_container
def test_fresh_chrome_install_owns_its_source_and_the_vendor_adds_none() -> None:
    """The branch this desktop could never exercise, because it already had
    Chrome. It is also the branch carrying the design bet: setting the vendor's
    own `repo_add_once=false` before installing must stop the package's postinst
    from adding a second source for the same repository."""
    result = run_in_container(
        """
        test ! -e /etc/default/google-chrome
        ! ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi google

        /usr/local/libexec/rldyour-bootstrap-privileged ubuntu-desktop-gui-system

        gpg --batch --show-keys --with-colons /etc/apt/keyrings/rldyour-google-chrome.asc \
          | awk -F: '$1=="pub"{c++;a=1;next} $1=="fpr"&&a{f=toupper($10);a=0}
                     END{ if (c==1) print "FPR=" f }'
        grep -q 'Signed-By: /etc/apt/keyrings/rldyour-google-chrome.asc' \
          /etc/apt/sources.list.d/rldyour-google-chrome.sources && echo SOURCE_OK
        grep -q 'repo_add_once="false"' /etc/default/google-chrome && echo OPTOUT_OK
        dpkg-query -W -f='${Status}' google-chrome-stable | grep -q 'install ok installed' \
          && echo INSTALLED_OK
        competing=$(grep -rlF 'dl.google.com/linux/chrome' \
          /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v rldyour- || true)
        [ -z "$competing" ] && echo NO_COMPETING_SOURCE || echo "COMPETING=$competing"

        /usr/local/libexec/rldyour-bootstrap-privileged ubuntu-desktop-gui-system
        echo IDEMPOTENT_OK
        """
    )
    combined = result.stdout + result.stderr
    assert f"FPR={CHROME_FINGERPRINT}" in combined, combined[-3000:]
    for marker in ("SOURCE_OK", "OPTOUT_OK", "INSTALLED_OK", "NO_COMPETING_SOURCE", "IDEMPOTENT_OK"):
        assert marker in combined, f"{marker} missing\n{combined[-3000:]}"
    assert result.returncode == 0, combined[-3000:]


@requires_container
def test_fresh_chrome_install_refuses_a_key_that_does_not_verify() -> None:
    """A contract with the wrong trust root must stop before apt-source publish."""
    result = run_in_container(
        """
        python3 - <<'PY'
import json
p='/usr/local/share/rldyour-bootstrap/rldyour-contract.json'
d=json.load(open(p)); next(x for x in d['ubuntu_apt_packages']['desktop_apps'] if x['name']=='google-chrome-stable')['apt_source']['key_fingerprint']='0'*40
open(p,'w').write(json.dumps(d))
PY
        /usr/local/libexec/rldyour-bootstrap-privileged ubuntu-desktop-gui-system \
          && echo UNEXPECTED_SUCCESS || echo REFUSED

        test ! -e /etc/apt/sources.list.d/rldyour-google-chrome.sources && echo NO_SOURCE_WRITTEN
        dpkg-query -W -f='${Status}' google-chrome-stable 2>/dev/null | \
          grep -q 'install ok installed' && echo UNEXPECTED_INSTALL || echo NOT_INSTALLED
        """
    )
    combined = result.stdout + result.stderr
    assert "REFUSED" in combined, combined[-3000:]
    assert "NO_SOURCE_WRITTEN" in combined, "a rejected key must leave no apt source behind"
    assert "NOT_INSTALLED" in combined


@requires_container
def test_pinned_deb_installs_from_its_declared_digest() -> None:
    """RustDesk is the other install branch that had never been executed."""
    result = run_in_container(
        """
        /usr/local/libexec/rldyour-bootstrap-privileged ubuntu-desktop-gui-system
        dpkg-query -W -f='${Version}' rustdesk | grep -q '1.4.9' && echo VERSION_OK
        su dev -c 'cd /repo && source scripts/ubuntu/desktop.sh &&
                   nddev::_record() { :; } && nddev::_install_desktop_deb rustdesk' \
          | grep -q 'installed' && echo IDEMPOTENT_OK
        """
    )
    combined = result.stdout + result.stderr
    for marker in ("VERSION_OK", "IDEMPOTENT_OK"):
        assert marker in combined, f"{marker} missing\n{combined[-3000:]}"
    assert result.returncode == 0, combined[-3000:]


@requires_container
def test_pinned_deb_refuses_a_digest_mismatch() -> None:
    """A tampered artifact must never reach dpkg."""
    result = run_in_container(
        """
        python3 - <<'PY'
import json
p='/usr/local/share/rldyour-bootstrap/rldyour-contract.json'
d=json.load(open(p)); next(x for x in d['ubuntu_apt_packages']['desktop_apps'] if x['name']=='rustdesk')['sha256']['x64']='0'*64
open(p,'w').write(json.dumps(d))
PY
        /usr/local/libexec/rldyour-bootstrap-privileged ubuntu-desktop-gui-system \
          && echo UNEXPECTED_SUCCESS || echo REFUSED
        dpkg-query -W rustdesk 2>/dev/null && echo UNEXPECTED_INSTALL || echo NOT_INSTALLED
        """
    )
    combined = result.stdout + result.stderr
    assert "REFUSED" in combined, combined[-3000:]
    assert "NOT_INSTALLED" in combined, "a digest mismatch must never reach dpkg"


# --------------------------------------------------------------------------
# Privileged descendant supervision (#64)
#
# `timeout --foreground` bounded nothing: GNU coreutils documents that mode as
# "children of COMMAND will not be timed out", and its signal goes to a setuid
# pkexec the unprivileged launcher may not signal anyway. The guarantee now
# lives in the helper, which is root and owns its process group.
#
# This is a real-process test on purpose. Every defect the implementation had --
# an enumeration that counted its own pipeline, a group signal that would have
# killed the helper mid-cleanup, `kill -- -1` meaning "every process" when the
# helper is PID 1, and a bare `wait` blocking on a process in another group --
# was invisible to static reading and obvious to a container.
# --------------------------------------------------------------------------

SUPERVISOR_HARNESS = r"""
set -uo pipefail
result() { printf 'RLDYOUR_PRIVILEGE_RESULT=%s operation=%s\n' "$1" "${2:-redacted}" >&2; }
# Source only the supervisor primitives from the real helper, so this exercises
# shipped code rather than a copy of it.
eval "$(sed -n '/^readonly RLDYOUR_TERM_GRACE_SECONDS/,/^on_exit() {$/p' \
  /repo/scripts/ubuntu/privileged-helper.sh | sed '$d')"

if [ -z "${RLDYOUR_HARNESS_SETSID:-}" ] && ! own_process_group; then
  RLDYOUR_HARNESS_SETSID=1 exec setsid --wait bash "$0" "$@"
fi

setsid sleep 600 & UNRELATED=$!        # different session: must be preserved
sleep 0.3
( sleep 600 ) &                        # child
( ( sleep 600 ) & sleep 600 ) &        # child and grandchild
( trap '' TERM; sleep 600 ) &          # ignores TERM: must be escalated to KILL
sleep 0.5

scan_residual
echo "members_before=${#RLDYOUR_RESIDUAL[@]}"
start=$(date +%s)
terminate_descendants
echo "terminate_rc=$?"
echo "elapsed=$(( $(date +%s) - start ))"
scan_residual
echo "members_after=${#RLDYOUR_RESIDUAL[@]}"
if kill -0 "$UNRELATED" 2>/dev/null; then echo "unrelated=alive"; else echo "unrelated=killed"; fi
echo "zombies=$(ps -o stat= --ppid $$ 2>/dev/null | grep -c '^Z' || true)"
kill -9 "$UNRELATED" 2>/dev/null || true
"""


@requires_container
def test_privileged_descendants_are_bounded_without_touching_anything_else() -> None:
    script = (
        "set -eu\nexport DEBIAN_FRONTEND=noninteractive\n"
        "apt-get update -qq >/dev/null\n"
        "apt-get install -y -qq --no-install-recommends procps util-linux >/dev/null\n"
        "cat > /tmp/harness.sh <<'HARNESS'\n" + SUPERVISOR_HARNESS + "HARNESS\n"
        "timeout 120 bash /tmp/harness.sh\n"
    )
    completed = subprocess.run(
        [_DOCKER, "run", "--rm", "-v", f"{ROOT}:/repo:ro", "-w", "/repo", IMAGE,
         "bash", "-c", script],
        capture_output=True, text=True, check=False, timeout=900,
    )
    output = completed.stdout + completed.stderr
    assert completed.returncode == 0, output

    values = dict(
        line.split("=", 1)
        for line in completed.stdout.splitlines()
        if "=" in line and not line.startswith("RLDYOUR_")
    )

    # Four descendants existed: child, child, grandchild, TERM-ignoring child.
    assert int(values["members_before"]) >= 4, output
    # All of them are gone, including the one that ignored TERM.
    assert values["members_after"] == "0", output
    assert values["terminate_rc"] == "0", output
    # The escalation is bounded by the grace period, not open-ended.
    assert int(values["elapsed"]) <= 20, output
    # A process in another session is never signalled.
    assert values["unrelated"] == "alive", output
    # Everything signalled is reaped.
    assert values["zombies"] == "0", output


@requires_container
def test_the_supervisor_never_signals_every_process_when_it_is_pid_one() -> None:
    """`kill -- -1` is "every process the caller may signal", not "group 1".

    A root helper is PID 1 inside a container and can be inside a namespace, so
    a group signal spelled `-$$` would have signalled the whole namespace. The
    guard is that `own_process_group` refuses PID 1, which forces main() to
    re-execute under setsid and obtain a group of its own.
    """
    script = (
        "set -eu\nexport DEBIAN_FRONTEND=noninteractive\n"
        "apt-get update -qq >/dev/null\n"
        "apt-get install -y -qq --no-install-recommends procps >/dev/null\n"
        "eval \"$(sed -n '/^readonly RLDYOUR_TERM_GRACE_SECONDS/,/^on_exit() {$/p' "
        "/repo/scripts/ubuntu/privileged-helper.sh | sed '$d')\"\n"
        "echo \"pid=$$\"\n"
        "if own_process_group; then echo 'own_group=yes'; else echo 'own_group=no'; fi\n"
    )
    completed = subprocess.run(
        [_DOCKER, "run", "--rm", "-v", f"{ROOT}:/repo:ro", "-w", "/repo", IMAGE,
         "bash", "-c", script],
        capture_output=True, text=True, check=False, timeout=600,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "pid=1" in completed.stdout, completed.stdout
    assert "own_group=no" in completed.stdout, (
        "own_process_group accepted PID 1; a group signal there means every process"
    )
