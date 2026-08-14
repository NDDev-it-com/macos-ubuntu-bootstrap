#!/usr/bin/env python3
"""Verify the downloaded platform-evidence artifacts against the matrix.

The ``evidence-gate`` job used to read four ``needs.*.result`` values and never
open an artifact, so it could not tell a lane that proved its claims from a lane
that merely restated them. Adding such a gate to the required checks would have
made a declaration mandatory, not a proof.

This is what the gate runs instead. Given the directory that
``actions/download-artifact`` populated, it requires:

1. exactly ``expected_hosted_artifact_instances`` evidence payloads;
2. the observed ``(lane, architecture)`` set to equal the matrix's expansion, so
   a dropped runner reduces the set and fails rather than silently reducing
   coverage;
3. every payload's ``result`` to be ``success``;
4. every payload's declared capabilities to match the matrix for its lane --
   the payload is a copy, and a copy can be edited;
5. every payload's ``observed_steps`` to cover every step its REQUIRED
   capabilities declare, which is the part the lane had to actually execute;
6. every payload's ``not_proven`` list to equal the matrix's NOT_PROVEN
   capability ids for that lane, so an unproven capability cannot be quietly
   dropped from the artifact;
7. every payload to carry the exact SHA the run was dispatched for.

Exit status is 0 only if all of that holds for every artifact.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]

# Loaded by path rather than by mutating sys.path: this script lives one
# directory below support_evidence.py, and the tests load it the same way.
_SPEC = importlib.util.spec_from_file_location(
    "support_evidence", ROOT / "scripts" / "support_evidence.py"
)
assert _SPEC is not None and _SPEC.loader is not None
support_evidence = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(support_evidence)


class GateError(RuntimeError):
    """The downloaded evidence does not support what the matrix declares."""


def expected_instances(matrix: dict[str, Any]) -> set[tuple[str, str]]:
    """Every (lane, canonical architecture) pair the matrix expects to see."""
    pairs: set[tuple[str, str]] = set()
    for lane in matrix["evidence_lanes"]:
        for arch in lane["architectures"]:
            pairs.add((lane["lane"], support_evidence.canonical_arch(arch)))
    return pairs


def load_payloads(root: Path) -> list[tuple[Path, dict[str, Any]]]:
    payloads: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(root.rglob("evidence.json")):
        try:
            payloads.append((path, json.loads(path.read_text(encoding="utf-8"))))
        except (OSError, json.JSONDecodeError) as exc:
            raise GateError(f"{path}: unreadable evidence payload: {exc}") from exc
    if not payloads:
        raise GateError(f"no evidence.json found under {root}")
    return payloads


def check_payload(
    path: Path, payload: dict[str, Any], matrix: dict[str, Any], sha: str | None
) -> tuple[str, str]:
    lane_name = payload.get("lane")
    if not isinstance(lane_name, str):
        raise GateError(f"{path}: payload declares no lane")
    arch = payload.get("composition", {}).get("architecture")
    if not isinstance(arch, str):
        raise GateError(f"{path}: payload declares no composition architecture")

    try:
        lane = support_evidence.resolve_lane(matrix, lane_name, arch)
    except support_evidence.MatrixError as exc:
        raise GateError(f"{path}: {exc}") from exc

    if payload.get("result") != "success":
        raise GateError(f"{path}: lane {lane_name}/{arch} result is {payload.get('result')!r}")

    if sha is not None and payload.get("sha") != sha:
        raise GateError(
            f"{path}: lane {lane_name}/{arch} carries sha {payload.get('sha')!r}, expected {sha!r}"
        )

    declared = lane["capabilities"]
    reported = payload.get("capabilities")
    if reported != declared:
        raise GateError(
            f"{path}: lane {lane_name}/{arch} capabilities do not match the matrix declaration"
        )

    needed = support_evidence.required_observations(declared)
    observed = set(payload.get("observed_steps") or [])
    missing = sorted(needed - observed)
    if missing:
        raise GateError(
            f"{path}: lane {lane_name}/{arch} claims REQUIRED capabilities it did not "
            f"observe: {', '.join(missing)}"
        )

    expected_not_proven = sorted(
        capability["id"] for capability in declared if capability["status"] == "NOT_PROVEN"
    )
    if sorted(payload.get("not_proven") or []) != expected_not_proven:
        raise GateError(
            f"{path}: lane {lane_name}/{arch} not_proven is "
            f"{sorted(payload.get('not_proven') or [])}, expected {expected_not_proven}"
        )

    return lane_name, support_evidence.canonical_arch(arch)


def verify(root: Path, *, sha: str | None = None) -> int:
    matrix = support_evidence.load_json(support_evidence.DEFAULT_MATRIX)
    contract = support_evidence.load_json(support_evidence.DEFAULT_CONTRACT)
    support_evidence.validate_matrix(matrix, contract)

    payloads = load_payloads(root)
    seen: set[tuple[str, str]] = set()
    for path, payload in payloads:
        key = check_payload(path, payload, matrix, sha)
        if key in seen:
            raise GateError(f"{path}: duplicate evidence for lane {key[0]} on {key[1]}")
        seen.add(key)

    declared_total = matrix["expected_hosted_artifact_instances"]
    if len(payloads) != declared_total:
        raise GateError(
            f"expected {declared_total} evidence payloads, downloaded {len(payloads)}"
        )

    expected = expected_instances(matrix)
    if seen != expected:
        raise GateError(
            "evidence instance drift: "
            f"missing={sorted(expected - seen)} unexpected={sorted(seen - expected)}"
        )

    print(f"evidence-artifacts-ok: {len(payloads)} lanes")
    for lane_name, arch in sorted(seen):
        print(f"  {lane_name} [{arch}]")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="directory the artifacts were downloaded into")
    parser.add_argument("--sha", default=None, help="exact SHA every payload must carry")
    args = parser.parse_args(argv)
    return verify(args.root, sha=args.sha or None)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (GateError, support_evidence.MatrixError, OSError) as exc:
        print(f"evidence-artifacts-error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
