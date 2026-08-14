from __future__ import annotations

import importlib.util
import json
import os
import stat
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/device_integrity.py"
SPEC = importlib.util.spec_from_file_location("device_integrity", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
di = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(di)


# ----------------------------- helpers -----------------------------


def write_receipt(path: Path, state: dict[str, object]) -> None:
    """Write a canonical receipt with payload_sha256, mode 0600."""
    path.write_bytes(di.canonical_bytes(di.payload_with_integrity(state)))
    path.chmod(0o600)


def write_canonical(path: Path, data: dict[str, object]) -> None:
    """Write canonical JSON without the integrity field, mode 0600."""
    path.write_bytes(di.canonical_bytes(data))
    path.chmod(0o600)


def minimal_state() -> dict[str, object]:
    """A receipt-shaped dict with the mandatory top-level fields.

    The runtime_hosts/pinned_source_tools/user_tools/desktop_entries keys are
    kept empty so build-time and verify-time collect_state are not needed for
    the structural-integrity tests below.
    """
    return {
        "schema": di.SCHEMA,
        "owner": di.OWNER,
        "bootstrap_version": di.BOOTSTRAP_VERSION,
        "home": str(Path.home()),
        "platform": "Linux-x86_64",
        "policy_hashes": {},
        "runtime_hosts": {},
        "pinned_source_tools": {},
        "user_tools": {},
        "desktop_entries": {},
    }


# ----------------------------- canonical serialization -----------------------------


def test_canonical_bytes_is_sorted_compact_with_trailing_newline() -> None:
    payload = {"b": 2, "a": 1, "c": [3, 2, 1]}
    result = di.canonical_bytes(payload)
    assert result.endswith(b"\n")
    decoded = json.loads(result)
    assert decoded == payload
    # Keys must be sorted, separators must be compact (no spaces).
    assert result == b'{"a":1,"b":2,"c":[3,2,1]}\n'


def test_payload_with_integrity_adds_digest_without_mutating_input() -> None:
    original = {"a": 1}
    result = di.payload_with_integrity(original)
    assert "payload_sha256" in result
    assert "payload_sha256" not in original
    assert len(result["payload_sha256"]) == 64
    # The digest must match a re-derivation.
    assert result["payload_sha256"] == di.sha256_bytes(di.canonical_bytes(original))


# ----------------------------- receipt load + integrity -----------------------------


def test_receipt_round_trip_loads_after_write(tmp_path: Path) -> None:
    receipt = tmp_path / "device-receipt.json"
    write_receipt(receipt, minimal_state())
    loaded = di.load_receipt(receipt)
    assert loaded["schema"] == di.SCHEMA
    assert loaded["owner"] == di.OWNER
    assert "payload_sha256" in loaded


def test_receipt_rejects_noncanonical_json(tmp_path: Path) -> None:
    receipt = tmp_path / "bad.json"
    # Write JSON with spaces (non-canonical) but a valid digest field.
    state = minimal_state()
    state["payload_sha256"] = di.sha256_bytes(di.canonical_bytes(state))
    receipt.write_text(json.dumps(state, indent=2))
    receipt.chmod(0o600)
    with pytest.raises(di.IntegrityError, match="not canonical JSON"):
        di.load_receipt(receipt)


def test_receipt_rejects_payload_tampering(tmp_path: Path) -> None:
    """Changing a field after writing must break the payload digest."""
    receipt = tmp_path / "tampered.json"
    write_receipt(receipt, minimal_state())
    # Re-read, mutate a field, re-write canonically WITHOUT fixing the digest.
    data = json.loads(receipt.read_bytes())
    data["platform"] = "Darwin-arm64"
    receipt.write_bytes(di.canonical_bytes(data))
    receipt.chmod(0o600)
    with pytest.raises(di.IntegrityError, match="payload digest changed"):
        di.load_receipt(receipt)


def test_receipt_rejects_wrong_schema(tmp_path: Path) -> None:
    receipt = tmp_path / "wrong-schema.json"
    state = minimal_state()
    state["schema"] = "rldyour-something-else-v1"
    write_receipt(receipt, state)
    with pytest.raises(di.IntegrityError, match="ownership/schema is wrong"):
        di.load_receipt(receipt)


def test_receipt_rejects_wrong_owner(tmp_path: Path) -> None:
    receipt = tmp_path / "wrong-owner.json"
    state = minimal_state()
    state["owner"] = "not-macos-ubuntu-bootstrap"
    write_receipt(receipt, state)
    with pytest.raises(di.IntegrityError, match="ownership/schema is wrong"):
        di.load_receipt(receipt)


def test_receipt_rejects_symlink(tmp_path: Path) -> None:
    real = tmp_path / "real.json"
    write_receipt(real, minimal_state())
    link = tmp_path / "link.json"
    link.symlink_to(real)
    with pytest.raises(di.IntegrityError, match="regular non-symlink file"):
        di.load_receipt(link)


def test_receipt_rejects_missing_file(tmp_path: Path) -> None:
    with pytest.raises(di.IntegrityError, match="required path is missing"):
        di.load_receipt(tmp_path / "nonexistent.json")


def test_receipt_rejects_group_writable_mode(tmp_path: Path) -> None:
    receipt = tmp_path / "group-writable.json"
    write_receipt(receipt, minimal_state())
    receipt.chmod(0o660)
    with pytest.raises(di.IntegrityError, match="group/world-writable"):
        di.load_receipt(receipt)


# ----------------------------- contract version verification -----------------------------


def test_verify_contract_versions_passes_when_state_matches() -> None:
    """A state whose versions all match the contract must not raise."""
    contract = di.load_contract()
    runtime_support = contract["runtime_support"]
    state = {
        "runtime_hosts": {
            name: {
                # Use _normalize_version to mirror what collect_state would
                # produce — gopls reports "0.23.0" but the contract stores
                # "v0.23.0", and _verify_contract_versions strips the v.
                "normalized": di._normalize_version(runtime_support[field], name),
                "raw": runtime_support[field],
                "path": f"/bin/{name}",
            }
            for name, (_flag, field) in di.RUNTIME_HOSTS.items()
        },
        "pinned_source_tools": {
            name: spec["version"]
            for name, spec in runtime_support[
                di.PINNED_SOURCE_TOOLS_CONTRACT
            ].items()
        },
        "user_tools": {
            name: {
                "installed_version": spec["version"],
                "declared_version": spec["version"],
                **(
                    {
                        "sha256": spec["source"]["assets"][
                            "macos-aarch64" if di._current_os() == "macos" else "linux-x86_64"
                        ]["sha256"]
                    }
                    if spec.get("source", {}).get("assets")
                    else {}
                ),
                **(
                    {"external_updater_policy_valid": True}
                    if spec.get("external_updater_policy_target")
                    else {}
                ),
            }
            for name, spec in contract.get("user_tools", {}).items()
        },
    }
    # Must not raise.
    di._verify_contract_versions(state)


def test_verify_contract_versions_detects_runtime_drift() -> None:
    contract = di.load_contract()
    runtime_support = contract["runtime_support"]
    state = {
        "runtime_hosts": {
            name: {
                "normalized": runtime_support[field],
                "raw": runtime_support[field],
                "path": f"/bin/{name}",
            }
            for name, (_flag, field) in di.RUNTIME_HOSTS.items()
        },
        "pinned_source_tools": {},
        "user_tools": {},
    }
    # Introduce a drift in node.
    state["runtime_hosts"]["node"]["normalized"] = "0.0.0"
    with pytest.raises(di.IntegrityError, match="node: installed 0.0.0"):
        di._verify_contract_versions(state)


def test_verify_contract_versions_detects_absent_runtime() -> None:
    state = {
        "runtime_hosts": {
            name: {"normalized": None, "raw": "absent", "path": f"/bin/{name}"}
            for name, _ in di.RUNTIME_HOSTS.items()
        },
        "pinned_source_tools": {},
        "user_tools": {},
    }
    with pytest.raises(di.IntegrityError, match="absent"):
        di._verify_contract_versions(state)


def test_verify_contract_versions_detects_user_tool_drift(monkeypatch: pytest.MonkeyPatch) -> None:
    contract = di.load_contract()
    monkeypatch.setattr(di, "_applies_to_current_os", lambda spec: True)
    runtime_support = contract["runtime_support"]
    declared = list(contract.get("user_tools", {}))
    if not declared:
        pytest.skip("contract declares no user tools")
    name = declared[0]
    declared_version = contract["user_tools"][name]["version"]
    state = {
        "runtime_hosts": {
            runtime_name: {
                "normalized": di._normalize_version(runtime_support[field], runtime_name),
                "raw": runtime_support[field],
                "path": f"/bin/{runtime_name}",
            }
            for runtime_name, (_flag, field) in di.RUNTIME_HOSTS.items()
        },
        "pinned_source_tools": {
            tool: spec["version"]
            for tool, spec in runtime_support[di.PINNED_SOURCE_TOOLS_CONTRACT].items()
        },
        "user_tools": {
            name: {
                "installed_version": "0.0.0",
                "declared_version": declared_version,
            }
        },
    }
    with pytest.raises(di.IntegrityError, match=f"{name}: installed 0.0.0"):
        di._verify_contract_versions(state)


def test_telegram_presence_probe_never_executes_the_gui(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bin_dir = tmp_path / ".local/bin"
    bin_dir.mkdir(parents=True)
    for name in ("herdr", "telegram-desktop"):
        binary = bin_dir / name
        binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        binary.chmod(0o755)

    calls: list[str] = []

    def fake_run_version(binary: Path, flag: str) -> str:
        calls.append(binary.name)
        assert flag == "--version"
        return "herdr 0.8.0"

    monkeypatch.setattr(di.shutil, "which", lambda name: str(bin_dir / name))
    monkeypatch.setattr(di, "_applies_to_current_os", lambda spec: True)
    monkeypatch.setattr(di, "_run_version", fake_run_version)
    state = di._user_tool_state(bin_dir, tmp_path)

    assert calls == ["herdr"]
    assert state["telegram"]["raw"] == "presence-only"
    assert state["telegram"]["installed_version"] == "7.0.9"


# ----------------------------- profile awareness -----------------------------


def _server_state_all_required_tools_present() -> dict[str, object]:
    """A server-shaped state matching contract 3.1.0 source-tooling policy."""
    contract = di.load_contract()
    rs = contract["runtime_support"]
    runtime_hosts: dict[str, object] = {}
    for name, (_flag, field) in di.RUNTIME_HOSTS.items():
        runtime_hosts[name] = {
            "normalized": di._normalize_version(rs[field], name),
            "raw": rs[field],
            "path": f"/bin/{name}",
        }
    return {
        "runtime_hosts": runtime_hosts,
        "pinned_source_tools": {
            name: spec["version"]
            for name, spec in rs[di.PINNED_SOURCE_TOOLS_CONTRACT].items()
        },
        "user_tools": {
            "herdr": {
                "installed_version": contract["user_tools"]["herdr"]["version"],
                "sha256": contract["user_tools"]["herdr"]["source"]["assets"][
                    "macos-aarch64" if di._current_os() == "macos" else "linux-x86_64"
                ]["sha256"],
            }
        },
    }


def test_server_profile_requires_compiled_hosts_pinned_tools_and_herdr() -> None:
    state = _server_state_all_required_tools_present()
    di._verify_contract_versions(state, profile="server")
    state["runtime_hosts"]["go"]["normalized"] = "absent"
    with pytest.raises(di.IntegrityError, match="go: absent"):
        di._verify_contract_versions(state, profile="server")


def test_server_profile_still_requires_node_uv_bun() -> None:
    """node/uv/bun are provisioned on every profile; a server drift still fails."""
    state = _server_state_all_required_tools_present()
    state["runtime_hosts"]["node"]["normalized"] = "0.0.0"
    with pytest.raises(di.IntegrityError, match="node: installed 0.0.0"):
        di._verify_contract_versions(state, profile="server")


def test_resolve_build_profile_precedence(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("RLDYOUR_PROFILE", raising=False)
    monkeypatch.delenv("RLDYOUR_LOCAL_EXECUTION_POLICY", raising=False)
    # Explicit wins.
    assert di._resolve_build_profile("server") == "server"
    # Env profile next.
    monkeypatch.setenv("RLDYOUR_PROFILE", "server")
    assert di._resolve_build_profile(None) == "server"
    # Execution policy maps to a profile.
    monkeypatch.delenv("RLDYOUR_PROFILE", raising=False)
    monkeypatch.setenv("RLDYOUR_LOCAL_EXECUTION_POLICY", "container-execution-only")
    assert di._resolve_build_profile(None) == "server"
    # Nothing set falls back to the strict desktop superset.
    monkeypatch.delenv("RLDYOUR_LOCAL_EXECUTION_POLICY", raising=False)
    assert di._resolve_build_profile(None) == "desktop"


def test_collect_state_records_profile() -> None:
    state = di.collect_state(home=Path.home(), profile="server")
    assert state["profile"] == "server"


def test_collect_state_rejects_invalid_profile() -> None:
    with pytest.raises(di.IntegrityError, match="profile is invalid"):
        di.collect_state(home=Path.home(), profile="bogus")


def test_verify_receipt_rejects_missing_profile(tmp_path: Path) -> None:
    """A pre-profile receipt (or one with a bad profile) fails closed."""
    receipt = tmp_path / "no-profile.json"
    write_receipt(receipt, minimal_state())  # minimal_state has no "profile"
    with pytest.raises(di.IntegrityError, match="missing a valid profile"):
        di.verify_receipt(receipt)


def test_build_server_profile_flag_plumbs_through(tmp_path: Path) -> None:
    """`build --profile server` records the server profile in the receipt."""
    receipt = tmp_path / "server.json"
    assert _run_cli("build", "--output", str(receipt), "--profile", "server") == 0
    loaded = di.load_receipt(receipt)
    assert loaded["profile"] == "server"


# ----------------------------- contract parity (static) -----------------------------


def test_contract_has_new_sections() -> None:
    """The contract must declare the sections this feature relies on."""
    contract = di.load_contract()
    assert "user_tools" in contract, "contract missing user_tools section"
    assert "desktop_entries" in contract, "contract missing desktop_entries section"
    assert (
        "ubuntu_apt_packages" in contract
    ), "contract missing ubuntu_apt_packages section"


def test_herdr_declared_in_contract_and_install_sh() -> None:
    """herdr must be declared in both the contract and the bash installer."""
    contract = di.load_contract()
    assert "herdr" in contract["user_tools"], "herdr not in contract user_tools"
    assert (
        contract["user_tools"]["herdr"]["version"] == "0.8.0"
    ), "herdr version mismatch in contract"

    installer = (ROOT / "scripts/ubuntu/install.sh").read_text(encoding="utf-8")
    assert "USER_TOOLS=(" in installer, "USER_TOOLS array missing from install.sh"
    assert (
        "herdr;0.8.0;raw" in installer
    ), "herdr row missing from USER_TOOLS array in install.sh"


def test_desktop_template_exists() -> None:
    template = ROOT / "templates/desktop/herdr.desktop"
    assert template.is_file(), f"desktop template missing: {template}"
    text = template.read_text(encoding="utf-8")
    assert "Exec=ptyxis" in text, "desktop template missing Ptyxis Exec line"
    assert "desktop-entry-herdr-v1" in text, "desktop template missing managed marker"


def test_telegram_runtime_and_launcher_policies_are_explicit() -> None:
    contract = di.load_contract()
    runtime = contract["user_tools"]["telegram"]
    desktop = contract["desktop_entries"]["telegram"]
    template = ROOT / desktop["source"]
    text = template.read_text(encoding="utf-8")

    assert runtime["auto_update"] == "disabled-by-externalupdater.d"
    assert runtime["version_probe"] == "presence-only"
    assert runtime["external_updater_policy_target"].endswith(
        "/TelegramDesktop/externalupdater.d/macos-ubuntu-bootstrap"
    )
    assert desktop["launch_environment"] == {"QT_QPA_PLATFORM": "xcb"}
    assert desktop["dbus_activatable"] is False
    assert desktop["icon"] == "org.telegram.desktop"
    assert desktop["target"].endswith(
        "/applications/org.telegram.desktop.desktop"
    )
    assert desktop["upstream_source_commit"] == (
        "a1e89e1f64f08cb058caf1c61ff43f319f98a6ec"
    )
    assert len(desktop["icon_assets"]) == 4
    assert desktop["icon_assets"][0]["target"].endswith(
        "/hicolor/256x256/apps/org.telegram.desktop.png"
    )
    assert desktop["icon_assets"][0]["sha256"] == (
        "3fb1400c7dc9bbc3b5cb3ffedcbf4a9b09c53e28b57a7ff33a8a6b9048864090"
    )
    assert "desktop-entry-telegram-v3" in text
    assert "Exec=env QT_QPA_PLATFORM=xcb telegram-desktop -- %U" in text
    assert "Icon=org.telegram.desktop" in text
    assert "DBusActivatable=false" in text
    assert "MimeType=x-scheme-handler/tg;x-scheme-handler/tonsite;" in text


# ----------------------------- build / verify CLI -----------------------------


def _device_matches_desktop_contract() -> bool:
    """True only on a device actually provisioned to the desktop contract.

    The build->verify round-trip tests prove a real PROVEN receipt, which needs
    the pinned toolchain installed at the contract versions. A bare CI runner
    has none of it (node/go at runner defaults, bun/dart/scanners absent), so
    those two tests skip there instead of asserting a NOT_PROVEN device is
    PROVEN. On a provisioned dev machine they run in full.
    """
    try:
        di._verify_contract_versions(
            di.collect_state(home=Path.home(), profile="desktop"), profile="desktop"
        )
        return True
    except di.IntegrityError:
        return False


requires_provisioned_device = pytest.mark.skipif(
    not _device_matches_desktop_contract(),
    reason="requires a device provisioned with the pinned toolchain (a bare CI runner is not)",
)


def test_build_writes_canonical_receipt(tmp_path: Path) -> None:
    output = tmp_path / "built.json"
    # build uses the real machine state, which is fine — we only assert the
    # output is canonical and loadable.
    rc = _run_cli("build", "--output", str(output))
    assert rc == 0
    assert output.exists()
    loaded = di.load_receipt(output)
    assert loaded["schema"] == di.SCHEMA


@requires_provisioned_device
def test_verify_cli_returns_zero_on_valid_receipt(tmp_path: Path) -> None:
    """verify subcommand via CLI must exit 0 and print PROVEN for a fresh receipt."""
    receipt = tmp_path / "verify.json"
    assert _run_cli("build", "--output", str(receipt)) == 0
    assert _run_cli("verify", "--receipt", str(receipt)) == 0


@requires_provisioned_device
def test_verify_cli_json_output(tmp_path: Path) -> None:
    """verify --json must emit a canonical JSON status envelope."""
    import io
    import sys

    receipt = tmp_path / "verify-json.json"
    assert _run_cli("build", "--output", str(receipt)) == 0

    old_stdout = sys.stdout
    sys.stdout = io.StringIO()
    try:
        rc = _run_cli("verify", "--receipt", str(receipt), "--json")
    finally:
        output = sys.stdout.getvalue()
        sys.stdout = old_stdout

    assert rc == 0
    result = json.loads(output)
    assert result["status"] == "PROVEN"
    assert "payload_sha256" in result


def test_metadata_only_cli(tmp_path: Path) -> None:
    """metadata-only subcommand must validate receipt self-integrity."""
    receipt = tmp_path / "meta.json"
    assert _run_cli("build", "--output", str(receipt)) == 0
    assert _run_cli("metadata-only", "--receipt", str(receipt)) == 0


def test_build_overwrites_existing_our_receipt_with_backup(tmp_path: Path) -> None:
    """build must back up an existing our-receipt before rewriting."""
    receipt = tmp_path / "rebuild.json"
    assert _run_cli("build", "--output", str(receipt)) == 0
    # A second build should create a .bak and succeed.
    assert _run_cli("build", "--output", str(receipt)) == 0
    assert (tmp_path / "rebuild.json.bak").exists()


def test_build_refuses_unmanaged_receipt(tmp_path: Path) -> None:
    """build must refuse to overwrite a file that is not one of our receipts."""
    foreign = tmp_path / "foreign.json"
    foreign.write_text(json.dumps({"unrelated": "data"}))
    rc = _run_cli("build", "--output", str(foreign))
    assert rc != 0


# ------------------- receipt replacement is a transaction -------------------
#
# Ownership used to be decided by schema+owner alone, and the active receipt was
# renamed to .bak *before* state collection. Both halves are tested here: an
# owned-but-unverifiable receipt must not be silently consumed, and no failure
# may leave the device without an active receipt.


def _valid_receipt(tmp_path: Path, name: str = "device.json") -> Path:
    receipt = tmp_path / name
    assert _run_cli("build", "--output", str(receipt)) == 0
    return receipt


def test_build_refuses_an_owned_receipt_whose_payload_was_edited(tmp_path: Path) -> None:
    """Correct schema and owner, wrong digest: evidence, not a stale file."""
    receipt = _valid_receipt(tmp_path)
    data = json.loads(receipt.read_text(encoding="utf-8"))
    data["home"] = "/tmp/somewhere-else"  # digest no longer matches the payload
    receipt.write_bytes(di.canonical_bytes(data))
    before = receipt.read_bytes()

    assert _run_cli("build", "--output", str(receipt)) != 0
    assert receipt.read_bytes() == before, "the tampered receipt must be preserved"


def test_build_refuses_a_noncanonical_owned_receipt(tmp_path: Path) -> None:
    receipt = _valid_receipt(tmp_path)
    data = json.loads(receipt.read_text(encoding="utf-8"))
    receipt.write_text(json.dumps(data, indent=2), encoding="utf-8")  # not canonical
    before = receipt.read_bytes()

    assert _run_cli("build", "--output", str(receipt)) != 0
    assert receipt.read_bytes() == before


def test_build_refuses_a_symlinked_receipt(tmp_path: Path) -> None:
    real = _valid_receipt(tmp_path, "real.json")
    link = tmp_path / "link.json"
    link.symlink_to(real)
    before = real.read_bytes()

    assert _run_cli("build", "--output", str(link)) != 0
    assert link.is_symlink(), "the symlink itself must be left in place"
    assert real.read_bytes() == before


def test_build_refuses_a_group_writable_receipt(tmp_path: Path) -> None:
    receipt = _valid_receipt(tmp_path)
    receipt.chmod(0o664)
    before = receipt.read_bytes()

    assert _run_cli("build", "--output", str(receipt)) != 0
    assert receipt.read_bytes() == before


def test_collection_failure_leaves_the_active_receipt_intact(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The previous order renamed the receipt away before collecting state."""
    receipt = _valid_receipt(tmp_path)
    before = receipt.read_bytes()

    def exploding_collect(**_: object) -> dict[str, object]:
        raise di.IntegrityError("collection failed")

    monkeypatch.setattr(di, "collect_state", exploding_collect)
    assert _run_cli("build", "--output", str(receipt)) != 0

    assert receipt.exists(), "the last valid receipt must still be the active one"
    assert receipt.read_bytes() == before


def test_publication_failure_leaves_the_active_receipt_intact(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    receipt = _valid_receipt(tmp_path)
    before = receipt.read_bytes()

    real_replace = os.replace

    def exploding_replace(src: object, dst: object) -> None:
        raise OSError("simulated rename failure")

    monkeypatch.setattr(di.os, "replace", exploding_replace)
    with pytest.raises(OSError):
        _run_cli("build", "--output", str(receipt))
    monkeypatch.setattr(di.os, "replace", real_replace)

    assert receipt.read_bytes() == before
    leftovers = [p.name for p in tmp_path.iterdir() if p.name.endswith(".tmp")]
    assert leftovers == [], f"temporary files were left behind: {leftovers}"


def test_replace_invalid_retains_the_rejected_copy(tmp_path: Path) -> None:
    """The escape hatch must preserve the unverifiable receipt as evidence."""
    receipt = _valid_receipt(tmp_path)
    data = json.loads(receipt.read_text(encoding="utf-8"))
    data["home"] = "/tmp/somewhere-else"
    receipt.write_bytes(di.canonical_bytes(data))
    tampered = receipt.read_bytes()

    assert _run_cli("build", "--output", str(receipt), "--replace-invalid") == 0

    rejected = tmp_path / f"{receipt.name}.rejected.1"
    assert rejected.exists()
    assert rejected.read_bytes() == tampered
    di.load_receipt(receipt, metadata_only=True)  # the new one must be valid


def test_write_file_atomically_is_private_and_durable(tmp_path: Path) -> None:
    target = tmp_path / "sub" / "payload.bin"
    target.parent.mkdir()
    di.write_file_atomically(target, b"first\n")
    assert target.read_bytes() == b"first\n"
    assert stat.S_IMODE(target.stat().st_mode) == 0o600

    di.write_file_atomically(target, b"second\n")
    assert target.read_bytes() == b"second\n"
    assert [p.name for p in target.parent.iterdir()] == ["payload.bin"]



def _run_cli(*args: str) -> int:
    """Invoke the script's main() with the given argv."""
    import sys

    old = sys.argv
    sys.argv = [str(MODULE_PATH), *args]
    try:
        return di.main()
    finally:
        sys.argv = old


# --------------------------------------------------------------------------
# The receipt has a caller, and the ownership check has something to check (#67)
#
# device_integrity.py was 846 lines with no runtime caller, and its harness
# ownership check read a contract key that did not exist -- so it reported
# no drift because it could observe none. ADR 0007 and AGENTS.md described it
# as a working mechanism. These tests bind the mechanism to its callers and
# prove the ownership check can now fail.
# --------------------------------------------------------------------------

CONTRACT = json.loads((ROOT / "config/rldyour-contract.json").read_text(encoding="utf-8"))
UBUNTU_INSTALL = (ROOT / "scripts/ubuntu/install.sh").read_text(encoding="utf-8")
UBUNTU_VERIFY = (ROOT / "scripts/ubuntu/verify.sh").read_text(encoding="utf-8")


def _fake_harness(home: Path, prefix_rel: str, command: str) -> Path:
    target = home / prefix_rel / command
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    target.chmod(0o755)
    return target


def test_every_active_harness_has_a_detection_entry() -> None:
    """The policy names three harnesses; all three must be observable."""
    detection = CONTRACT["harnesses"]["detection"]
    for name in CONTRACT["harnesses"]["active"]:
        assert name in detection, f"{name} is active but has no detection entry"
        spec = detection[name]
        assert spec["enforcement"] in {"owned-prefix", "observe-only"}
        assert spec["owned_prefix_default"].startswith("${HOME}")
        assert len(spec.get("rationale", "")) > 30, f"{name} states no rationale"


def test_at_least_one_harness_is_actually_enforced() -> None:
    """An all-observe-only block would be the old no-op with more words."""
    detection = CONTRACT["harnesses"]["detection"]
    enforced = [
        name for name, spec in detection.items()
        if isinstance(spec, dict) and spec.get("enforcement") == "owned-prefix"
    ]
    assert enforced, "no harness is enforced; the ownership check observes nothing"


def test_harness_inside_its_owned_prefix_is_not_drift(tmp_path, monkeypatch) -> None:
    home = tmp_path / "home"
    codex = _fake_harness(home, ".local/share/rldyour/npm/bin", "codex")
    bin_dir = home / ".local/bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (bin_dir / "codex").symlink_to(codex)
    monkeypatch.setenv("PATH", str(bin_dir))
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))

    state = {"harnesses": di._harness_state(home)}
    assert state["harnesses"]["codex"]["inside_owned_prefix"] == "True"
    assert di._verify_harness_ownership(state) == []


def test_a_second_copy_shadowing_the_owner_is_reported(tmp_path, monkeypatch) -> None:
    """The exact failure the one-owner-per-harness policy exists to catch."""
    home = tmp_path / "home"
    _fake_harness(home, ".local/share/rldyour/npm/bin", "codex")
    impostor = _fake_harness(home, ".bun/bin", "codex")
    monkeypatch.setenv("PATH", str(impostor.parent))
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))

    state = {"harnesses": di._harness_state(home)}
    drifts = di._verify_harness_ownership(state)
    assert len(drifts) == 1
    assert "codex" in drifts[0]
    assert str(impostor) in drifts[0]


def test_observe_only_harnesses_never_produce_drift(tmp_path, monkeypatch) -> None:
    """The vendor installer owns those targets; recording is not enforcing."""
    home = tmp_path / "home"
    claude = _fake_harness(home, "somewhere/else", "claude")
    grok = _fake_harness(home, "another/place", "grok")
    monkeypatch.setenv("PATH", f"{claude.parent}:{grok.parent}")
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))

    state = {"harnesses": di._harness_state(home)}
    assert state["harnesses"]["claude-code"]["inside_owned_prefix"] == "False"
    assert state["harnesses"]["grok-build"]["inside_owned_prefix"] == "False"
    assert di._verify_harness_ownership(state) == []


def _contract_drifts(state: dict, platform: str, monkeypatch) -> str:
    """Return the drift message `_verify_contract_versions` raises, or ""."""
    monkeypatch.setattr(di, "_current_os", lambda: platform)
    try:
        di._verify_contract_versions(state, profile="desktop")
    except di.IntegrityError as exc:
        return str(exc)
    return ""


def test_exact_versions_are_only_asserted_where_the_contract_pins_them(monkeypatch) -> None:
    """macOS resolves runtime hosts through Homebrew, so `ubuntu_*` is not its contract.

    Homebrew resolves current metadata and preserves an already installed
    formula, so a macOS device legitimately carries a different patch than the
    `ubuntu_*` fields pin. Asserting those fields there reported drift that was
    not drift. `user_tools` are unaffected: herdr is an exact pinned artifact on
    both platforms and stays asserted everywhere.
    """
    assert di.EXACT_VERSION_PLATFORMS == ("linux",)
    state = {
        "runtime_hosts": {name: {"normalized": "0.0.0"} for name in di.RUNTIME_HOSTS},
        "pinned_source_tools": {name: "0.0.0" for name in
                                CONTRACT["runtime_support"]["ubuntu_pinned_source_tools"]},
        "user_tools": {},
        "harnesses": {},
    }

    on_linux = _contract_drifts(state, "linux", monkeypatch)
    on_macos = _contract_drifts(state, "macos", monkeypatch)

    # Every runtime host and pinned tool is wrong; Linux must name them all.
    for name in di.RUNTIME_HOSTS:
        assert f"{name}: installed 0.0.0" in on_linux, f"{name} not asserted on Linux"
    for name in CONTRACT["runtime_support"]["ubuntu_pinned_source_tools"]:
        assert f"{name}: installed 0.0.0" in on_linux, f"{name} not asserted on Linux"

    # macOS must not report any of them.
    for name in di.RUNTIME_HOSTS:
        assert f"{name}: installed 0.0.0" not in on_macos, f"{name} wrongly asserted on macOS"
    for name in CONTRACT["runtime_support"]["ubuntu_pinned_source_tools"]:
        assert f"{name}: installed 0.0.0" not in on_macos, f"{name} wrongly asserted on macOS"


def test_apply_writes_a_receipt_and_strict_verify_checks_it() -> None:
    """No document may describe a mechanism that does not run."""
    assert "build_device_receipt" in UBUNTU_INSTALL
    assert "device_integrity.py\" build --profile" in UBUNTU_INSTALL
    # The receipt records a state something else already proved, so it is built
    # after strict verification rather than instead of it.
    verify_apply = UBUNTU_INSTALL.split("verify_apply() {", 1)[1].split("\n}", 1)[0]
    assert verify_apply.index("verify.sh\" --strict") < verify_apply.index("build_device_receipt")
    assert "device_integrity.py\" verify --receipt" in UBUNTU_VERIFY


def test_no_document_claims_the_harness_collector_observes_nothing() -> None:
    """#62 added that caveat as an interim mitigation; it is no longer true."""
    source = MODULE_PATH.read_text(encoding="utf-8")
    assert "currently observe nothing" not in source
    assert "carries no ``harnesses.detection``" not in source


def test_policy_hashes_accept_a_repository_the_applying_user_does_not_own() -> None:
    """The hosted native evidence lanes stage the repository as root.

    `platform-evidence.sh` does `sudo cp -a` the checkout to
    /opt/rldyour-evidence-source and then applies it as an unprivileged
    `rldyourevidence`. That is a legitimate shape -- a read-only repository
    staged by an administrator and applied by a user who cannot modify it -- and
    it is safer than the alternative, yet it made `policy_hashes` fail with
    `path is not owned by the current UID`. The device receipt could not be
    built in the very lanes that are supposed to gate it.

    A repository source is pinned into the receipt by its content hash, not by
    who owns it: the first path checked is `device_integrity.py` itself, so
    anyone who owns it already controls the check.
    """
    import inspect

    source = inspect.getsource(di.policy_hashes)
    assert "enforce_owner=False" in source

    # And the primitive still enforces ownership by default, for device files.
    signature = inspect.signature(di.regular_owned)
    assert signature.parameters["enforce_owner"].default is True


def test_regular_owned_still_rejects_a_foreign_owner_for_device_files(tmp_path) -> None:
    """Ownership remains enforced where it means something."""
    import inspect

    target = tmp_path / "receipt.json"
    target.write_text("{}", encoding="utf-8")
    # Owned by us, so it passes with the check on.
    di.regular_owned(target, enforce_private_mode=False)
    # The device-state collectors must not have opted out of it.
    for name in ("_user_tool_state", "_desktop_entry_state"):
        source = inspect.getsource(getattr(di, name))
        assert "enforce_owner=False" not in source, f"{name} opted out of ownership"


# Functions whose `regular_owned` targets are repository sources rather than
# files this installer wrote on the device.
_REPOSITORY_SOURCE_READERS = {"load_contract", "policy_hashes"}


def test_every_repository_source_check_opts_out_of_ownership() -> None:
    """Catch the class, not the instance.

    Fixing `policy_hashes` alone moved the hosted lane's failure from
    `scripts/device_integrity.py` to `config/rldyour-contract.json`, because
    `load_contract` performed the same check independently. This walks the AST
    and requires every `regular_owned` call inside a repository-source reader to
    pass `enforce_owner=False` -- and, symmetrically, every call outside one NOT
    to, since a file this installer wrote is where ownership means something.

    Classification is by enclosing function rather than by argument name: the
    receipt path in `load_receipt` and the loop variable in `policy_hashes` are
    both called `path`, so the name says nothing.
    """
    import ast

    tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
    checked = 0
    for function in ast.walk(tree):
        if not isinstance(function, ast.FunctionDef):
            continue
        reads_repository = function.name in _REPOSITORY_SOURCE_READERS
        for node in ast.walk(function):
            if not (isinstance(node, ast.Call)
                    and getattr(node.func, "id", None) == "regular_owned"):
                continue
            checked += 1
            keywords = {kw.arg: kw.value for kw in node.keywords}
            value = keywords.get("enforce_owner")
            opted_out = isinstance(value, ast.Constant) and value.value is False
            if reads_repository:
                assert opted_out, (
                    f"{function.name} (line {node.lineno}) reads a repository source but "
                    "still enforces current-UID ownership; the hosted lanes stage the "
                    "repository as root and apply it as an unprivileged user"
                )
            else:
                assert not opted_out, (
                    f"{function.name} (line {node.lineno}) opted out of ownership for a "
                    "device file; ownership is a real property there"
                )

    assert checked >= 3, f"expected at least three call sites, found {checked}"
