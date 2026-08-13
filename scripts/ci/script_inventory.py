#!/usr/bin/env python3
"""Validate and query the canonical repository script classification."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import sys

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INVENTORY = ROOT / "config/script-inventory.json"
SCHEMA = "rldyour.script-inventory/v1"
PLATFORMS = {"cross-platform", "macos", "ubuntu"}
ROLES = {"runtime-entrypoint", "runtime-installer", "runtime-library", "runtime-verifier", "ci-validation", "ci-evidence", "internal-test-tooling", "inventory-meta-tool", "privilege-library", "root-helper"}
INTERPRETERS = {"bash", "bash-p", "python"}
DEPENDENCY_CLASSES = {"system-shell", "runtime-stdlib", "test-stdlib", "locked-test-tooling"}
LAUNCHERS = {"direct", "sourced", "isolated-python", "managed-root-helper", "scripts/ci/run-locked-test-audit.sh"}
EVIDENCE = {"native-host", "hosted", "structural"}
GATES = {"shell-syntax", "shellcheck", "macos-bash32", "python-compile", "dry-run", "runtime-verify", "security-contract", "clean-validation", "locked-python-audit", "hosted-matrix"}
RECEIPT_SCHEMA = "rldyour.script-selection/v1"


class InventoryError(RuntimeError):
    def __init__(self, code: str, path: str, detail: str):
        self.code = code
        self.path = path
        self.detail = detail
        super().__init__(f"{code}:{path}: {detail}")


def fail(code: str, path: str, detail: str) -> None:
    raise InventoryError(code, path, detail)


def fail_phase(diagnostics: list[tuple[str, str, str]]) -> None:
    if diagnostics:
        code, path, detail = sorted(diagnostics)[0]
        fail(code, path, detail)


def source_paths(root: Path) -> set[str]:
    result: set[str] = set()
    for path in (root / "scripts").rglob("*"):
        if not path.is_file() or "__pycache__" in path.parts:
            continue
        head = path.read_bytes()[:256]
        if path.suffix in {".sh", ".py"} or head.startswith(b"#!"):
            result.add(path.relative_to(root).as_posix())
    return result


def load(path: Path = DEFAULT_INVENTORY) -> list[dict[str, object]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InventoryError("E_SCHEMA", str(path), f"unavailable or malformed: {exc}") from exc
    if data.get("schema") != SCHEMA or not isinstance(data.get("entries"), list):
        fail("E_SCHEMA", str(path), "schema/version or entries type is invalid")
    return data["entries"]


def validate(root: Path = ROOT, inventory: Path = DEFAULT_INVENTORY) -> list[dict[str, object]]:
    entries = load(inventory)
    required = {"path", "platform", "role", "interpreter", "dependency_class", "launcher", "evidence", "gates"}
    schema_errors: list[tuple[str, str, str]] = []
    seen: set[str] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) != required:
            schema_errors.append(("E_SCHEMA_FIELDS", f"entries[{index}]", "entry must contain exactly the typed fields"))
            continue
        path = entry["path"]
        parts = Path(path).parts if isinstance(path, str) else ()
        if not isinstance(path, str) or not re.fullmatch(r"scripts/[A-Za-z0-9_./-]+", path) or ".." in parts or "." in parts or "//" in path:
            schema_errors.append(("E_SCHEMA_PATH", f"entries[{index}]", f"invalid script path: {path!r}"))
            continue
        if path in seen:
            schema_errors.append(("E_CARDINALITY_DUPLICATE_PATH", path, "path must have exactly one record"))
            continue
        seen.add(path)
        if not all(isinstance(entry[key], str) for key in ("platform", "role", "interpreter", "dependency_class", "launcher", "evidence")) or not isinstance(entry["gates"], list) or not all(isinstance(gate, str) for gate in entry["gates"]):
            schema_errors.append(("E_SCHEMA_TYPES", path, "classification fields have invalid types"))
    fail_phase(schema_errors)
    self_count = sum(entry["path"] == "scripts/ci/script_inventory.py" for entry in entries)
    if self_count != 1:
        fail("E_CARDINALITY_SELF", "scripts/ci/script_inventory.py", f"expected exactly one self-entry, found {self_count}")

    path_errors: list[tuple[str, str, str]] = []
    for entry in entries:
        path = entry["path"]
        target = root / path
        try:
            info = target.lstat()
        except FileNotFoundError:
            path_errors.append(("E_PATH_MISSING", path, "declared script is missing"))
            continue
        if not stat.S_ISREG(info.st_mode):
            path_errors.append(("E_PATH_KIND", path, "declared script is not a regular file"))
            continue
        first = target.read_bytes().splitlines()[:1]
        expected = {"bash": b"#!/usr/bin/env bash", "bash-p": b"#!/bin/bash -p"}.get(entry["interpreter"])
        if expected is not None and first != [expected]:
            path_errors.append(("E_PATH_INTERPRETER", path, "interpreter/shebang mismatch"))
        if entry["interpreter"] == "python" and first and first[0].startswith(b"#!") and b"python3" not in first[0]:
            path_errors.append(("E_PATH_INTERPRETER", path, "interpreter/shebang mismatch"))
    actual = source_paths(root)
    if seen != actual:
        path_errors.append(("E_PATH_TREE_DRIFT", "scripts/", f"unclassified={sorted(actual-seen)} stale={sorted(seen-actual)}"))
    fail_phase(path_errors)

    edges = {
        entry["path"]: entry["launcher"]
        for entry in entries
        if isinstance(entry["launcher"], str) and entry["launcher"].startswith("scripts/")
    }
    edge_errors = [("E_EDGE_TARGET", origin, f"unknown launcher target: {target}") for origin, target in edges.items() if target not in seen]
    fail_phase(edge_errors)
    cycle_errors: list[tuple[str, str, str]] = []
    for origin, target in sorted(edges.items()):
        visited = {origin}
        cursor = target
        while cursor in edges:
            if cursor in visited:
                cycle_errors.append(("E_EDGE_CYCLE", origin, f"launcher cycle contains {cursor}"))
                break
            visited.add(cursor)
            cursor = edges[cursor]
    fail_phase(cycle_errors)

    role_errors: list[tuple[str, str, str]] = []
    for entry in entries:
        path = entry["path"]
        launcher = entry["launcher"]
        gates = entry["gates"]
        if entry["platform"] not in PLATFORMS or entry["role"] not in ROLES or entry["interpreter"] not in INTERPRETERS or entry["evidence"] not in EVIDENCE:
            role_errors.append(("E_ROLE_CLASSIFICATION", path, "unknown platform, role, interpreter, or evidence class"))
        if entry["dependency_class"] not in DEPENDENCY_CLASSES or (launcher not in LAUNCHERS and not launcher.startswith("scripts/")):
            role_errors.append(("E_ROLE_DEPENDENCY", path, "unknown dependency class or launcher"))
        if entry["interpreter"] == "python" and entry["dependency_class"] == "system-shell":
            role_errors.append(("E_ROLE_DEPENDENCY", path, "Python tool has shell dependency class"))
        if entry["interpreter"] in {"bash", "bash-p"} and entry["dependency_class"] != "system-shell":
            role_errors.append(("E_ROLE_DEPENDENCY", path, "shell tool has non-shell dependency class"))
        if entry["dependency_class"] == "locked-test-tooling" and launcher != "scripts/ci/run-locked-test-audit.sh":
            role_errors.append(("E_ROLE_LAUNCHER", path, "locked tool must use the locked audit launcher"))
        if len(gates) != len(set(gates)) or not gates or not set(gates) <= GATES:
            role_errors.append(("E_ROLE_GATES", path, "duplicate, empty, or unknown gates"))
        if entry["interpreter"] in {"bash", "bash-p"} and not {"shell-syntax", "shellcheck"} <= set(gates):
            role_errors.append(("E_ROLE_GATES", path, "shell script lacks mandatory lint gates"))
        if entry["interpreter"] == "python" and "python-compile" not in gates:
            role_errors.append(("E_ROLE_GATES", path, "Python script lacks compile gate"))
        if "shellcheck" in gates and entry["interpreter"] not in {"bash", "bash-p"}:
            role_errors.append(("E_ROLE_GATES", path, "non-shell tool cannot be a ShellCheck subject"))
        if "macos-bash32" in gates and entry["platform"] == "ubuntu":
            role_errors.append(("E_ROLE_PLATFORM", path, "Ubuntu-only script claims macOS Bash evidence"))
    self_entry = next(entry for entry in entries if entry["path"] == "scripts/ci/script_inventory.py")
    if (self_entry["role"], self_entry["dependency_class"], self_entry["launcher"]) != ("inventory-meta-tool", "runtime-stdlib", "isolated-python"):
        role_errors.append(("E_ROLE_SELF", self_entry["path"], "meta-tool role/dependency/launcher invariant is invalid"))
    fail_phase(role_errors)
    return entries


def selected(entries: list[dict[str, object]], gate: str) -> list[str]:
    paths = sorted(entry["path"] for entry in entries if gate in entry["gates"])
    if not paths:
        fail("E_SELECTION_EMPTY", gate, "gate selected no scripts")
    return paths


def selection_receipt(entries: list[dict[str, object]], gate: str) -> dict[str, object]:
    paths = selected(entries, gate)
    payload = "".join(f"{path}\n" for path in paths).encode("utf-8")
    return {
        "schema": RECEIPT_SCHEMA,
        "inventory_schema": SCHEMA,
        "gate": gate,
        "count": len(paths),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "paths": paths,
    }


def load_receipt(path: Path, entries: list[dict[str, object]]) -> dict[str, object]:
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InventoryError("E_RECEIPT_SCHEMA", str(path), f"unavailable or malformed: {exc}") from exc
    fields = {"schema", "inventory_schema", "gate", "count", "sha256", "paths"}
    if not isinstance(receipt, dict) or set(receipt) != fields or receipt.get("schema") != RECEIPT_SCHEMA or receipt.get("inventory_schema") != SCHEMA:
        fail("E_RECEIPT_SCHEMA", str(path), "receipt fields or schema are invalid")
    gate = receipt.get("gate")
    paths = receipt.get("paths")
    if gate not in GATES or not isinstance(paths, list) or not all(isinstance(item, str) for item in paths):
        fail("E_RECEIPT_SCHEMA", str(path), "receipt gate or paths are invalid")
    expected = selection_receipt(entries, gate)
    if receipt != expected:
        fail("E_RECEIPT_DRIFT", str(path), "receipt count, hash, paths, or current selection differ")
    return receipt


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "list", "receipt", "paths"))
    parser.add_argument("--gate", choices=sorted(GATES))
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args(argv)
    try:
        entries = validate(inventory=args.inventory)
    except InventoryError as exc:
        print(f"script-inventory: {exc}", file=sys.stderr)
        return 1
    if args.command == "validate":
        print(f"script-inventory-ok:{len(entries)}")
    elif args.command == "list":
        for path in selected(entries, args.gate) if args.gate else sorted(entry["path"] for entry in entries):
            print(path)
    elif args.command == "receipt":
        if args.gate is None:
            parser.error("receipt requires --gate")
        print(json.dumps(selection_receipt(entries, args.gate), sort_keys=True, separators=(",", ":")))
    else:
        if args.receipt is None:
            parser.error("paths requires --receipt")
        receipt = load_receipt(args.receipt, entries)
        for path in receipt["paths"]:
            print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
