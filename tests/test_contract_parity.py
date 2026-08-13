"""Contract parity tests: the contract JSON must match the installer code.

Extends the pattern established by test_compiled_language_hosts.py
(test_installer_constants_match_the_contract) to cover the domains that were
previously unchecked: apt baseline, GUI applications, macOS GUI casks, and
Node/uv/Bun version+hash constants. A drift between the contract and the
installer is caught here at CI time, before it can ship to a device.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "config/rldyour-contract.json"
UBUNTU_INSTALL_PATH = ROOT / "scripts/ubuntu/install.sh"
MACOS_INSTALL_PATH = ROOT / "scripts/macos/install.sh"
MACOS_VERIFY_PATH = ROOT / "scripts/macos/verify.sh"
SHELL_CONTRACT_PATH = ROOT / "scripts/ci/shell_contract.py"


def _read_text(path: Path) -> str:
    if not isinstance(path, Path):
        raise TypeError("filesystem fixture must be Path-valued")
    return path.read_text(encoding="utf-8")


CONTRACT_DATA = json.loads(_read_text(CONTRACT_PATH))
UBUNTU_INSTALL_TEXT = _read_text(UBUNTU_INSTALL_PATH)
MACOS_INSTALL_TEXT = _read_text(MACOS_INSTALL_PATH)
MACOS_VERIFY_TEXT = _read_text(MACOS_VERIFY_PATH)


def test_release_metadata_matches_contract_version() -> None:
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    assert CONTRACT_DATA["adapter"]["version"] == version
    assert f"## Contract {version}" in agents
    assert f"current contract is `{version}`" in readme
    assert re.search(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}$", changelog, re.M)


def test_ubuntu_gui_architecture_boundary_is_explicit_and_enforced() -> None:
    ubuntu = CONTRACT_DATA["targets"]["ubuntu"]
    assert ubuntu["architectures"] == ["amd64", "arm64"]
    assert ubuntu["gui_architectures"] == ["amd64"]
    assert 'if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && [ "$GUI_ENABLED" -eq 1 ]' in UBUNTU_INSTALL_TEXT
    assert "Google Chrome and Telegram Desktop publish no supported Linux ARM64 build" in UBUNTU_INSTALL_TEXT


def _parse_bash_array(path: Path, name: str) -> list[str]:
    """Extract one bounded static Bash array without executing shell."""
    if not isinstance(path, Path):
        raise TypeError("shell array source must be Path-valued")
    result = subprocess.run(
        [sys.executable, "-I", str(SHELL_CONTRACT_PATH), "array", "--path", str(path), "--name", name],
        text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stderr
    envelope = json.loads(result.stdout)
    assert envelope["schema"] == "rldyour.shell-contract/v1"
    assert envelope["operation"] == "array"
    return envelope["result"]


def _ubuntu_packages(consumer: str) -> list[str]:
    result = subprocess.run(
        [sys.executable, "-I", str(SHELL_CONTRACT_PATH), "ubuntu-packages", "--contract", str(CONTRACT_PATH), "--consumer", consumer],
        text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0, result.stderr
    envelope = json.loads(result.stdout)
    assert envelope["schema"] == "rldyour.shell-contract/v1"
    return envelope["result"]


def _constant(source: str, name: str) -> str:
    """Extract a bash scalar constant NAME=\"value\" from source."""
    if not isinstance(source, str):
        raise TypeError("shell scalar source must be text-valued")
    match = re.search(rf'^{name}="([^"]+)"', source, re.M)
    assert match is not None, f"{name} missing from installer source"
    return match.group(1)


# ----------------------------- apt packages -----------------------------


def test_apt_baseline_matches_contract() -> None:
    """Installer baseline is the canonical named JSON transformation."""
    code = _parse_bash_array(UBUNTU_INSTALL_PATH, "APT_SOURCE_PACKAGES")
    expected = _ubuntu_packages("ubuntu-install-source-baseline")
    assert code == expected, (
        f"apt baseline order/content drift:\n  code: {code}\n  contract: {expected}"
    )


def test_host_build_packages_are_profile_isolated() -> None:
    assert "APT_DESKTOP_BUILD_PACKAGES" not in UBUNTU_INSTALL_TEXT
    assert _ubuntu_packages("ubuntu-desktop-build") == ["build-essential"]
    profiles = CONTRACT_DATA["ubuntu_apt_packages"]["profiles"]
    assert "desktop_build" in profiles["desktop"]
    assert "desktop_build" in profiles["desktop-builds"]
    assert "desktop_build" not in profiles["server"]


def test_apt_profiles_reference_valid_groups() -> None:
    """Every profile must reference only groups that exist in the contract."""
    groups = {k for k in CONTRACT_DATA["ubuntu_apt_packages"] if not k.startswith("_") and k != "profiles"}
    for profile, refs in CONTRACT_DATA["ubuntu_apt_packages"]["profiles"].items():
        for ref in refs:
            assert ref in groups, f"profile {profile} references unknown group {ref}"


# ----------------------------- macOS GUI casks -----------------------------


def test_gui_casks_match_contract() -> None:
    """macOS GUI_CASKS array == contract gui.macos list."""
    code = set(_parse_bash_array(MACOS_INSTALL_PATH, "GUI_CASKS"))
    contract = set(CONTRACT_DATA["gui"]["macos"])
    assert code == contract, (
        f"GUI casks drift:\n  in code only: {code - contract}\n  in contract only: {contract - code}"
    )


# ----------------------------- Node / uv / Bun constants -----------------------------


def test_node_constants_match_contract() -> None:
    """Node version + SHA-256 in install.sh == contract runtime_support."""
    runtime = CONTRACT_DATA["runtime_support"]
    assert _constant(UBUNTU_INSTALL_TEXT, "NODE_VERSION") == runtime["ubuntu_node_lts"]
    assert _constant(UBUNTU_INSTALL_TEXT, "NODE_SHA256_X64") == runtime["ubuntu_node_sha256"]["x64"]
    assert _constant(UBUNTU_INSTALL_TEXT, "NODE_SHA256_ARM64") == runtime["ubuntu_node_sha256"]["arm64"]


def test_uv_constants_match_contract() -> None:
    """uv version + SHA-256 in install.sh == contract runtime_support."""
    runtime = CONTRACT_DATA["runtime_support"]
    assert _constant(UBUNTU_INSTALL_TEXT, "UV_VERSION") == runtime["ubuntu_uv"]
    assert _constant(UBUNTU_INSTALL_TEXT, "UV_SHA256_X64") == runtime["ubuntu_uv_sha256"]["x64"]
    assert _constant(UBUNTU_INSTALL_TEXT, "UV_SHA256_ARM64") == runtime["ubuntu_uv_sha256"]["arm64"]


def test_bun_constants_match_contract() -> None:
    """Bun version + SHA-256 in install.sh == contract runtime_support."""
    runtime = CONTRACT_DATA["runtime_support"]
    assert _constant(UBUNTU_INSTALL_TEXT, "BUN_VERSION") == runtime["ubuntu_bun"]
    assert _constant(UBUNTU_INSTALL_TEXT, "BUN_SHA256_X64") == runtime["ubuntu_bun_sha256"]["x64"]
    assert _constant(UBUNTU_INSTALL_TEXT, "BUN_SHA256_ARM64") == runtime["ubuntu_bun_sha256"]["arm64"]


# ----------------------------- USER_TOOLS (herdr) -----------------------------


def _parse_user_tool_rows(path: Path) -> dict[str, list[str]]:
    """Parse the USER_TOOLS bash array into {name: [fields]}.

    Each row is ``name;version;kind;member_x64;member_arm64;link;
    sha_x64;sha_arm64;url_x64;url_arm64`` — the same contract as
    PINNED_SOURCE_TOOLS.
    """
    rows: dict[str, list[str]] = {}
    for raw in _parse_bash_array(path, "USER_TOOLS"):
        fields = raw.split(";")
        rows[fields[0]] = fields
    return rows


def test_user_tools_match_the_contract() -> None:
    """USER_TOOLS bash array must match contract user_tools: name, version, SHA-256."""
    declared = CONTRACT_DATA.get("user_tools", {})
    rows = _parse_user_tool_rows(UBUNTU_INSTALL_PATH)
    assert set(declared) == set(rows), (
        f"contract and installer disagree on user_tools set:\n"
        f"  contract only: {set(declared) - set(rows)}\n"
        f"  installer only: {set(rows) - set(declared)}"
    )
    for name, row in rows.items():
        spec = declared[name]
        assert row[1] == spec["version"], f"{name}: version drift ({row[1]} vs {spec['version']})"
        # Herdr uses the canonical per-platform source asset table; Telegram
        # uses a single archive_sha256.
        if name == "herdr":
            assets = spec["source"]["assets"]
            assert row[6] == assets["linux-x86_64"]["sha256"], f"{name}: x64 SHA-256 drift"
            assert row[7] == assets["linux-aarch64"]["sha256"], f"{name}: arm64 SHA-256 drift"
            assert row[8] == assets["linux-x86_64"]["url"], f"{name}: x64 URL drift"
            assert row[9] == assets["linux-aarch64"]["url"], f"{name}: arm64 URL drift"
        elif "archive_sha256" in spec:
            assert row[6] == spec["archive_sha256"], f"{name}: archive SHA-256 drift"
            assert row[7] in {"", spec["archive_sha256"]}, f"{name}: archive SHA-256 (arm64 slot) drift"


def test_macos_herdr_asset_matches_contract_and_bypasses_homebrew() -> None:
    herdr = CONTRACT_DATA["user_tools"]["herdr"]
    macos = herdr["source"]["assets"]["macos-aarch64"]
    assert herdr["install_method"]["macos"] == "verified-github-release-binary"
    assert _constant(MACOS_INSTALL_TEXT, "HERDR_VERSION") == herdr["version"]
    assert _constant(MACOS_INSTALL_TEXT, "HERDR_MACOS_AARCH64_SHA256") == macos["sha256"]
    assert _constant(MACOS_INSTALL_TEXT, "HERDR_MACOS_AARCH64_URL") == macos["url"]
    assert _constant(MACOS_VERIFY_TEXT, "HERDR_VERSION") == herdr["version"]
    assert _constant(MACOS_VERIFY_TEXT, "HERDR_MACOS_AARCH64_SHA256") == macos["sha256"]
    assert _constant(MACOS_VERIFY_TEXT, "HERDR_MACOS_AARCH64_URL") == macos["url"]
    assert "herdr" not in set(_parse_bash_array(MACOS_INSTALL_PATH, "BREW_SOURCE_PACKAGES"))
    assert "ensure_herdr" in MACOS_INSTALL_TEXT.split("main() {", 1)[1]
    assert herdr["source"]["tag"] == f"v{herdr['version']}"
    assert herdr["source"]["tag_object"] == "857196dee1ce98df53efdd3f437aa2ac8a75b608"
    assert herdr["source"]["commit"] == "346411fa21afd297f5ed3b3fa56f9e3fbf7654b7"
    assert herdr["source"]["verified_at"] == "2026-08-13"
    assert "never invoke mutable herdr update" in herdr["update_policy"]
    assert "herdr update" not in MACOS_INSTALL_TEXT


def test_fixture_types_fail_closed_in_both_directions() -> None:
    with pytest.raises(TypeError, match="Path-valued"):
        _read_text(UBUNTU_INSTALL_TEXT)  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="text-valued"):
        _constant(UBUNTU_INSTALL_PATH, "NODE_VERSION")  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="Path-valued"):
        _parse_bash_array(UBUNTU_INSTALL_TEXT, "APT_SOURCE_PACKAGES")  # type: ignore[arg-type]
