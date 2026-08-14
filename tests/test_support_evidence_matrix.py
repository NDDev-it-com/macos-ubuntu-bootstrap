from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("support_evidence", ROOT / "scripts/support_evidence.py")
assert SPEC and SPEC.loader
support_evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(support_evidence)

MATRIX = json.loads((ROOT / "config/support-evidence-matrix.json").read_text(encoding="utf-8"))
CONTRACT = json.loads((ROOT / "config/rldyour-contract.json").read_text(encoding="utf-8"))


def test_canonical_matrix_validates_and_is_deterministic() -> None:
    support_evidence.validate_matrix(MATRIX, CONTRACT)
    assert CONTRACT["support_evidence"]["path"] == "config/support-evidence-matrix.json"
    first = support_evidence.resolve_lane(MATRIX, "ubuntu-desktop-no-gui", "x86_64", "24.04")
    second = support_evidence.resolve_lane(MATRIX, "ubuntu-desktop-no-gui", "AMD64", "24.04")
    assert first == second
    assert json.dumps(first, sort_keys=True) == json.dumps(second, sort_keys=True)


@pytest.mark.parametrize("arch,expected", [("x64", "amd64"), ("aarch64", "arm64")])
def test_architecture_aliases_are_explicit(arch: str, expected: str) -> None:
    assert support_evidence.resolve_lane(MATRIX, "ubuntu-desktop-no-gui", arch)["architecture"] == expected


def test_unknown_lane_and_unsupported_architecture_fail_closed() -> None:
    with pytest.raises(support_evidence.MatrixError, match="unknown or ambiguous"):
        support_evidence.resolve_lane(MATRIX, "invented", "arm64")
    with pytest.raises(support_evidence.MatrixError, match="not declared"):
        support_evidence.resolve_lane(MATRIX, "sandbox-server-rootless", "arm64")
    with pytest.raises(support_evidence.MatrixError, match="unsupported evidence architecture"):
        support_evidence.resolve_lane(MATRIX, "macos-gui", "riscv64")


def test_duplicate_lane_and_composition_fail_closed() -> None:
    duplicate_lane = copy.deepcopy(MATRIX)
    duplicate_lane["evidence_lanes"].append(copy.deepcopy(duplicate_lane["evidence_lanes"][0]))
    with pytest.raises(support_evidence.MatrixError, match="duplicate or invalid evidence lane"):
        support_evidence.validate_matrix(duplicate_lane, CONTRACT)
    duplicate_composition = copy.deepcopy(MATRIX)
    duplicate_composition["support_compositions"].append(copy.deepcopy(duplicate_composition["support_compositions"][0]))
    with pytest.raises(support_evidence.MatrixError, match="duplicate or invalid composition"):
        support_evidence.validate_matrix(duplicate_composition, CONTRACT)


def test_missing_lane_coverage_fails_closed() -> None:
    matrix = copy.deepcopy(MATRIX)
    matrix["evidence_lanes"] = matrix["evidence_lanes"][:-1]
    with pytest.raises(support_evidence.MatrixError, match="lane set drift"):
        support_evidence.validate_matrix(matrix, CONTRACT)


def test_known_gaps_are_typed_optional_and_tracked() -> None:
    assert {gap["tracking_issue"] for gap in MATRIX["known_evidence_gaps"]} == {55, 56, 57}
    assert all(gap["requirement"] == "OPTIONAL" for gap in MATRIX["known_evidence_gaps"])
    assert all(gap["status"] == "NOT_PROVEN" for gap in MATRIX["known_evidence_gaps"])
    assert {gap["id"] for gap in MATRIX["known_evidence_gaps"]} >= {
        "ubuntu-26.04-hosted-runtime", "interactive-privilege-prompts",
        "reboot-gui-live-ssh-firewall", "ubuntu-amd64-gui-runtime",
        "ubuntu-arm64-rootless-runtime",
    }


def test_declared_hosted_artifact_count_matches_the_matrix_expansion() -> None:
    assert MATRIX["expected_hosted_artifact_instances"] == 21
    # One artifact per (lane, release, architecture): release is part of the
    # expansion so a 24.04 result cannot stand in for its 26.04 twin.
    assert sum(
        len(lane["architectures"]) * len(lane["releases"])
        for lane in MATRIX["evidence_lanes"]
    ) == 21


def test_installation_audit_covers_every_contract_install_domain() -> None:
    audit_ids = {item["id"] for item in MATRIX["installation_audit"]}
    assert {
        "ai-cli-codex", "ai-cli-claude-code", "ai-cli-grok-build",
        "macos-homebrew-formulae-and-casks", "ubuntu-apt-baseline",
        "ubuntu-pinned-source-tools", "ubuntu-node-uv-bun",
        "ubuntu-go-gopls-rust-dart", "herdr", "google-chrome", "rustdesk",
        "telegram", "terminal-git-payloads", "ubuntu-docker",
        "ubuntu-server-hardening",
    } == audit_ids


def test_required_unproven_and_tier_escalation_fail_closed() -> None:
    required_unproven = copy.deepcopy(MATRIX)
    capability = required_unproven["evidence_lanes"][0]["capabilities"][0]
    capability["status"] = "NOT_PROVEN"
    capability["required_tier"] = "REAL_HOST_REQUIRED"
    with pytest.raises(support_evidence.MatrixError, match="REQUIRED capability must be PROVEN"):
        support_evidence.validate_matrix(required_unproven, CONTRACT)

    escalation = copy.deepcopy(MATRIX)
    optional = escalation["evidence_lanes"][0]["capabilities"][1]
    optional["status"] = "PROVEN"
    with pytest.raises(support_evidence.MatrixError, match="PROVEN cannot claim"):
        support_evidence.validate_matrix(escalation, CONTRACT)


def test_optional_not_proven_is_honest_and_does_not_weaken_required_gate() -> None:
    lane = support_evidence.resolve_lane(MATRIX, "macos-gui", "arm64", "runner-image")
    payload = {"capabilities": copy.deepcopy(lane["capabilities"])}
    observed = sorted(support_evidence.required_observations(lane["capabilities"]))
    result = support_evidence.finalize_evidence(payload, "success", observed)
    assert result["result"] == "success"
    assert any(item["status"] == "NOT_PROVEN" for item in result["capabilities"])
    assert all(item["status"] == "PROVEN" for item in result["capabilities"] if item["requirement"] == "REQUIRED")


def test_finalize_rejects_success_with_required_unproven() -> None:
    payload = {"capabilities": [{"id": "core", "requirement": "REQUIRED", "status": "NOT_PROVEN"}]}
    with pytest.raises(support_evidence.MatrixError, match="left REQUIRED capability unproven"):
        support_evidence.finalize_evidence(payload, "success")


def test_workflow_and_runner_script_lane_sets_match_matrix() -> None:
    workflow = (ROOT / ".github/workflows/platform-evidence.yml").read_text(encoding="utf-8")
    runner = (ROOT / "scripts/ci/platform-evidence.sh").read_text(encoding="utf-8")
    for lane in MATRIX["evidence_lanes"]:
        assert lane["lane"] in workflow
        assert lane["lane"] in runner


# --------------------------------------------------------------------------
# The gate observes, is required, and cannot silently lose a lane (#65)
# --------------------------------------------------------------------------

import re  # noqa: E402

EVIDENCE_WORKFLOW = (ROOT / ".github/workflows/platform-evidence.yml").read_text(encoding="utf-8")
RELEASE_WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
RULESET = json.loads((ROOT / ".github/rulesets/branch-main.json").read_text(encoding="utf-8"))
GATE_SCRIPT = ROOT / "scripts/ci/verify_evidence_artifacts.py"

GATE_SPEC = importlib.util.spec_from_file_location("verify_evidence_artifacts", GATE_SCRIPT)
assert GATE_SPEC and GATE_SPEC.loader
gate = importlib.util.module_from_spec(GATE_SPEC)
GATE_SPEC.loader.exec_module(gate)


def _matrix_instances(name: str, text: str) -> int:
    """Instances one `strategy.matrix` block expands to.

    Only the two shapes this workflow uses are understood, and anything else
    raises. That is the point: a parser that silently failed to understand a job
    would under-count, which is the exact failure this test exists to catch.
    """
    pair = r"^          - runner: (\S+)\n            lane: (\S+)$"

    # Separate the sections first. `include:` and `exclude:` entries have an
    # identical shape, so a regex over the whole block counts exclusions as
    # inclusions.
    head, _, excluded_text = text.partition("        exclude:\n")
    # An exclude entry names runner and lane but not release, so it removes one
    # instance per declared release rather than one instance outright.
    excluded_entries = len(re.findall(pair, excluded_text, re.M)) if excluded_text else 0

    if "        include:\n" in head:
        included = len(re.findall(pair, head.split("        include:\n", 1)[1], re.M))
        if not included:
            raise AssertionError(f"{name}: include: block matched no runner/lane pair")
        if excluded_entries:
            raise AssertionError(f"{name}: include: with exclude: is not a shape this parser handles")
        return included

    def inline_list(key: str) -> list[str] | None:
        found = re.search(rf'^        {key}: \[(.*?)\]$', head, re.M)
        if not found:
            return None
        return [item.strip().strip('"') for item in found.group(1).split(",")]

    lanes = re.findall(r"^          - (\S+)$", head, re.M) or inline_list("lane")
    releases = inline_list("release") or [None]
    runners = inline_list("runner") or [None]

    if not lanes:
        # A job whose only matrix dimension is the release still expands, e.g.
        # ubuntu-safeguards, which runs one named lane per release.
        if releases != [None]:
            return len(releases) - excluded_entries
        raise AssertionError(f"{name}: matrix understood by neither shape:\n{text}")

    return len(lanes) * len(releases) * len(runners) - excluded_entries * len(releases)


def _artifact_producing_job_instances() -> int:
    """Count the artifact uploads the workflow's runner matrices actually produce.

    `expected_hosted_artifact_instances` was computed from the matrix's own
    architecture lists, so the matrix agreed with itself: a lane dropped from the
    *workflow* reduced coverage without failing anything. This counts from the
    workflow instead.
    """
    body = EVIDENCE_WORKFLOW.split("\njobs:\n", 1)[1]
    blocks = re.split(r"\n(?=  [a-z][a-z0-9-]*:\n)", body)

    total = 0
    seen_upload = False
    for block in blocks:
        name = block.strip().split(":", 1)[0]
        if "upload-artifact" not in block:
            continue  # evidence-gate uploads nothing; it consumes.
        seen_upload = True
        matrix = re.search(r"\n      matrix:\n(.*?)(?=\n    steps:)", block, re.S)
        if matrix is None:
            total += 1  # a single-instance job, e.g. ubuntu-safeguards
            continue
        total += _matrix_instances(name, matrix.group(1))
    if not seen_upload:
        raise AssertionError("no artifact-uploading job found; the parser lost the workflow")
    return total


def test_workflow_runner_matrix_matches_the_declared_artifact_count() -> None:
    """A dropped lane must fail here rather than quietly reduce coverage."""
    declared = MATRIX["expected_hosted_artifact_instances"]
    assert _artifact_producing_job_instances() == declared, (
        "the workflow's runner matrices and expected_hosted_artifact_instances disagree"
    )


def test_declared_artifact_count_also_matches_the_matrix_expansion() -> None:
    """The pre-existing self-consistency check, kept as the second binding."""
    assert len(gate.expected_instances(MATRIX)) == MATRIX["expected_hosted_artifact_instances"]


def test_evidence_gate_opens_the_artifacts_it_gates_on() -> None:
    """The gate previously read four `needs.*.result` values and nothing else."""
    gate_job = EVIDENCE_WORKFLOW.split("\n  evidence-gate:\n", 1)[1]
    assert "actions/download-artifact@" in gate_job
    assert "scripts/ci/verify_evidence_artifacts.py" in gate_job


def test_evidence_runs_only_from_pull_request() -> None:
    """`pull_request` must be the only trigger (#75).

    These jobs check out a contributor's head SHA and execute it. Any trigger
    that can write the default-branch Actions cache scope makes that a
    cache-poisoning path, which is the CodeQL finding this file carried. A
    `pull_request` run's cache scope is the PR's own branch.

    The release gate does not need another trigger: it proves the candidate's
    tree is identical to a head whose `evidence-gate` is green.
    """
    triggers = EVIDENCE_WORKFLOW.split("\npermissions:", 1)[0]
    declared = re.findall(r"^  ([a-z_]+):", triggers, re.M)
    assert declared == ["pull_request"], (
        f"platform-evidence declares triggers beyond pull_request: {declared}"
    )
    # And no job may re-admit one through its condition.
    for condition in re.findall(r"^    if: (.+)$", EVIDENCE_WORKFLOW, re.M):
        assert "workflow_dispatch" not in condition and "'push'" not in condition, (
            f"a job condition still admits a write-capable trigger: {condition}"
        )


def test_evidence_gate_is_in_the_required_check_projection() -> None:
    contexts = {
        check["context"]
        for rule in RULESET["rules"]
        if rule["type"] == "required_status_checks"
        for check in rule["parameters"]["required_status_checks"]
    }
    assert "evidence-gate" in contexts
    assert "bootstrap-gate" in contexts


def test_release_requires_both_gates_before_publication() -> None:
    job = RELEASE_WORKFLOW.split("\n  verify-candidate:\n", 1)[1].split("\n  verify-tag:", 1)[0]

    # bootstrap-gate is asked about the candidate itself.
    assert "check_name=bootstrap-gate" in job
    assert "commits/${GITHUB_SHA}/check-runs" in job

    # evidence-gate is asked about the head the candidate's tree came from, and
    # the tree identity is proven rather than assumed.
    assert "check_name=evidence-gate" in job
    assert 'candidate_tree="$(git rev-parse "${GITHUB_SHA}^{tree}")"' in job
    assert '[ "$candidate_tree" = "$head_tree" ]' in job

    # Publication must depend on it, on every trigger.
    supply = RELEASE_WORKFLOW.split("\n  supply-chain:\n", 1)[1]
    assert "needs.verify-candidate.result == 'success'" in supply
    # verify-candidate carries no `if:`, so it runs for tag pushes too.
    assert not re.search(r"^    if:", job, re.M)


def test_the_tree_identity_property_is_backed_by_the_ruleset() -> None:
    """The proof relies on strict required-status-checks, so assert it is set.

    A merge commit has the same tree as its head only when the branch was up to
    date. `strict_required_status_checks_policy` is what forces that; without it
    the tree check would simply start failing, which is the safe direction, but
    the projection should still say so.
    """
    strict = [
        rule["parameters"]["strict_required_status_checks_policy"]
        for rule in RULESET["rules"]
        if rule["type"] == "required_status_checks"
    ]
    assert strict == [True], "verify-candidate's tree-identity proof assumes a strict policy"


def test_required_capabilities_declare_the_steps_a_lane_must_observe() -> None:
    for lane in MATRIX["evidence_lanes"]:
        for capability in lane["capabilities"]:
            if capability["requirement"] == "REQUIRED":
                assert capability["observable_steps"], f"{lane['lane']}: no observable steps"
            else:
                assert "observable_steps" not in capability


def test_finalize_rejects_a_success_that_observed_nothing() -> None:
    """The check the old runtime guard could not perform.

    `validate_matrix` refuses REQUIRED + not-PROVEN, so the matrix cannot express
    the state the previous runtime check guarded against and it could never fire.
    This one can: the capabilities are exactly what the matrix declares, and the
    lane still fails because it did not run the steps.
    """
    lane = support_evidence.resolve_lane(MATRIX, "macos-gui", "arm64", "runner-image")
    payload = {"capabilities": copy.deepcopy(lane["capabilities"])}
    with pytest.raises(support_evidence.MatrixError, match="did not observe every REQUIRED step"):
        support_evidence.finalize_evidence(payload, "success", ["plan", "apply"])


def test_finalize_accepts_a_success_that_observed_every_step() -> None:
    lane = support_evidence.resolve_lane(MATRIX, "macos-gui", "arm64", "runner-image")
    payload = {"capabilities": copy.deepcopy(lane["capabilities"])}
    steps = sorted(support_evidence.required_observations(lane["capabilities"]))
    result = support_evidence.finalize_evidence(payload, "success", steps)
    assert result["observed_steps"] == steps


def test_a_failed_lane_is_not_required_to_have_observed_anything() -> None:
    lane = support_evidence.resolve_lane(MATRIX, "macos-gui", "arm64", "runner-image")
    payload = {"capabilities": copy.deepcopy(lane["capabilities"])}
    result = support_evidence.finalize_evidence(payload, "failure", [])
    assert result["result"] == "failure"


def _lane_functions() -> dict[str, str]:
    """Map each lane id to the shell function its dispatch case calls."""
    runner = (ROOT / "scripts/ci/platform-evidence.sh").read_text(encoding="utf-8")
    case_body = runner.split('case "$LANE" in', 1)[1].split("\nesac", 1)[0]
    mapping = dict(re.findall(r"^\s*([\w-]+)\)\s+(\w+)", case_body, re.M))
    declared = {lane["lane"] for lane in MATRIX["evidence_lanes"]}
    assert set(mapping) == declared, (
        f"dispatch and matrix disagree on lanes: {set(mapping) ^ declared}"
    )
    return mapping


def _steps_recorded_by(function: str) -> set[str]:
    runner = (ROOT / "scripts/ci/platform-evidence.sh").read_text(encoding="utf-8")
    match = re.search(rf"^{function}\(\) \{{\n(.*?)^\}}", runner, re.S | re.M)
    assert match, f"lane function {function} not found"
    return set(re.findall(r"evidence_step (\w+)", match.group(1)))


def test_every_lane_records_every_step_that_lane_declares() -> None:
    """Per lane, not per script.

    A set built across the whole script cannot see a per-lane omission: five of
    the nine lanes declare the same five steps, so deleting one call from one
    lane leaves every step name still present somewhere. Each lane is checked
    against the function its own dispatch case calls.
    """
    functions = _lane_functions()
    for lane in MATRIX["evidence_lanes"]:
        declared = support_evidence.required_observations(lane["capabilities"])
        recorded = _steps_recorded_by(functions[lane["lane"]])
        missing = sorted(declared - recorded)
        assert not missing, (
            f"{lane['lane']} declares steps its lane function never records: {missing}"
        )
        outside = sorted(recorded - set(MATRIX["observable_step_vocabulary"]))
        assert not outside, f"{lane['lane']} records steps outside the vocabulary: {outside}"


# --------------------------------------------------------------------------
# The artifact gate, against complete and tampered evidence sets
# --------------------------------------------------------------------------


def _write_lane(root: Path, lane_name: str, arch: str, release: str | None = None,
                **override) -> Path:
    lane = support_evidence.resolve_lane(MATRIX, lane_name, arch, release)
    payload = {
        "lane": lane_name,
        "sha": "a" * 40,
        "result": "success",
        "capabilities": copy.deepcopy(lane["capabilities"]),
        "release": lane["release"],
        "composition": {"architecture": lane["architecture"], "release": lane["release"]},
        "observed_steps": sorted(support_evidence.required_observations(lane["capabilities"])),
        "not_proven": sorted(
            item["id"] for item in lane["capabilities"] if item["status"] == "NOT_PROVEN"
        ),
    }
    payload.update(override)
    directory = root / f"platform-{lane_name}-{lane['release']}-{lane['architecture']}"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "evidence.json"
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return path


def _complete_evidence(root: Path) -> None:
    for lane in MATRIX["evidence_lanes"]:
        for release in lane["releases"]:
            for arch in lane["architectures"]:
                _write_lane(root, lane["lane"], arch, release)


def test_gate_accepts_a_complete_honest_evidence_set(tmp_path) -> None:
    _complete_evidence(tmp_path)
    assert gate.verify(tmp_path, sha="a" * 40) == 0


def test_gate_rejects_a_missing_lane(tmp_path) -> None:
    """A dropped runner must fail rather than silently reduce coverage."""
    _complete_evidence(tmp_path)
    import shutil

    shutil.rmtree(tmp_path / "platform-sandbox-server-rootless-24.04-amd64")
    with pytest.raises(gate.GateError, match="expected 21 evidence payloads, downloaded 20"):
        gate.verify(tmp_path, sha="a" * 40)


def test_gate_rejects_a_lane_that_claims_more_than_it_observed(tmp_path) -> None:
    """The defect the old gate structurally could not see."""
    _complete_evidence(tmp_path)
    _write_lane(tmp_path, "macos-gui", "arm64", observed_steps=["plan", "apply"])
    with pytest.raises(gate.GateError, match="did not\n?\\s*observe|claims REQUIRED"):
        gate.verify(tmp_path, sha="a" * 40)


def test_gate_rejects_a_failed_lane(tmp_path) -> None:
    _complete_evidence(tmp_path)
    _write_lane(tmp_path, "macos-no-gui", "arm64", result="failure")
    with pytest.raises(gate.GateError, match="result is 'failure'"):
        gate.verify(tmp_path, sha="a" * 40)


def test_gate_rejects_a_quietly_emptied_not_proven_list(tmp_path) -> None:
    """An unproven capability must not disappear from the artifact."""
    _complete_evidence(tmp_path)
    _write_lane(tmp_path, "macos-gui", "arm64", not_proven=[])
    with pytest.raises(gate.GateError, match="not_proven is"):
        gate.verify(tmp_path, sha="a" * 40)


def test_gate_rejects_an_edited_capability_list(tmp_path) -> None:
    """The payload's capabilities are a copy, and a copy can be rewritten."""
    _complete_evidence(tmp_path)
    _write_lane(
        tmp_path,
        "macos-gui",
        "arm64",
        capabilities=[{
            "id": "plan_apply_strict_verify_repeat_apply",
            "requirement": "REQUIRED",
            "status": "PROVEN",
            "observable_steps": ["plan"],
        }],
        observed_steps=["plan"],
    )
    with pytest.raises(gate.GateError, match="capabilities do not match"):
        gate.verify(tmp_path, sha="a" * 40)


def test_gate_rejects_evidence_from_a_different_commit(tmp_path) -> None:
    _complete_evidence(tmp_path)
    _write_lane(tmp_path, "macos-gui", "arm64", sha="b" * 40)
    with pytest.raises(gate.GateError, match="carries sha"):
        gate.verify(tmp_path, sha="a" * 40)


# --------------------------------------------------------------------------
# Ubuntu 26.04 coverage (#57)
# --------------------------------------------------------------------------

RUNNER_SCRIPT = (ROOT / "scripts/ci/platform-evidence.sh").read_text(encoding="utf-8")


def test_sandbox_release_is_a_lane_property_not_the_runner_s() -> None:
    """26.04 coverage must not depend on a public-preview runner label.

    The sandbox container's Ubuntu release is independent of the runner's, so a
    26.04 sandbox runs on a 24.04 runner. `ubuntu-26.04` and `ubuntu-26.04-arm`
    exist but are public preview, and a job asking for a label no runner
    advertises queues indefinitely rather than failing.
    """
    assert 'RLDYOUR_EVIDENCE_RELEASE:-24.04' in RUNNER_SCRIPT
    assert "FROM ubuntu:${RELEASE}" in RUNNER_SCRIPT
    assert "FROM ubuntu:24.04" not in RUNNER_SCRIPT, "the sandbox base image is hardcoded again"

    sandbox = EVIDENCE_WORKFLOW.split("\n  ubuntu-systemd-sandbox:\n", 1)[1]
    assert 'release: ["24.04", "26.04"]' in sandbox
    assert "runs-on: ${{ matrix.runner }}" in sandbox
    # Comments are stripped: the workflow explains why it does not use the
    # preview label, and naming it in prose must stay allowed.
    executable = "\n".join(
        line for line in EVIDENCE_WORKFLOW.splitlines() if not line.lstrip().startswith("#")
    )
    assert "ubuntu-26.04" not in executable, (
        "a preview runner label entered the workflow; sandbox releases do not need one"
    )


def test_container_readiness_accepts_a_settled_degraded_system() -> None:
    """`running` was never the property the lane needs.

    On 26.04 `systemd-modules-load.service` fails inside a container -- it cannot
    load kernel modules -- so systemd settles `degraded` and never reaches
    `running`. Waiting for `running` made a correct 26.04 sandbox time out.
    Verified by running the lane: it now boots, and the degraded state is
    recorded with its failed unit rather than tolerated silently.
    """
    block = RUNNER_SCRIPT.split("start_systemd_container() {", 1)[1].split("\n}", 1)[0]
    assert "running|degraded" in block, "readiness rejects a settled degraded system again"
    assert "is-system-running --quiet" not in block, (
        "the quiet form cannot distinguish `degraded` from `starting`"
    )
    # A degraded boot must be visible in the artifact, not swallowed.
    assert "SANDBOX_FAILED_UNITS" in block
    assert "sandbox_failed_units" in RUNNER_SCRIPT
    assert "runner_stability" in RUNNER_SCRIPT


def test_every_ubuntu_lane_declares_which_releases_it_proves() -> None:
    """No shared result may imply both releases."""
    for lane in MATRIX["evidence_lanes"]:
        assert lane["releases"], lane["lane"]
        assert "release" not in lane, f"{lane['lane']} kept the scalar spelling"
        if lane["os"] == "ubuntu":
            assert set(lane["releases"]) <= {"24.04", "26.04"}, lane["lane"]
    sandbox = [l for l in MATRIX["evidence_lanes"] if l["lane"].startswith("sandbox-")]
    assert sandbox, "no sandbox lanes found"
    for lane in sandbox:
        assert lane["releases"] == ["24.04", "26.04"], (
            f"{lane['lane']} does not prove both supported releases"
        )
