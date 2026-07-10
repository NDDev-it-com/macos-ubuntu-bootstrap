from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/browser_runtime_integrity.py"
SPEC = importlib.util.spec_from_file_location("browser_runtime_integrity", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
integrity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(integrity)


def write_receipt(path: Path, state: dict[str, object]) -> None:
    path.write_bytes(integrity.canonical_bytes(integrity.payload_with_integrity(state)))
    path.chmod(0o600)


def minimal_state() -> dict[str, object]:
    return {
        "schema": integrity.SCHEMA,
        "owner": integrity.OWNER,
        "bootstrap_version": integrity.BOOTSTRAP_VERSION,
        "home": str(Path.home()),
    }


def test_policy_contract_exposes_only_two_active_providers() -> None:
    integrity.validate_contract()
    contract = json.loads(
        (ROOT / "config/rldyour-contract.json").read_text(encoding="utf-8")
    )
    browser = contract["browser_automation"]
    assert browser["active_providers"] == ["playwright-cli", "chrome-devtools-mcp"]
    assert browser["webwright_status"] == "retired-fail-closed"
    assert browser["webwright_enabled"] is False
    assert browser["disabled_wrapper"] == "webwright"
    assert integrity.ACTIVE_PROVIDERS == ["playwright-cli", "chrome-devtools-mcp"]
    assert b"exit 78\n" in integrity.DISABLED_WEBWRIGHT
    assert b"NOT_PROVEN" in integrity.DISABLED_WEBWRIGHT


def test_cloak_runtime_identity_preserves_repository_logical_names(
    tmp_path: Path,
) -> None:
    platform_label = "Darwin-arm64"
    expected = integrity.content_id(
        f"cloakbrowser|version={integrity.CLOAK_VERSION}|platform={platform_label}",
        [
            ROOT / "templates/browser/cloakbrowser-pyproject.toml",
            ROOT / "templates/browser/cloakbrowser-uv.lock",
        ],
    )
    assert integrity.cloak_runtime_identity(platform_label) == expected

    # Installed files intentionally use conventional project names. Their
    # bytes match, but those renamed paths are not the installer's logical
    # content-ID inputs.
    project = tmp_path / "pyproject.toml"
    lock = tmp_path / "uv.lock"
    project.write_bytes(
        (ROOT / "templates/browser/cloakbrowser-pyproject.toml").read_bytes()
    )
    lock.write_bytes((ROOT / "templates/browser/cloakbrowser-uv.lock").read_bytes())
    assert (
        integrity.content_id(
            f"cloakbrowser|version={integrity.CLOAK_VERSION}|platform={platform_label}",
            [project, lock],
        )
        != expected
    )


def test_receipt_round_trip_rejects_payload_tampering(tmp_path: Path) -> None:
    receipt = tmp_path / "receipt.json"
    state = minimal_state()
    write_receipt(receipt, state)
    loaded = integrity.load_receipt(receipt)
    assert loaded["payload_sha256"] == integrity.sha256_bytes(
        integrity.canonical_bytes(state)
    )

    tampered = json.loads(receipt.read_text(encoding="utf-8"))
    tampered["bootstrap_version"] = "0.0.0"
    receipt.write_bytes(integrity.canonical_bytes(tampered))
    with pytest.raises(integrity.IntegrityError, match="payload digest changed"):
        integrity.load_receipt(receipt)


def test_receipt_rejects_noncanonical_json_and_unsafe_mode(tmp_path: Path) -> None:
    receipt = tmp_path / "receipt.json"
    state = minimal_state()
    payload = integrity.payload_with_integrity(state)
    receipt.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    receipt.chmod(0o600)
    with pytest.raises(integrity.IntegrityError, match="not canonical JSON"):
        integrity.load_receipt(receipt)

    write_receipt(receipt, state)
    receipt.chmod(0o620)
    with pytest.raises(integrity.IntegrityError, match="group/world-writable"):
        integrity.load_receipt(receipt)


def test_receipt_rejects_symlink(tmp_path: Path) -> None:
    target = tmp_path / "target.json"
    write_receipt(target, minimal_state())
    receipt = tmp_path / "receipt.json"
    receipt.symlink_to(target)
    with pytest.raises(integrity.IntegrityError, match="regular non-symlink"):
        integrity.load_receipt(receipt)


def test_build_uses_exclusive_owner_only_file(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    output = tmp_path / "receipt.json"
    state = minimal_state()
    monkeypatch.setattr(integrity, "collect_state", lambda **_: state)
    monkeypatch.setattr(
        integrity.sys,
        "argv",
        [
            str(MODULE_PATH),
            "build",
            "--output",
            str(output),
            "--cloak-runtime",
            str(tmp_path / "cloak"),
            "--cloak-binary",
            str(tmp_path / "binary"),
            "--node-runtime",
            str(tmp_path / "node"),
            "--config-runtime",
            str(tmp_path / "config"),
        ],
    )
    assert integrity.main() == 0
    assert os.stat(output).st_mode & 0o777 == 0o600
    assert (
        integrity.load_receipt(output)["bootstrap_version"]
        == integrity.BOOTSTRAP_VERSION
    )

    monkeypatch.setattr(integrity.sys, "argv", list(integrity.sys.argv))
    assert integrity.main() == 1
    assert (
        integrity.load_receipt(output)["bootstrap_version"]
        == integrity.BOOTSTRAP_VERSION
    )
