"""Ubuntu desktop customization reports a real aggregate result offline."""

from __future__ import annotations

import os
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DESKTOP = ROOT / "scripts/ubuntu/desktop.sh"
INSTALL = ROOT / "scripts/ubuntu/install.sh"
PRIVILEGED_HELPER = ROOT / "scripts/ubuntu/privileged-helper.sh"
VERIFY = ROOT / "scripts/ubuntu/verify.sh"

# Preconditions desktop.sh checks before it does anything. Each stub is the
# smallest program that satisfies the check without touching the real system.
BASE_STUBS: dict[str, str] = {
    "gsettings": '[ "$1" = "list-schemas" ] && '
                 "echo org.gnome.shell.extensions.dash-to-dock\nexit 0\n",
    "localectl": "exit 0\n",
    "sudo": 'while [ "${1:0:1}" = "-" ]; do shift; done\n[ "$#" -eq 0 ] && exit 0\nexec "$@"\n',
    "locale": "echo ru_RU.utf8\n",
    "sed": "exit 0\n",
    "locale-gen": "exit 0\n",
    "dpkg-query": 'case "$*" in *rustdesk*|*google-chrome-stable*) printf "install ok installed\\n" ;; *) exit 1 ;; esac\n',
    "dpkg": "exit 1\n",
    # `snap list firefox >/dev/null 2>&1` discards both streams, so the only
    # way a stub can prove it ran is a side effect on disk.
    "snap": 'touch "$(dirname "$0")/snap-ran"\nexit 1\n',
    "apt-get": "exit 0\n",
    "curl": "exit 0\n",
}


# The package must be reported as absent so the step proceeds past its
# already-installed short circuit, and the download must fail so the test never
# fetches the real artifact.
# `dpkg --print-architecture` must answer here or the .deb step reports
# `skipped` and the test loses its subject. The Chrome step then also attempts
# and fails on a host without Chrome; later independent steps must still run.
DEB_STEP_FAILS: dict[str, str] = {
    "dpkg": '[ "$1" = "--print-architecture" ] && { echo amd64; exit 0; }\nexit 1\n',
    "dpkg-query": "exit 1\n",
    "curl": "exit 1\n",
}


def write_stubs(bin_dir: Path, overrides: dict[str, str] | None = None) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    stubs = {**BASE_STUBS, **(overrides or {})}
    for name, body in stubs.items():
        stub = bin_dir / name
        stub.write_text(f"#!/usr/bin/env bash\n{body}", encoding="utf-8")
        stub.chmod(0o755)
    return bin_dir


def run_desktop(bin_dir: Path) -> subprocess.CompletedProcess[str]:
    harness = r'''
source "$1"
rldyour::privilege::refresh() { return 0; }
RLDYOUR_PRIVILEGE_MODE=root
nddev::desktop_configure
'''
    return subprocess.run(
        ["bash", "-c", harness, "_", str(DESKTOP)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        env={
            **os.environ,
            "RLDYOUR_DRY_RUN": "0",
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        },
    )


def test_all_required_steps_ok_reports_complete(tmp_path: Path) -> None:
    result = run_desktop(write_stubs(tmp_path / "bin"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "desktop customization complete" in result.stdout


def test_failed_deb_step_does_not_skip_the_firefox_step(tmp_path: Path) -> None:
    """The ``die``-inside-``||`` regression: later steps must still run."""
    stubs = write_stubs(tmp_path / "bin", DEB_STEP_FAILS)
    result = run_desktop(stubs)
    combined = result.stdout + result.stderr
    assert (stubs / "snap-ran").exists(), "Firefox removal never ran after the .deb step failed"
    assert "rustdesk: FAILED (required)" in combined
    # google_chrome is required and also fails under these stubs.
    assert result.returncode != 0


def test_required_failure_is_not_reported_as_complete(tmp_path: Path) -> None:
    stubs = write_stubs(tmp_path / "bin", DEB_STEP_FAILS)
    result = run_desktop(stubs)
    combined = result.stdout + result.stderr
    assert "desktop customization incomplete" in combined
    assert "✓ desktop customization complete" not in combined


def test_optional_step_failure_does_not_fail_the_layer(tmp_path: Path) -> None:
    """A cosmetic step must be visible in the report but must not fail apply."""
    stubs = write_stubs(tmp_path / "bin", {"locale": "echo en_US.utf8\n"})
    result = run_desktop(stubs)
    combined = result.stdout + result.stderr
    assert result.returncode == 0
    assert (
        "russian_layout: skipped (precondition absent)" in combined
        or "russian_layout: failed (optional)" in combined
    )


def test_absent_precondition_is_skipped_not_failed(tmp_path: Path) -> None:
    stubs = write_stubs(tmp_path / "bin", {"gsettings": "exit 0\n"})
    result = run_desktop(stubs)
    combined = result.stdout + result.stderr
    assert result.returncode == 0
    assert "gnome_dock: skipped" in combined


# ----------------------------- wiring -----------------------------


def test_no_step_terminates_the_script_instead_of_returning() -> None:
    """``die`` is ``exit``; a step that calls it cannot be made independent."""
    source = DESKTOP.read_text(encoding="utf-8")
    body = source.split("# ----------------------------- GNOME dock", 1)[1]
    offenders = [
        line.strip()
        for line in body.splitlines()
        if "die " in line and not line.strip().startswith("#")
    ]
    assert offenders == [], f"steps must return, not exit: {offenders}"


def test_installer_surfaces_the_desktop_result_instead_of_warning() -> None:
    source = INSTALL.read_text(encoding="utf-8")
    assert "GUI_LAYER_FAILED=1" in source
    assert 'desktop customization reported issues (non-fatal)' not in source
    # The failure is reported at the end of main, so a required GUI failure
    # cannot strand the layers that run after it.
    main = source.split("main() {", 1)[1]
    assert main.index("install_gui_apps") < main.index('if [ "$GUI_LAYER_FAILED" -ne 0 ]')


def test_every_owned_shell_script_is_linted() -> None:
    """lint.sh consumes the validated canonical inventory."""
    lint = (ROOT / "scripts/ci/lint.sh").read_text(encoding="utf-8")
    assert "script_inventory.py\" receipt --gate shellcheck" in lint
    assert "script_inventory.py\" paths --receipt" in lint
    discovered = {
        Path(entry["path"])
        for entry in json.loads(
            (ROOT / "config/script-inventory.json").read_text(encoding="utf-8")
        )["entries"]
        if "shellcheck" in entry["gates"]
    }
    for required in (
        Path("scripts/ubuntu/desktop.sh"),
        Path("scripts/remote-exec.sh"),
    ):
        assert required in discovered
    # The only literal repository script path is the typed inventory launcher;
    # governed ShellCheck subjects are never enumerated in lint.sh itself.
    literals = re.findall(r'\$REPO_ROOT/(scripts/[A-Za-z0-9_./-]+)', lint)
    assert literals == ["scripts/ci/script_inventory.py", "scripts/ci/script_inventory.py"]


@pytest.mark.parametrize(
    "script",
    sorted(str(p.relative_to(ROOT)) for p in (ROOT / "scripts").rglob("*.sh")),
)
def test_discovered_script_passes_syntax_check(script: str) -> None:
    result = subprocess.run(
        ["bash", "-n", str(ROOT / script)], capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stderr


# ----------------------------- Google Chrome -----------------------------
#
# Chrome is the one desktop app deliberately not pinned to a SHA-256: pinning a
# browser to an old build is a security liability. Supply-chain control comes
# from the signing key, so the fingerprint gate is the thing worth testing.

CONTRACT = ROOT / "config/rldyour-contract.json"


def _chrome_contract() -> dict:
    import json

    apps = json.loads(CONTRACT.read_text(encoding="utf-8"))["ubuntu_apt_packages"][
        "desktop_apps"
    ]
    for entry in apps:
        if isinstance(entry, dict) and entry.get("name") == "google-chrome-stable":
            return entry
    raise AssertionError("google-chrome-stable is not declared in desktop_apps")


CHROME_FINGERPRINT = _chrome_contract()["apt_source"]["key_fingerprint"]


def test_contract_declares_chrome_as_key_verified_not_version_pinned() -> None:
    chrome = _chrome_contract()
    assert chrome["version_policy"] == "tracks-stable-channel"
    source = chrome["apt_source"]
    assert source["key_fingerprint"] == CHROME_FINGERPRINT
    assert source["key_url"].startswith("https://dl.google.com/")
    assert source["vendor_repo_add_once"] == "false"
    assert source["vendor_source_policy"] == "preserve-when-key-verifies"


def test_helper_and_verifier_consume_the_contract_without_duplicate_fingerprint() -> None:
    source = PRIVILEGED_HELPER.read_text(encoding="utf-8")
    assert CHROME_FINGERPRINT not in source
    assert 'apps["google-chrome-stable"]["apt_source"]' in source
    verify = (ROOT / "scripts/ubuntu/verify.sh").read_text(encoding="utf-8")
    assert CHROME_FINGERPRINT not in verify
    assert "rldyour-contract.json" in verify


def test_chrome_and_rustdesk_are_required() -> None:
    source = DESKTOP.read_text(encoding="utf-8")
    assert "REQUIRED_STEPS=(google_chrome rustdesk firefox_removal)" in source
    body = source.split("nddev::desktop_configure() {", 1)[1]
    assert "nddev::_step rustdesk nddev::_install_desktop_deb rustdesk" in body
    assert "OPTIONAL_STEPS=(gnome_dock russian_layout)" in source


def _generated_keyring(directory: Path, name: str = "Not Google") -> Path:
    """Create a throwaway armoured keyring holding exactly one primary key."""
    directory.mkdir(parents=True, exist_ok=True)
    gnupg = directory / "gnupg"
    gnupg.mkdir(mode=0o700, exist_ok=True)
    batch = directory / "batch"
    batch.write_text(
        "%no-protection\nKey-Type: eddsa\nKey-Curve: ed25519\n"
        f"Name-Real: {name}\nName-Email: nobody@example.invalid\n%commit\n",
        encoding="utf-8",
    )
    generated = subprocess.run(
        ["gpg", "--batch", "--homedir", str(gnupg), "--gen-key", str(batch)],
        capture_output=True, text=True, check=False,
    )
    if generated.returncode != 0:
        pytest.skip(f"gpg could not generate a test key: {generated.stderr[:200]}")
    exported = subprocess.run(
        ["gpg", "--batch", "--homedir", str(gnupg), "--armor", "--export"],
        capture_output=True, check=False,
    )
    keyring = directory / "keyring.asc"
    keyring.write_bytes(exported.stdout)
    return keyring


def _extract(function: str, path: Path) -> str:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    out, inside = [], False
    for line in lines:
        if line.startswith(f"{function}()"):
            inside = True
        if inside:
            out.append(line)
            if line.rstrip() == "}":
                break
    assert out, f"{function} not found in {path}"
    return "".join(out)


def test_chrome_key_gate_rejects_a_foreign_key(tmp_path: Path) -> None:
    """A key that is not Google's must never satisfy the gate."""
    gnupg = tmp_path / "gnupg"
    gnupg.mkdir(mode=0o700)
    batch = tmp_path / "batch"
    batch.write_text(
        "%no-protection\nKey-Type: eddsa\nKey-Curve: ed25519\n"
        "Name-Real: Not Google\nName-Email: nobody@example.invalid\n%commit\n",
        encoding="utf-8",
    )
    generated = subprocess.run(
        ["gpg", "--batch", "--homedir", str(gnupg), "--gen-key", str(batch)],
        capture_output=True, text=True, check=False,
    )
    if generated.returncode != 0:
        pytest.skip(f"gpg could not generate a test key: {generated.stderr[:200]}")
    foreign = tmp_path / "foreign.asc"
    exported = subprocess.run(
        ["gpg", "--batch", "--homedir", str(gnupg), "--armor", "--export"],
        capture_output=True, check=False,
    )
    foreign.write_bytes(exported.stdout)

    result = subprocess.run(
        ["bash", "-c",
         'source "$1"; chrome_key_matches "$2" "$3"', "_", str(PRIVILEGED_HELPER),
         str(foreign), CHROME_FINGERPRINT],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0, "a foreign signing key was accepted"


def test_chrome_key_acceptance_is_contract_owned_and_rejects_override() -> None:
    helper = PRIVILEGED_HELPER.read_text(encoding="utf-8")
    install = helper.split("install_chrome() {", 1)[1].split("\n}", 1)[0]
    matcher = helper.split("chrome_key_matches() {", 1)[1].split("\n}", 1)[0]
    assert 'chrome_key_matches "$tmp_dir/chrome-key" "$fingerprint"' in install
    assert 'observed=$(chrome_key_fingerprint "$key")' in matcher
    assert '[ "$observed" = "$expected" ]' in matcher
    assert CHROME_FINGERPRINT not in helper


def test_chrome_key_gate_rejects_a_missing_keyring(tmp_path: Path) -> None:
    """The privileged helper's gate must fail closed on an absent keyring."""
    result = subprocess.run(
        ["bash", "-c",
         'source "$1"; chrome_key_fingerprint "$2"',
         "_", str(PRIVILEGED_HELPER), str(tmp_path / "absent.asc")],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0, "a missing keyring produced a fingerprint"


def test_verifier_chrome_gate_accepts_only_its_own_keyring(tmp_path: Path) -> None:
    """Execute the verifier's gate; do not assert on its source text.

    The gate this replaces was unexecutable -- its escaped quotes reached awk
    verbatim inside a double-quoted command substitution -- and the only test
    that touched it asserted on a neighbouring line, so nothing observed the
    failure.
    """
    keyring = _generated_keyring(tmp_path)
    observed = subprocess.run(
        ["bash", "-c",
         'set -euo pipefail\n'
         f'source "{ROOT}/scripts/lib/common.sh"\n'
         'rldyour::gpg_primary_fingerprint "$1"', "_", str(keyring)],
        capture_output=True, text=True, check=False,
    )
    assert observed.returncode == 0, observed.stderr
    fingerprint = observed.stdout.strip()
    assert re.fullmatch(r"[0-9A-F]{40}", fingerprint), fingerprint

    gate = _extract("rldyour::ubuntu_verify::chrome_key_trusted", VERIFY)

    def run(expected: str) -> int:
        return subprocess.run(
            ["bash", "-c",
             'set -euo pipefail\n'
             f'source "{ROOT}/scripts/lib/common.sh"\n'
             f'{gate}\n'
             'rldyour::ubuntu_verify::chrome_key_trusted "$1" "$2"',
             "_", str(keyring), expected],
            capture_output=True, text=True, check=False,
        ).returncode

    assert run(fingerprint) == 0, "the verifier rejected its own keyring"
    assert run(CHROME_FINGERPRINT) != 0, "the verifier accepted a foreign fingerprint"


def test_verifier_chrome_gate_rejects_a_keyring_with_a_second_primary_key(
    tmp_path: Path,
) -> None:
    """A keyring that also carries an unrelated primary key is not the vendor.

    The previous check counted matching fingerprint lines, so a keyring holding
    Google's key alongside an attacker's satisfied it.
    """
    first = _generated_keyring(tmp_path / "a", name="First Key")
    second = _generated_keyring(tmp_path / "b", name="Second Key")
    combined = tmp_path / "combined.asc"
    combined.write_bytes(first.read_bytes() + second.read_bytes())
    result = subprocess.run(
        ["bash", "-c",
         'set -euo pipefail\n'
         f'source "{ROOT}/scripts/lib/common.sh"\n'
         'rldyour::gpg_primary_fingerprint "$1"', "_", str(combined)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0, "a two-primary-key keyring was treated as one identity"


def test_chrome_key_gate_rejects_multiple_primary_keys(tmp_path: Path) -> None:
    gnupg = tmp_path / "gnupg"
    gnupg.mkdir(mode=0o700)
    for index in (1, 2):
        batch = tmp_path / f"batch-{index}"
        batch.write_text(
            "%no-protection\nKey-Type: eddsa\nKey-Curve: ed25519\n"
            f"Name-Real: Foreign {index}\nName-Email: foreign-{index}@example.invalid\n%commit\n",
            encoding="utf-8",
        )
        generated = subprocess.run(
            ["gpg", "--batch", "--homedir", str(gnupg), "--gen-key", str(batch)],
            capture_output=True, text=True, check=False,
        )
        if generated.returncode != 0:
            pytest.skip(f"gpg could not generate test keys: {generated.stderr[:200]}")
    combined = tmp_path / "multiple.asc"
    exported = subprocess.run(
        ["gpg", "--batch", "--homedir", str(gnupg), "--armor", "--export"],
        capture_output=True, check=False,
    )
    combined.write_bytes(exported.stdout)
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; chrome_key_fingerprint "$2"', "_", str(PRIVILEGED_HELPER), str(combined)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0


def test_verifier_fails_typed_when_no_chrome_source_is_installed(tmp_path: Path) -> None:
    """The structured consumer owns absence handling; no shell grep model remains."""
    empty_sources = tmp_path / "sources.list.d"
    empty_sources.mkdir()
    result = subprocess.run(
        [sys.executable, "-I", str(ROOT / "scripts/ci/shell_contract.py"), "chrome-runtime",
         "--contract", str(CONTRACT), "--source", str(empty_sources)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 3
    assert result.stdout == ""
    assert result.stderr == "shell-contract: Chrome apt source identity or binding is invalid\n"
    verify = (ROOT / "scripts/ubuntu/verify.sh").read_text(encoding="utf-8")
    docs = (ROOT / "docs/reference/source-register.md").read_text(encoding="utf-8")
    assert "--require-root-owned-contract" in verify
    assert 'rldyour::log "missing" "valid Chrome source and trust contract"' in verify
    normalized_docs = " ".join(docs.split())
    assert "typed exit 3" in normalized_docs and "no accepted installed source" in normalized_docs
    stale = "chrome_" + "source="
    tests = Path(__file__).read_text(encoding="utf-8")
    assert stale not in verify and stale not in docs and stale not in tests


def test_both_google_repository_paths_are_recognised(tmp_path: Path) -> None:
    """Google's cron writes linux/chrome/deb; repolib writes
    linux/chrome-stable/deb. Matching only the former left a real device's
    source invisible to both the installer and the verifier."""
    chrome = _chrome_contract()["apt_source"]
    assert chrome["uri"] == "https://dl.google.com/linux/chrome/deb/"
    helper = PRIVILEGED_HELPER.read_text(encoding="utf-8")
    verifier = (ROOT / "scripts/ubuntu/verify.sh").read_text(encoding="utf-8")
    desktop = DESKTOP.read_text(encoding="utf-8")
    assert 'chrome["uri"]' in helper
    assert "shell_contract.py" in verifier and "chrome-runtime" in verifier
    assert chrome["uri"] not in desktop
    assert chrome["key_fingerprint"] not in desktop
    identities = chrome["accepted_source_identities"]
    assert identities == [
        {"scheme": "https", "host": "dl.google.com", "path": "/linux/chrome/deb"},
        {"scheme": "https", "host": "dl.google.com", "path": "/linux/chrome-stable/deb"},
    ]
    for index, identity in enumerate(identities):
        source = tmp_path / f"chrome-{index}.list"
        source.write_text(
            "deb [arch=amd64 signed-by=/etc/apt/keyrings/rldyour-google-chrome.asc] "
            f"{identity['scheme']}://{identity['host']}{identity['path']}/ stable main\n",
            encoding="utf-8",
        )
        result = subprocess.run(
            [sys.executable, "-I", str(ROOT / "scripts/ci/shell_contract.py"), "chrome-runtime",
             "--contract", str(CONTRACT), "--source", str(source)],
            capture_output=True, text=True, check=False,
        )
        assert result.returncode == 0, result.stderr
        observed = json.loads(result.stdout)["result"]
        assert observed["fingerprint"] == CHROME_FINGERPRINT
        assert observed["matched_identities"] == [[identity["scheme"], identity["host"], identity["path"]]]


@pytest.mark.parametrize("uri", [
    "http://dl.google.com/linux/chrome/deb/",
    "https://dl.google.com.evil.invalid/linux/chrome/deb/",
    "https://evil.invalid/dl.google.com/linux/chrome/deb/",
    "https://user@dl.google.com/linux/chrome/deb/",
    "https://dl.google.com:443/linux/chrome/deb/",
    "https://dl.google.com/linux/chrome/deb.evil/",
    "https://dl.google.com/linux/chrome/deb/?query=1",
    "https://dl.google.com/linux/chrome/deb/#fragment",
])
def test_chrome_source_authority_rejects_lookalikes(tmp_path: Path, uri: str) -> None:
    source = tmp_path / "chrome.list"
    source.write_text(
        "deb [arch=amd64 signed-by=/etc/apt/keyrings/rldyour-google-chrome.asc] "
        f"{uri} stable main\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, "-I", str(ROOT / "scripts/ci/shell_contract.py"), "chrome-runtime",
         "--contract", str(CONTRACT), "--source", str(source)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 3


def test_chrome_source_authority_accepts_deb822_and_rejects_binding_drift(tmp_path: Path) -> None:
    source = tmp_path / "chrome.sources"
    valid = (
        "Types: deb\nURIs: https://dl.google.com/linux/chrome-stable/deb/\n"
        "Suites: stable\nComponents: main\nArchitectures: amd64\n"
        "Signed-By: /etc/apt/keyrings/rldyour-google-chrome.asc\n"
    )
    command = [
        sys.executable, "-I", str(ROOT / "scripts/ci/shell_contract.py"), "chrome-runtime",
        "--contract", str(CONTRACT), "--source", str(source),
    ]
    source.write_text(valid, encoding="utf-8")
    accepted = subprocess.run(command, capture_output=True, text=True, check=False)
    assert accepted.returncode == 0, accepted.stderr
    for old, new in (
        ("Suites: stable", "Suites: testing"),
        ("Components: main", "Components: contrib"),
        ("Architectures: amd64", "Architectures: arm64"),
        ("rldyour-google-chrome.asc", "unmanaged-google.asc"),
        ("Types: deb", "Types: deb-src"),
    ):
        source.write_text(valid.replace(old, new), encoding="utf-8")
        refused = subprocess.run(command, capture_output=True, text=True, check=False)
        assert refused.returncode == 3, (old, new, refused.stdout, refused.stderr)


# ------------------- privileged .deb ownership -------------------


def test_rustdesk_identity_has_one_contract_owner() -> None:
    source = DESKTOP.read_text(encoding="utf-8")
    helper = PRIVILEGED_HELPER.read_text(encoding="utf-8")
    assert "REQUIRED_DESKTOP_PACKAGES" not in source
    assert "rustdesk/releases/download" not in source
    apps = json.loads(CONTRACT.read_text(encoding="utf-8"))["ubuntu_apt_packages"]["desktop_apps"]
    rustdesk = next(item for item in apps if item["name"] == "rustdesk")
    assert all(value.startswith("https://") for value in rustdesk["url"].values())
    assert all(re.fullmatch(r"[0-9a-f]{64}", value) for value in rustdesk["sha256"].values())
    assert 'rustdesk = apps["rustdesk"]' in helper
    assert 'nddev::_install_desktop_deb rustdesk' in source


def test_unknown_required_desktop_package_is_refused(tmp_path: Path) -> None:
    prelude = tmp_path / "prelude.sh"
    call = tmp_path / "call.sh"
    prelude.write_text('info(){ :; }; ok(){ :; }; warn(){ printf "%s\\n" "$*"; }\n', encoding="utf-8")
    call.write_text("nddev::_install_desktop_deb nonesuch\n", encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts/ci/shell_function_harness.py"), "run",
         "--source", str(DESKTOP), "--function", "nddev::_install_desktop_deb",
         "--prelude", str(prelude), "--call", str(call)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stderr
    observed = json.loads(result.stdout)["result"]
    assert observed["returncode"] != 0
    assert "unknown required desktop package" in observed["stdout"]


# ------------------- macOS: an optional layer cannot strand the rest -------------------
#
# macos/install.sh runs the GUI cask layer before the AI CLI layer.
# The loop used to call ensure_cask bare under `set -euo pipefail`, so one
# unavailable cask aborted the script and took the language servers, the
# AI CLI layer and verification with it. This is
# the failure this repository already fixed twice on the Ubuntu side.

MACOS_INSTALL = ROOT / "scripts/macos/install.sh"


def test_macos_gui_layer_attempts_every_cask() -> None:
    source = MACOS_INSTALL.read_text(encoding="utf-8")
    body = source.split("install_gui_apps() {", 1)[1].split("\n}", 1)[0]
    assert "if ! ensure_cask" in body, (
        "a bare ensure_cask under set -e aborts the whole run on the first "
        "failing cask"
    )
    assert "GUI_LAYER_FAILED" in body


def test_macos_gui_failure_is_reported_after_all_install_layers() -> None:
    source = MACOS_INSTALL.read_text(encoding="utf-8")
    main = source.split("main() {", 1)[1]
    gui = main.index("install_gui_apps")
    harnesses = main.index("install_ai_runtimes")
    report = main.index('if [ "$GUI_LAYER_FAILED" -ne 0 ]')
    assert gui < harnesses, "unexpected ordering; re-derive this test"
    assert harnesses < report, (
        "the GUI result must be reported after the mandatory layers have run, "
        "not before them"
    )


def test_macos_gui_failure_still_fails_the_run() -> None:
    """Attempting everything must not become reporting success."""
    source = MACOS_INSTALL.read_text(encoding="utf-8")
    main = source.split("main() {", 1)[1]
    report = main.index('if [ "$GUI_LAYER_FAILED" -ne 0 ]')
    assert "return 1" in main[report : report + 300]


# ------------------- the minimum-version gate must actually gate -------------------
#
# rldyour::require_cmd_min_version is used only by macos/verify.sh, for node,
# uv, bun, starship, atuin, carapace and dart. It returned 0 -- "skipping
# numeric check" -- whenever it could not parse a version, and it discarded
# stderr while doing so. The Ubuntu code documents that `dart --version` printed
# to stderr on older SDKs and reads both streams for that reason, so the macOS
# gate could pass Dart without ever comparing its version.

COMMON = ROOT / "scripts/lib/common.sh"


def _min_version(tool: Path, minimum: str = "1.0") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c",
         f'source "{COMMON}"\nrldyour::require_cmd_min_version {tool.name} {minimum} --version'],
        capture_output=True, text=True, check=False,
        env={**os.environ, "PATH": f"{tool.parent}{os.pathsep}{os.environ['PATH']}"},
    )


def _tool(tmp_path: Path, name: str, body: str) -> Path:
    tool = tmp_path / name
    tool.write_text(f"#!/bin/sh\n{body}", encoding="utf-8")
    tool.chmod(0o755)
    return tool


def test_min_version_accepts_a_current_version(tmp_path: Path) -> None:
    assert _min_version(_tool(tmp_path, "good", 'echo "1.2.3"\n')).returncode == 0


def test_min_version_rejects_an_old_version(tmp_path: Path) -> None:
    assert _min_version(_tool(tmp_path, "old", 'echo "0.9.0"\n')).returncode != 0


def test_min_version_reads_a_version_reported_on_stderr(tmp_path: Path) -> None:
    """The exact shape of `dart --version` on older SDKs."""
    tool = _tool(tmp_path, "stderrtool", 'echo "Dart SDK version: 3.13.0" >&2\n')
    result = _min_version(tool)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "3.13.0" in result.stdout


def test_min_version_fails_closed_when_no_version_can_be_read(tmp_path: Path) -> None:
    """It used to return 0 here, so a broken binary satisfied the gate."""
    result = _min_version(_tool(tmp_path, "silent", "exit 0\n"))
    assert result.returncode != 0, "an unreadable version must not pass a version gate"
    assert "could not detect version" in result.stdout
    assert "skipping numeric check" not in result.stdout


# ------------------- bash 3.2 portability on the macOS path -------------------
#
# macOS still ships bash 3.2. The repository's own lint script used `mapfile`
# and died with "command not found" on the macOS CI lane -- in an adapter whose
# whole purpose is to support both platforms. The lane caught it; nothing local
# did.

# bash 4.0+ only. Each would be a runtime failure on macOS, not a syntax error,
# so `bash -n` does not see them.
BASH4_ONLY = (
    (r"\bmapfile\b", "mapfile is bash 4.0+"),
    (r"\breadarray\b", "readarray is bash 4.0+"),
    (r"declare\s+-A\b", "associative arrays are bash 4.0+"),
    (r"\$\{[A-Za-z_][A-Za-z0-9_]*\^\^", "${var^^} is bash 4.0+"),
    (r"\$\{[A-Za-z_][A-Za-z0-9_]*,,", "${var,,} is bash 4.0+"),
)

# Scripts that execute on macOS: the compositor, the shared library, the macOS
# platform scripts and every repository-level entry point. The ubuntu/ scripts
# are Linux-only and may use bash 4 freely.
SCRIPT_INVENTORY = json.loads(
    (ROOT / "config/script-inventory.json").read_text(encoding="utf-8")
)["entries"]
MACOS_PATH_SCRIPTS = [
    entry["path"] for entry in SCRIPT_INVENTORY if "macos-bash32" in entry["gates"]
]


@pytest.mark.parametrize("script", MACOS_PATH_SCRIPTS)
def test_macos_path_scripts_avoid_bash4_only_features(script: str) -> None:
    path = ROOT / script
    assert path.exists(), f"{script} is listed here but does not exist"
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for pattern, why in BASH4_ONLY:
            assert not re.search(pattern, line), (
                f"{script}:{number} uses a construct macOS bash 3.2 lacks — {why}\n"
                f"  {line.strip()}"
            )


def test_the_macos_path_list_covers_every_applicable_script() -> None:
    assert MACOS_PATH_SCRIPTS
    assert all(
        entry["platform"] != "ubuntu"
        for entry in SCRIPT_INVENTORY
        if "macos-bash32" in entry["gates"]
    )


def test_key_identity_is_one_primitive_with_no_surviving_copies() -> None:
    """Four call sites used to carry four copies of the same awk program.

    One of those copies -- the Ubuntu verifier's -- was written inside a
    double-quoted command substitution, so its escaped quotes reached awk
    verbatim, awk exited 2, and under `set -o pipefail` strict Ubuntu GUI
    verification aborted on every device in every state. The duplication was the
    defect; one primitive is the fix.

    The file list differs from `main`'s version of this test: on this line
    Chrome is installed by the root helper, so `desktop.sh` no longer performs
    key identity at all and `privileged-helper.sh` does.
    """
    library = (ROOT / "scripts/lib/common.sh").read_text(encoding="utf-8")
    assert "rldyour::gpg_primary_fingerprint()" in library

    for relative in (
        "scripts/ubuntu/verify.sh",
        "scripts/ubuntu/server.sh",
        "scripts/ubuntu/verify-server.sh",
    ):
        source = (ROOT / relative).read_text(encoding="utf-8")
        assert "rldyour::gpg_primary_fingerprint" in source, relative
        assert "--show-keys --with-colons" not in source, (
            f"{relative} still carries its own copy of the key-identity program"
        )

    # The privileged helper cannot source the unprivileged library -- it runs as
    # root from a fixed path with a scrubbed environment -- so it carries its
    # own gate. What must not come back is the broken spelling.
    helper = PRIVILEGED_HELPER.read_text(encoding="utf-8")
    assert "chrome_key_fingerprint" in helper
    assert 'awk -F: \'$1 == \\"fpr\\"' not in helper, (
        "the helper regained the escaped-quote awk program that aborted the verifier"
    )
