#!/usr/bin/env python3
"""Validate and resolve the bootstrap support/evidence contract."""

from __future__ import annotations

import argparse
import json
import os
import platform
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MATRIX = ROOT / "config" / "support-evidence-matrix.json"
DEFAULT_CONTRACT = ROOT / "config" / "rldyour-contract.json"


class MatrixError(ValueError):
    """The matrix is ambiguous, incomplete, or overstates evidence."""


def load_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise MatrixError(f"{path}: root must be an object")
    return data


def canonical_arch(value: str) -> str:
    aliases = {"x64": "amd64", "x86_64": "amd64", "amd64": "amd64", "arm64": "arm64", "aarch64": "arm64"}
    try:
        return aliases[value.lower()]
    except KeyError as exc:
        raise MatrixError(f"unsupported evidence architecture: {value or 'empty'}") from exc


def validate_matrix(matrix: dict[str, Any], contract: dict[str, Any]) -> None:
    if matrix.get("schema_version") != 1:
        raise MatrixError("matrix schema_version must be 1")
    if matrix.get("adapter_version") != contract.get("adapter", {}).get("version"):
        raise MatrixError("matrix adapter_version must match rldyour contract")
    evidence_contract = contract.get("support_evidence", {})
    if evidence_contract.get("path") != "config/support-evidence-matrix.json" or evidence_contract.get("schema_version") != 1:
        raise MatrixError("rldyour contract support_evidence reference drift")
    statuses = set(matrix.get("status_vocabulary", []))
    support_statuses = set(matrix.get("support_vocabulary", []))
    tiers = set(matrix.get("evidence_tiers", []))
    if statuses != {"PROVEN", "NOT_PROVEN", "UNSUPPORTED_EXPECTED"}:
        raise MatrixError("status vocabulary is not canonical")
    if support_statuses != {"SUPPORTED", "UNSUPPORTED", "UNSUPPORTED_FAIL_CLOSED"}:
        raise MatrixError("support vocabulary is not canonical")
    expected_tiers = {"HOSTED_NATIVE", "DISPOSABLE_SYSTEMD_CONTAINER", "STRUCTURAL", "EXPECTED_FAIL_CLOSED", "REAL_HOST_REQUIRED"}
    if tiers != expected_tiers:
        raise MatrixError("evidence tier vocabulary is not canonical")
    steps_vocabulary = matrix.get("observable_step_vocabulary")
    if not isinstance(steps_vocabulary, list) or not steps_vocabulary:
        raise MatrixError("observable_step_vocabulary must be a non-empty list")
    if len(set(steps_vocabulary)) != len(steps_vocabulary):
        raise MatrixError("observable_step_vocabulary has duplicates")

    compositions = matrix.get("support_compositions")
    lanes = matrix.get("evidence_lanes")
    if not isinstance(compositions, list) or not compositions:
        raise MatrixError("support_compositions must be a non-empty list")
    if not isinstance(lanes, list) or not lanes:
        raise MatrixError("evidence_lanes must be a non-empty list")
    gaps = matrix.get("known_evidence_gaps")
    if not isinstance(gaps, list) or not gaps:
        raise MatrixError("known_evidence_gaps must be a non-empty list")
    gap_ids: set[str] = set()
    for gap in gaps:
        identity = gap.get("id")
        if not isinstance(identity, str) or not identity or identity in gap_ids:
            raise MatrixError(f"duplicate or invalid evidence gap: {identity!r}")
        gap_ids.add(identity)
        if gap.get("requirement") != "OPTIONAL" or gap.get("status") != "NOT_PROVEN":
            raise MatrixError(f"{identity}: evidence gaps must be OPTIONAL NOT_PROVEN")
        if gap.get("required_tier") not in tiers or not isinstance(gap.get("tracking_issue"), int):
            raise MatrixError(f"{identity}: evidence gap tier and tracking issue are required")
    audits = matrix.get("installation_audit")
    if not isinstance(audits, list) or not audits:
        raise MatrixError("installation_audit must be a non-empty list")
    audit_ids: set[str] = set()
    audit_fields = {"id", "inventory_ref", "source", "version_discovery", "integrity", "architectures", "idempotency", "partial_failure", "update_policy"}
    for audit in audits:
        identity = audit.get("id")
        if not isinstance(identity, str) or not identity or identity in audit_ids:
            raise MatrixError(f"duplicate or invalid installation audit id: {identity!r}")
        audit_ids.add(identity)
        if not audit_fields <= set(audit):
            raise MatrixError(f"{identity}: incomplete installation audit fields")
        if not isinstance(audit.get("architectures"), list) or not audit["architectures"]:
            raise MatrixError(f"{identity}: installation audit architectures must be non-empty")
    composition_ids: set[str] = set()
    for item in compositions:
        identity = item.get("id")
        if not isinstance(identity, str) or not identity or identity in composition_ids:
            raise MatrixError(f"duplicate or invalid composition id: {identity!r}")
        composition_ids.add(identity)
        if item.get("support") not in support_statuses:
            raise MatrixError(f"{identity}: invalid support status")
        for field in ("releases", "architectures", "profiles", "gui_modes", "docker_modes", "apply_privilege", "interaction"):
            if not isinstance(item.get(field), list) or not item[field]:
                raise MatrixError(f"{identity}: {field} must be non-empty")

    lane_ids: set[str] = set()
    for lane in lanes:
        identity = lane.get("lane")
        if not isinstance(identity, str) or not identity or identity in lane_ids:
            raise MatrixError(f"duplicate or invalid evidence lane: {identity!r}")
        lane_ids.add(identity)
        if lane.get("tier") not in tiers - {"REAL_HOST_REQUIRED"}:
            raise MatrixError(f"{identity}: invalid executable evidence tier")
        architectures = lane.get("architectures")
        if not isinstance(architectures, list) or not architectures:
            raise MatrixError(f"{identity}: architectures must be non-empty")
        if len({canonical_arch(value) for value in architectures}) != len(architectures):
            raise MatrixError(f"{identity}: duplicate architecture aliases")
        capabilities = lane.get("capabilities")
        if not isinstance(capabilities, list) or not capabilities:
            raise MatrixError(f"{identity}: capabilities must be non-empty")
        capability_ids: set[str] = set()
        for capability in capabilities:
            capability_id = capability.get("id")
            requirement = capability.get("requirement")
            status = capability.get("status")
            if not isinstance(capability_id, str) or not capability_id or capability_id in capability_ids:
                raise MatrixError(f"{identity}: duplicate or invalid capability id {capability_id!r}")
            capability_ids.add(capability_id)
            if requirement not in {"REQUIRED", "OPTIONAL"} or status not in statuses:
                raise MatrixError(f"{identity}/{capability_id}: invalid requirement or status")
            if requirement == "REQUIRED" and status != "PROVEN":
                raise MatrixError(f"{identity}/{capability_id}: REQUIRED capability must be PROVEN")
            if status == "NOT_PROVEN" and capability.get("required_tier") != "REAL_HOST_REQUIRED":
                raise MatrixError(f"{identity}/{capability_id}: NOT_PROVEN must name REAL_HOST_REQUIRED")
            if status == "PROVEN" and "required_tier" in capability:
                raise MatrixError(f"{identity}/{capability_id}: PROVEN cannot claim a different required tier")
            # A REQUIRED capability must name the steps a lane has to record for
            # it. Without this the runtime check below is a tautology: the
            # validator already refuses REQUIRED + not-PROVEN, so the matrix
            # cannot express the state the runtime check guarded against, and
            # the gate could only ever confirm a declaration.
            steps = capability.get("observable_steps")
            if requirement == "REQUIRED":
                if not isinstance(steps, list) or not steps:
                    raise MatrixError(f"{identity}/{capability_id}: REQUIRED capability must declare observable_steps")
                if len(set(steps)) != len(steps):
                    raise MatrixError(f"{identity}/{capability_id}: duplicate observable step")
                unknown = sorted(set(steps) - set(matrix.get("observable_step_vocabulary", [])))
                if unknown:
                    raise MatrixError(f"{identity}/{capability_id}: observable steps outside the vocabulary: {unknown}")
            elif steps is not None:
                raise MatrixError(f"{identity}/{capability_id}: only REQUIRED capabilities are observed")

    required_lanes = {
        "macos-gui", "macos-no-gui", "ubuntu-desktop-no-gui", "ubuntu-arm-gui-refusal",
        "sandbox-desktop-builds-rootful", "sandbox-server-none", "sandbox-server-rootful",
        "sandbox-server-rootless", "sandbox-server-hardening",
    }
    if lane_ids != required_lanes:
        raise MatrixError(f"evidence lane set drift: missing={sorted(required_lanes-lane_ids)} extra={sorted(lane_ids-required_lanes)}")
    artifact_instances = sum(len({canonical_arch(value) for value in lane["architectures"]}) for lane in lanes)
    if artifact_instances != matrix.get("expected_hosted_artifact_instances"):
        raise MatrixError(
            f"hosted artifact instance drift: declared={matrix.get('expected_hosted_artifact_instances')} computed={artifact_instances}"
        )

    targets = contract.get("targets", {})
    if set(targets.get("ubuntu", {}).get("releases", [])) != {"24.04", "26.04"}:
        raise MatrixError("Ubuntu release contract drift")
    if set(targets.get("ubuntu", {}).get("architectures", [])) != {"amd64", "arm64"}:
        raise MatrixError("Ubuntu architecture contract drift")
    if targets.get("macos", {}).get("architectures") != ["arm64"]:
        raise MatrixError("macOS architecture contract drift")


def resolve_lane(matrix: dict[str, Any], lane_name: str, arch: str) -> dict[str, Any]:
    matches = [item for item in matrix["evidence_lanes"] if item["lane"] == lane_name]
    if len(matches) != 1:
        raise MatrixError(f"unknown or ambiguous evidence lane: {lane_name}")
    lane = matches[0]
    canonical = canonical_arch(arch)
    allowed = {canonical_arch(value) for value in lane["architectures"]}
    if canonical not in allowed:
        raise MatrixError(f"{lane_name}: architecture {canonical} is not declared")
    return {**lane, "architecture": canonical}


def required_observations(capabilities: list[dict[str, Any]]) -> set[str]:
    """Every step a lane must record for its REQUIRED capabilities."""
    needed: set[str] = set()
    for capability in capabilities:
        if capability.get("requirement") == "REQUIRED":
            needed |= set(capability.get("observable_steps") or [])
    return needed


def finalize_evidence(
    payload: dict[str, Any],
    result: str,
    observed_steps: list[str] | None = None,
) -> dict[str, Any]:
    """Close an evidence payload, requiring the lane to have observed its claims.

    ``capabilities`` is copied from the matrix declaration, so checking it
    against the matrix proves only that the copy is faithful. ``observed_steps``
    is different: the lane script appends a step name after the command that
    proves it returns successfully, so the list describes what the runner did.
    A successful lane whose observations do not cover every step its REQUIRED
    capabilities declare is a lane that claimed more than it ran.
    """
    if result not in {"success", "failure"}:
        raise MatrixError(f"invalid execution result: {result}")
    capabilities = payload.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        raise MatrixError("evidence payload has no capabilities")
    if result == "success":
        for capability in capabilities:
            if capability.get("requirement") == "REQUIRED" and capability.get("status") != "PROVEN":
                raise MatrixError(f"successful lane left REQUIRED capability unproven: {capability.get('id')}")
        observed = set(observed_steps or [])
        missing = sorted(required_observations(capabilities) - observed)
        if missing:
            raise MatrixError(
                "successful lane did not observe every REQUIRED step: " + ", ".join(missing)
            )
    payload["result"] = result
    payload["observed_steps"] = sorted(set(observed_steps or []))
    return payload


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", type=Path, default=DEFAULT_MATRIX)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")
    resolve = subparsers.add_parser("resolve")
    resolve.add_argument("--lane", required=True)
    resolve.add_argument("--arch", default=os.environ.get("RUNNER_ARCH") or platform.machine())
    args = parser.parse_args(argv)
    matrix = load_json(args.matrix)
    contract = load_json(args.contract)
    validate_matrix(matrix, contract)
    if args.command == "validate":
        print("support-evidence-matrix-ok")
        return 0
    print(json.dumps(resolve_lane(matrix, args.lane, args.arch), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (MatrixError, OSError, json.JSONDecodeError) as exc:
        print(f"support-evidence-error: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
