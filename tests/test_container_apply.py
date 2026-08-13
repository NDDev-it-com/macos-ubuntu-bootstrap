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
