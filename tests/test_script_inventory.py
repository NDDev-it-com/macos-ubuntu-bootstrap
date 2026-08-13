"""Fail-closed coverage for the canonical repository script inventory."""

from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/ci/script_inventory.py"
SPEC = importlib.util.spec_from_file_location("script_inventory", MODULE_PATH)
assert SPEC and SPEC.loader
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)


def _contract() -> dict:
    return json.loads((ROOT / "config/script-inventory.json").read_text(encoding="utf-8"))


def _fixture(tmp_path: Path, data: dict | None = None) -> tuple[Path, Path, dict]:
    data = data or _contract()
    for entry in data["entries"]:
        source = ROOT / entry["path"]
        target = tmp_path / entry["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
        target.chmod(source.stat().st_mode & 0o777)
    contract = tmp_path / "inventory.json"
    contract.write_text(json.dumps(data), encoding="utf-8")
    return tmp_path, contract, data


def test_inventory_covers_tree_and_required_classifications() -> None:
    entries = inventory.validate()
    by_path = {entry["path"]: entry for entry in entries}
    for path in (
        "scripts/ci/run-clean-validation.sh",
        "scripts/ci/run-locked-test-audit.sh",
    ):
        assert by_path[path]["platform"] == "cross-platform"
        assert "macos-bash32" in by_path[path]["gates"]
    assert set(by_path) == inventory.source_paths(ROOT)


@pytest.mark.parametrize("mutation,match", [
    ("missing", "E_PATH_TREE_DRIFT"),
    ("extra", "E_PATH_TREE_DRIFT"),
    ("duplicate", "E_CARDINALITY_DUPLICATE_PATH"),
    ("wrong-platform", "E_ROLE_PLATFORM"),
    ("interpreter", "E_PATH_INTERPRETER"),
])
def test_inventory_rejects_tree_and_classification_drift(
    tmp_path: Path, mutation: str, match: str
) -> None:
    root, contract, data = _fixture(tmp_path)
    if mutation == "missing":
        data["entries"].pop()
    elif mutation == "extra":
        extra = root / "scripts/new-tool.sh"
        extra.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    elif mutation == "duplicate":
        data["entries"].append(dict(data["entries"][0]))
    elif mutation == "wrong-platform":
        entry = next(item for item in data["entries"] if item["path"] == "scripts/bootstrap.sh")
        entry["platform"] = "ubuntu"
    else:
        entry = next(item for item in data["entries"] if item["path"] == "scripts/bootstrap.sh")
        entry["interpreter"] = "bash-p"
    contract.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(inventory.InventoryError, match=match):
        inventory.validate(root=root, inventory=contract)


def test_inventory_rejects_deleted_and_renamed_paths(tmp_path: Path) -> None:
    root, contract, _ = _fixture(tmp_path)
    source = root / "scripts/bootstrap.sh"
    source.rename(root / "scripts/bootstrap-renamed.sh")
    with pytest.raises(inventory.InventoryError, match="E_PATH_MISSING"):
        inventory.validate(root=root, inventory=contract)


def test_inventory_gate_selection_has_no_duplicate_or_wrong_interpreter() -> None:
    entries = inventory.validate()
    shell = [entry for entry in entries if "shellcheck" in entry["gates"]]
    assert len(shell) == len({entry["path"] for entry in shell})
    assert all(entry["interpreter"] in {"bash", "bash-p"} for entry in shell)


@pytest.mark.parametrize("mutation,match", [
    ("missing-self", "E_CARDINALITY_SELF"),
    ("duplicate-self", "E_CARDINALITY_DUPLICATE_PATH"),
    ("unknown-launcher", "E_EDGE_TARGET"),
    ("cycle", "E_EDGE_CYCLE"),
    ("dependency-class", "E_ROLE_DEPENDENCY"),
    ("wrong-role", "E_ROLE_SELF"),
])
def test_inventory_rejects_invalid_self_hosting_graph(
    tmp_path: Path, mutation: str, match: str
) -> None:
    root, contract, data = _fixture(tmp_path)
    meta = next(item for item in data["entries"] if item["path"] == "scripts/ci/script_inventory.py")
    lint = next(item for item in data["entries"] if item["path"] == "scripts/ci/lint.sh")
    if mutation == "missing-self":
        data["entries"].remove(meta)
    elif mutation == "duplicate-self":
        data["entries"].append(dict(meta))
    elif mutation == "unknown-launcher":
        meta["launcher"] = "scripts/ci/not-present.py"
    elif mutation == "cycle":
        meta["launcher"] = "scripts/ci/lint.sh"
        lint["launcher"] = "scripts/ci/script_inventory.py"
    elif mutation == "dependency-class":
        meta["dependency_class"] = "ambient-python"
    else:
        meta["role"] = "ci-validation"
    contract.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(inventory.InventoryError, match=match):
        inventory.validate(root=root, inventory=contract)


def test_inventory_diagnostic_is_order_independent_and_uses_phase_precedence(
    tmp_path: Path,
) -> None:
    root, contract, data = _fixture(tmp_path)
    meta = next(item for item in data["entries"] if item["path"] == "scripts/ci/script_inventory.py")
    meta["launcher"] = "scripts/ci/not-present.py"
    meta["role"] = "ci-validation"
    contract.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(inventory.InventoryError) as first:
        inventory.validate(root=root, inventory=contract)
    data["entries"].reverse()
    contract.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(inventory.InventoryError) as second:
        inventory.validate(root=root, inventory=contract)
    assert first.value.code == second.value.code == "E_EDGE_TARGET"
    assert str(first.value) == str(second.value)


def test_shell_selection_receipt_is_sorted_unique_and_content_bound(tmp_path: Path) -> None:
    entries = inventory.validate()
    receipt = inventory.selection_receipt(entries, "shellcheck")
    paths = receipt["paths"]
    assert paths == sorted(set(paths))
    assert receipt["count"] == len(paths)
    payload = "".join(f"{path}\n" for path in paths).encode("utf-8")
    assert receipt["sha256"] == hashlib.sha256(payload).hexdigest()
    assert all(
        entry["interpreter"] in {"bash", "bash-p"}
        for entry in entries
        if entry["path"] in paths
    )
    path = tmp_path / "receipt.json"
    path.write_text(json.dumps(receipt), encoding="utf-8")
    assert inventory.load_receipt(path, entries) == receipt


@pytest.mark.parametrize("mutation", ["missing", "duplicate", "stale", "reordered", "hash"])
def test_shell_selection_receipt_rejects_subject_drift(
    tmp_path: Path, mutation: str
) -> None:
    entries = inventory.validate()
    receipt = inventory.selection_receipt(entries, "shellcheck")
    if mutation == "missing":
        receipt["paths"].pop()
    elif mutation == "duplicate":
        receipt["paths"].append(receipt["paths"][0])
    elif mutation == "stale":
        receipt["paths"].append("scripts/deleted.sh")
    elif mutation == "reordered":
        receipt["paths"].reverse()
    else:
        receipt["sha256"] = "0" * 64
    path = tmp_path / "receipt.json"
    path.write_text(json.dumps(receipt), encoding="utf-8")
    with pytest.raises(inventory.InventoryError, match="E_RECEIPT_DRIFT"):
        inventory.load_receipt(path, entries)


def test_inventory_rejects_non_shell_subject_out_of_root_injection_and_symlink(
    tmp_path: Path,
) -> None:
    root, contract, data = _fixture(tmp_path)
    python_entry = next(item for item in data["entries"] if item["interpreter"] == "python")
    python_entry["gates"].append("shellcheck")
    contract.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(inventory.InventoryError, match="E_ROLE_GATES"):
        inventory.validate(root=root, inventory=contract)

    root, contract, data = _fixture(tmp_path / "escape")
    data["entries"][0]["path"] = "scripts/../outside.sh;touch-owned"
    contract.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(inventory.InventoryError, match="E_SCHEMA_PATH"):
        inventory.validate(root=root, inventory=contract)

    root, contract, data = _fixture(tmp_path / "symlink")
    target = root / data["entries"][0]["path"]
    replacement = root / "outside-owned.sh"
    replacement.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    target.unlink()
    target.symlink_to(replacement)
    with pytest.raises(inventory.InventoryError, match="E_PATH_KIND"):
        inventory.validate(root=root, inventory=contract)
