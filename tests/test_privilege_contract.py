from __future__ import annotations

import ast
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "config/rldyour-contract.json"
PRIVILEGE = ROOT / "scripts/ubuntu/privilege.sh"
HELPER = ROOT / "scripts/ubuntu/privileged-helper.sh"
PUBLISHER = ROOT / "scripts/ubuntu/secure-publish.py"
POLICY = ROOT / "templates/polkit/com.nddev.rldyour.bootstrap.policy"
SHELL_CONTRACT = ROOT / "scripts/ci/shell_contract.py"
SHELL_CONTRACT_SCHEMA = "rldyour.shell-contract/v1"
FUNCTION_HARNESS = ROOT / "scripts/ci/shell_function_harness.py"


def _load_function_harness():
    spec = importlib.util.spec_from_file_location("privilege_function_harness", FUNCTION_HARNESS)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FUNCTION_HARNESS_MODULE = _load_function_harness()


def contract() -> dict:
    return json.loads(CONTRACT.read_text(encoding="utf-8"))


def test_chrome_trust_has_one_machine_contract_owner() -> None:
    data = contract()
    chrome = next(
        item for item in data["ubuntu_apt_packages"]["desktop_apps"]
        if item["name"] == "google-chrome-stable"
    )
    fingerprint = chrome["apt_source"]["key_fingerprint"]
    assert re.fullmatch(r"[0-9A-F]{40}", fingerprint)
    for path in (HELPER, PRIVILEGE, ROOT / "scripts/ubuntu/desktop.sh"):
        assert fingerprint not in path.read_text(encoding="utf-8")
    assert HELPER.read_text(encoding="utf-8").count("data[\"ubuntu_apt_packages\"]") == 1


def _function_inventory(path: Path, *tools: str) -> dict[str, list[str]]:
    completed = subprocess.run(
        [sys.executable, str(FUNCTION_HARNESS), "inventory", "--source", str(path),
         *[value for tool in tools for value in ("--tool", tool)]],
        text=True, capture_output=True, check=False,
    )
    assert completed.returncode == 0, completed.stderr
    envelope = json.loads(completed.stdout)
    assert envelope["schema"] == "rldyour.shell-function-harness/v1"
    return envelope["result"]


def _canonical_identity_sets(value: object) -> dict[str, frozenset[str]]:
    assert isinstance(value, dict)
    canonical: dict[str, frozenset[str]] = {}
    for owner, identities in value.items():
        assert isinstance(owner, str) and owner
        assert isinstance(identities, list) and identities
        assert all(isinstance(identity, str) and identity for identity in identities)
        assert len(identities) == len(set(identities)), f"duplicate identity under {owner}"
        canonical[owner] = frozenset(identities)
    return canonical


def test_machine_authority_graph_reaches_chrome_consumers_without_literal_drift() -> None:
    graph = contract()["privilege"]["authority_graph"]["chrome_trust"]
    assert graph == {
        "producer": "config/rldyour-contract.json#ubuntu_apt_packages.desktop_apps[name=google-chrome-stable].apt_source",
        "installer": "scripts/ubuntu/privileged-helper.sh",
        "verifier": "scripts/ubuntu/verify.sh",
        "unprivileged_observer": "scripts/ubuntu/desktop.sh",
    }
    producer = contract()["ubuntu_apt_packages"]["desktop_apps"]
    chrome = next(item for item in producer if item["name"] == "google-chrome-stable")["apt_source"]
    assert re.fullmatch(r"[0-9A-F]{40}", chrome["key_fingerprint"])
    consumers = {key: ROOT / value for key, value in graph.items() if key != "producer"}
    assert 'chrome["key_fingerprint"]' in consumers["installer"].read_text(encoding="utf-8")
    verifier = consumers["verifier"].read_text(encoding="utf-8")
    assert "shell_contract.py" in verifier and "chrome-runtime" in verifier
    parser = SHELL_CONTRACT.read_text(encoding="utf-8")
    assert 'source.get("key_fingerprint"' in parser
    assert "accepted_source_identities" in parser
    assert "google-chrome-stable" in consumers["unprivileged_observer"].read_text(encoding="utf-8")
    for path in consumers.values():
        assert chrome["key_fingerprint"] not in path.read_text(encoding="utf-8")


def test_privilege_tool_invocation_matches_the_machine_authority_graph() -> None:
    graph = contract()["privilege"]["authority_graph"]["privilege_dispatch"]
    assert graph["collection_semantics"] == {
        "callers": "keyed-identity-set",
        "direct_tool_owners": "keyed-identity-set",
        "module_owned_root_execution": "keyed-identity-set",
    }
    authority = ROOT / graph["authority"]
    observed = _function_inventory(authority, *graph["direct_tool_owners"])
    assert _canonical_identity_sets(observed) == _canonical_identity_sets(graph["direct_tool_owners"])
    for relative, calls in graph["callers"].items():
        text = (ROOT / relative).read_text(encoding="utf-8")
        for call in calls:
            assert re.search(rf"(?m)^[ \t]*{re.escape(call)}(?:[ \t]|$)", text), (relative, call)
        assert "/usr/bin/pkexec" not in text
        if relative != "scripts/ubuntu/server.sh":
            assert "/usr/bin/sudo" not in text
    for relative, owners in graph["module_owned_root_execution"].items():
        observed_module = _function_inventory(ROOT / relative, "/usr/bin/sudo")
        assert frozenset(observed_module["/usr/bin/sudo"]) == frozenset(owners)


def test_authority_identity_sets_accept_reordering_and_reject_conflicts() -> None:
    owners = contract()["privilege"]["authority_graph"]["privilege_dispatch"]["direct_tool_owners"]
    reordered = {key: list(reversed(value)) for key, value in reversed(list(owners.items()))}
    assert _canonical_identity_sets(reordered) == _canonical_identity_sets(owners)
    duplicated = {key: list(value) for key, value in owners.items()}
    duplicated["/usr/bin/sudo"].append(duplicated["/usr/bin/sudo"][0])
    with pytest.raises(AssertionError, match="duplicate identity"):
        _canonical_identity_sets(duplicated)
    conflicting = {key: list(value) for key, value in owners.items()}
    conflicting["/usr/bin/sudo"] = [*conflicting["/usr/bin/sudo"], "rldyour::privilege::unknown"]
    assert _canonical_identity_sets(conflicting) != _canonical_identity_sets(owners)


def test_source_order_is_semantic_only_for_declared_package_sequences() -> None:
    docs = (ROOT / "docs/reference/source-register.md").read_text(encoding="utf-8")
    assert "authority mappings are unordered keyed identity sets" in docs
    canonical = _shell_contract(
        "ubuntu-packages", "--contract", str(CONTRACT), "--consumer", "ubuntu-install-source-baseline"
    )
    assert canonical != list(reversed(canonical))


def test_unknown_privilege_tool_owner_and_direct_caller_dispatch_fail_closed(tmp_path: Path) -> None:
    hostile = tmp_path / "hostile.sh"
    hostile.write_text("bad(){ /usr/bin/sudo -n -- /bin/sh; }\n", encoding="utf-8")
    assert _function_inventory(hostile, "/usr/bin/sudo") == {"/usr/bin/sudo": ["bad"]}
    allowed = contract()["privilege"]["authority_graph"]["privilege_dispatch"]["direct_tool_owners"]
    assert "bad" not in allowed["/usr/bin/sudo"]


def test_privilege_profile_contract_is_closed_and_complete() -> None:
    privilege = contract()["privilege"]
    assert privilege["system_python_minimum"] == "3.12"
    assert set(privilege["operations"]) == {
        "ubuntu-desktop-system", "ubuntu-desktop-gui-system", "ubuntu-server-system"
    }
    assert privilege["operation_owners"] == {
        "ubuntu-desktop-system": "scripts/ubuntu/privileged-helper.sh",
        "ubuntu-desktop-gui-system": "scripts/ubuntu/privileged-helper.sh",
        "ubuntu-server-system": "scripts/ubuntu/server.sh",
    }
    assert set(privilege["profiles"]) == {
        "desktop:gui-0", "desktop:gui-1", "desktop-builds:gui-0",
        "desktop-builds:gui-1", "server:gui-0",
    }
    assert "policykit" in privilege["profiles"]["desktop:gui-1"]["mechanisms"]
    assert all(
        "policykit" not in value["mechanisms"]
        for key, value in privilege["profiles"].items() if key != "desktop:gui-1"
    )
    assert privilege["gui_authorization_evidence"] == "NOT_PROVEN_REAL_HOST_REQUIRED"


def _capture_contract(script: str, tmp_path: Path) -> subprocess.CompletedProcess[str]:
    sandbox_helper = tmp_path / "helper.sh"
    sandbox_helper.write_text(
        HELPER.read_text(encoding="utf-8").replace(
            "readonly CONTRACT=/usr/local/share/rldyour-bootstrap/rldyour-contract.json",
            f"readonly CONTRACT={CONTRACT}",
        ),
        encoding="utf-8",
    )
    return subprocess.run(
        ["bash", "-c", script, "_", str(sandbox_helper), str(tmp_path / "capture")],
        text=True, capture_output=True, check=False,
    )


def test_contract_capture_binds_success_to_exact_typed_records(tmp_path: Path) -> None:
    result = _capture_contract(
        'source "$1"; load_contract_values "$2"; printf "%s\\n" "${CONTRACT_RECORDS[@]}"',
        tmp_path,
    )
    assert result.returncode == 0, result.stderr
    assert [line.split("=", 1)[0] for line in result.stdout.splitlines()] == [
        "chrome_key_url", "chrome_fingerprint", "chrome_repo_uri", "chrome_keyring",
        "chrome_source", "rustdesk_url", "rustdesk_sha256",
    ]


def test_contract_capture_rejects_partial_output_with_nonzero_and_cleans(tmp_path: Path) -> None:
    result = _capture_contract(
        'source "$1"; contract_values(){ printf "chrome_key_url=https://invalid\\n"; return 19; }; '
        'load_contract_values "$2"',
        tmp_path,
    )
    assert result.returncode == 19
    assert (tmp_path / "capture").read_text(encoding="utf-8") == "chrome_key_url=https://invalid\n"


def test_contract_capture_rejects_extra_malformed_and_oversized_records(tmp_path: Path) -> None:
    cases = (
        ":",
        "printf 'bad-record\\n'",
        "for i in {1..8}; do printf 'x%s=y\\n' \"$i\"; done",
        "python3 -c 'print(\"x=\" + \"a\" * 5000)'",
    )
    for producer in cases:
        result = _capture_contract(
            f'source "$1"; contract_values(){{ {producer}; }}; load_contract_values "$2"',
            tmp_path,
        )
        assert result.returncode != 0


def _validate_shell_control_flow_contract(value: dict) -> dict[str, dict]:
    assert value["canonical_form"] == "explicit-if-v1"
    guards = value["guards"]
    assert isinstance(guards, list) and guards
    indexed: dict[str, dict] = {}
    for guard in guards:
        assert set(guard) >= {"id", "path", "function", "predicate", "failure_exit", "before"}
        assert guard["id"] not in indexed
        assert guard["failure_exit"] == 1
        source = (ROOT / guard["path"]).read_text(encoding="utf-8")
        assert f'{guard["function"]}() {{' in source
        indexed[guard["id"]] = guard
    assert indexed["capture-size"]["predicate"] == "integer-range"
    assert indexed["capture-size"]["minimum"] == 1
    assert indexed["capture-size"]["maximum"] == 4096
    assert indexed["capture-size"]["before"] == "record-parse"
    required_order = {
        "capture-record": "record-append",
        "policykit-uid": "pkexec-parent-validation",
        "policykit-runtime": "runtime-owner-validation",
        "trusted-root-input": "ancestry-walk",
        "trusted-record": "receipt-read",
        "trusted-bundle-entry": "hash-compare",
        "published-bundle-entry": "published-hash-compare",
    }
    for guard_id, before in required_order.items():
        assert indexed[guard_id]["before"] == before
    return indexed


def test_shell_control_flow_contract_is_complete_and_semantic() -> None:
    model = _validate_shell_control_flow_contract(contract()["privilege"]["shell_control_flow"])
    assert set(model) == {
        "capture-size", "capture-record", "policykit-uid", "policykit-runtime",
        "trusted-root-input", "trusted-record", "trusted-bundle-entry",
        "published-bundle-entry",
    }
    size = model["capture-size"]
    assert (size["predicate"], size["minimum"], size["maximum"], size["before"]) == (
        "integer-range", 1, 4096, "record-parse")

    def accepted(value: int) -> bool:
        return size["minimum"] <= value <= size["maximum"]

    def equivalent_positive(value: int) -> bool:
        if value > 0 and value <= 4096:
            return True
        return False

    def equivalent_negative(value: int) -> bool:
        if value <= 0 or value > 4096:
            return False
        return True

    assert all(accepted(value) == equivalent_positive(value) == equivalent_negative(value)
               for value in (-1, 0, 1, 4096, 4097))
    weakened = json.loads(json.dumps(contract()["privilege"]["shell_control_flow"]))
    next(item for item in weakened["guards"] if item["id"] == "capture-size")["maximum"] = 8192
    with pytest.raises(AssertionError):
        _validate_shell_control_flow_contract(weakened)
    reordered = json.loads(json.dumps(contract()["privilege"]["shell_control_flow"]))
    next(item for item in reordered["guards"] if item["id"] == "capture-size")["before"] = "record-append"
    with pytest.raises(AssertionError):
        _validate_shell_control_flow_contract(reordered)


def test_contract_capture_fails_closed_on_measurement_and_capture_path_errors(tmp_path: Path) -> None:
    failing_wc = tmp_path / "wc"
    failing_wc.write_text("#!/bin/sh\nexit 23\n", encoding="utf-8")
    failing_wc.chmod(0o755)
    sandbox_helper = tmp_path / "helper.sh"
    sandbox_helper.write_text(
        HELPER.read_text(encoding="utf-8")
        .replace(
            "readonly CONTRACT=/usr/local/share/rldyour-bootstrap/rldyour-contract.json",
            f"readonly CONTRACT={CONTRACT}",
        )
        .replace("/usr/bin/wc -c", f"{failing_wc} -c"),
        encoding="utf-8",
    )
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; load_contract_values "$2"', "_",
         str(sandbox_helper), str(tmp_path / "capture")],
        text=True, capture_output=True, check=False,
    )
    assert result.returncode == 1

    capture_directory = tmp_path / "capture-directory"
    capture_directory.mkdir()
    regular_helper = tmp_path / "regular-helper.sh"
    regular_helper.write_text(
        HELPER.read_text(encoding="utf-8").replace(
            "readonly CONTRACT=/usr/local/share/rldyour-bootstrap/rldyour-contract.json",
            f"readonly CONTRACT={CONTRACT}",
        ),
        encoding="utf-8",
    )
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; load_contract_values "$2"', "_",
         str(regular_helper), str(capture_directory)],
        text=True, capture_output=True, check=False,
    )
    assert result.returncode != 0


def test_policy_binds_exact_path_and_only_gui_operation() -> None:
    text = POLICY.read_text(encoding="utf-8")
    assert text.count("org.freedesktop.policykit.exec.path") == 1
    assert "/usr/local/libexec/rldyour-bootstrap-privileged" in text
    assert text.count("org.freedesktop.policykit.exec.argv1") == 1
    assert ">ubuntu-desktop-gui-system<" in text
    assert "auth_admin_keep" not in text
    assert "<allow_any>no</allow_any>" in text


def _run_helper_function(body: str, *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/bash", "-c", 'source "$1"; shift; ' + body, "_", str(HELPER)],
        text=True,
        capture_output=True,
        check=False,
        env={**os.environ, **(env or {})},
    )


def _run_structural_function(
    tmp_path: Path, source: Path, function: str, prelude: str, call: str,
) -> dict[str, object]:
    prelude_path = tmp_path / "prelude.sh"
    call_path = tmp_path / "call.sh"
    prelude_path.write_text(prelude, encoding="utf-8")
    call_path.write_text(call, encoding="utf-8")
    completed = subprocess.run(
        [sys.executable, str(FUNCTION_HARNESS), "run", "--source", str(source),
         "--function", function, "--prelude", str(prelude_path), "--call", str(call_path)],
        text=True, capture_output=True, check=False,
    )
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout)["result"]


def test_external_root_dispatch_accepts_only_one_allowlisted_operation() -> None:
    for operation in (
        "ubuntu-desktop-system", "ubuntu-desktop-gui-system", "ubuntu-server-system"
    ):
        result = _run_helper_function(f"validate_external_request {operation}")
        assert result.returncode == 0, result.stderr
    for invocation in (
        "validate_external_request",
        "validate_external_request unknown",
        "validate_external_request ubuntu-desktop-system injected",
        "validate_external_request /bin/sh",
    ):
        result = _run_helper_function(invocation)
        assert result.returncode == 2


def test_external_root_dispatch_ignores_hostile_environment() -> None:
    result = _run_helper_function(
        "validate_external_request ubuntu-desktop-system",
        env={
            "PATH": "/hostile",
            "PYTHONPATH": "/hostile",
            "RLDYOUR_OPERATION": "/bin/sh",
        },
    )
    assert result.returncode == 0, result.stderr


def test_internal_apt_allowlist_permits_fixed_expansion_and_rejects_injection() -> None:
    accepted = _run_helper_function(
        "apt_arguments_allowed ca-certificates curl python3 google-chrome-stable"
    )
    assert accepted.returncode == 0, accepted.stderr
    for arguments in (
        "", "--option", "curl /tmp/package.deb", "curl '$(id)'", "curl evil=1",
        "curl --", "curl unknown-package",
    ):
        result = _run_helper_function(f"apt_arguments_allowed {arguments}")
        assert result.returncode != 0


def _shell_array(name: str, source: str) -> list[str]:
    path = ROOT / "scripts/ubuntu/privileged-helper.sh"
    assert source == path.read_text(encoding="utf-8")
    return _shell_contract("array", "--path", str(path), "--name", name)


def _shell_contract(*arguments: str, cwd: Path | None = None, env: dict[str, str] | None = None) -> object:
    result = subprocess.run(
        [sys.executable, "-I", str(SHELL_CONTRACT), *arguments],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    envelope = json.loads(result.stdout)
    assert set(envelope) == {"schema", "operation", "result"}
    assert envelope["schema"] == SHELL_CONTRACT_SCHEMA
    assert envelope["operation"] == arguments[0]
    return envelope["result"]


def _fixture_array(tmp_path: Path, source: str) -> subprocess.CompletedProcess[str]:
    fixture = tmp_path / "array.sh"
    fixture.write_text(source, encoding="utf-8")
    return subprocess.run(
        [sys.executable, "-I", str(SHELL_CONTRACT), "array", "--path", str(fixture), "--name", "ITEMS"],
        cwd=tmp_path,
        env={**os.environ, "PYTHONPATH": str(tmp_path / "hostile")},
        text=True, capture_output=True, check=False,
        timeout=10,
    )


def test_static_array_parser_accepts_the_declared_bounded_grammar(tmp_path: Path) -> None:
    cases = (
        ("ITEMS=(alpha beta)\n", ["alpha", "beta"]),
        ("ITEMS=()\n", []),
        ("ITEMS=(\n  alpha # comment\n  'two words' \"three\\\"words\"\n) # tail\n", ["alpha", "two words", 'three"words']),
        ("ITEMS=(joined\\\n-token escaped\\ value)\n", ["joined-token", "escaped value"]),
        ("ITEMS=(one\\\n  two)\n", ["one", "two"]),
        ("ITEMS=(one \\\n  two)\n", ["one", "two"]),
        ("ITEMS=(\"joined\\\nquoted\" 'single\\\nline')\n", ["joinedquoted", "single\\\nline"]),
        ("ITEMS=(one\\\n\\\n-two)\n", ["one-two"]),
        ("ITEMS=(one # comment\\\nstill-comment\n two)\n", ["one", "two"]),
        ("ITEMS=(one # unmatched ' quote\\\nstill-comment\n two)\n", ["one", "two"]),
        ("ITEMS=(joined\\\r\n-token)\r\n", ["joined-token"]),
        ("ITEMS=(one   \n  two   )   # trailing\n", ["one", "two"]),
        ("ITEMS=(one\r\n two)\r\n", ["one", "two"]),
        ("ITEMS=(one)", ["one"]),
        ("readonly -a ITEMS=(one\n two)\n", ["one", "two"]),
    )
    for source, expected in cases:
        result = _fixture_array(tmp_path, source)
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout)["result"] == expected


def test_static_array_parser_rejects_evaluation_ambiguity_and_reassignment(tmp_path: Path) -> None:
    cases = (
        "ITEMS=($value)\n",
        "ITEMS=(\"${value}\")\n",
        "ITEMS=($(command))\n",
        "ITEMS=(`command`)\n",
        "ITEMS=(<(command))\n",
        "ITEMS=($((1 + 1)))\n",
        "ITEMS=([0]=value)\n",
        "ITEMS=(one); command\n",
        "ITEMS=(one\n",
        "ITEMS=('one)\n",
        "ITEMS=(one)\nITEMS=(two)\n",
        "ITEMS=(one)\nITEMS+=(two)\n",
        "ITEMS=(one)\nITEMS[0]=two\n",
        "ITEMS=value\n",
        "ITEMS=(one) trailing\n",
        "ITEMS=(one\r two)\n",
    )
    for source in cases:
        result = _fixture_array(tmp_path, source)
        assert result.returncode == 3, source
        assert result.stdout == "" and result.stderr.startswith("shell-contract: ")
        assert re.search(r"\bat \d+:\d+", result.stderr) or "expected exactly one" in result.stderr


def test_exact_path_cli_is_cwd_and_shadow_module_independent(tmp_path: Path) -> None:
    hostile = tmp_path / "unrelated"
    hostile.mkdir()
    (hostile / "json.py").write_text("raise RuntimeError('shadow module loaded')\n", encoding="utf-8")
    fixture = tmp_path / "packages.sh"
    fixture.write_text("PACKAGES=(one 'two words')\n", encoding="utf-8")
    environment = {**os.environ, "PYTHONPATH": str(hostile)}
    command = subprocess.run(
        [sys.executable, "-I", str(SHELL_CONTRACT), "array", "--path", str(fixture), "--name", "PACKAGES"],
        cwd=hostile,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    assert command.returncode == 0, command.stderr
    assert json.loads(command.stdout)["result"] == ["one", "two words"]


def test_pytest_launchers_execute_exact_path_cli_from_unrelated_cwd(tmp_path: Path) -> None:
    pytest_executable = Path(sys.executable).with_name("pytest")
    assert pytest_executable.is_file() and os.access(pytest_executable, os.X_OK)
    test_file = tmp_path / "probe.py"
    test_file.write_text(
        "import json, subprocess, sys\n"
        f"CLI = {str(SHELL_CONTRACT)!r}\n"
        f"FIXTURE = {str(ROOT / 'scripts/ubuntu/privileged-helper.sh')!r}\n"
        "def test_cli():\n"
        " r=subprocess.run([sys.executable,'-I',CLI,'array','--path',FIXTURE,'--name','GUI_APT_PACKAGES'],text=True,capture_output=True)\n"
        " assert r.returncode == 0 and json.loads(r.stdout)['schema'] == 'rldyour.shell-contract/v1'\n",
        encoding="utf-8",
    )
    unrelated = tmp_path / "cwd"
    unrelated.mkdir()
    environment = {key: value for key, value in os.environ.items() if key != "PYTHONPATH"}
    for command in (
        [pytest_executable, "-q", str(test_file)],
        [sys.executable, "-m", "pytest", "-q", str(test_file)],
    ):
        result = subprocess.run(
            command, cwd=unrelated, env=environment, text=True, capture_output=True, check=False
        )
        assert result.returncode == 0, result.stdout + result.stderr


def test_missing_cli_fails_without_fallback(tmp_path: Path) -> None:
    result = subprocess.run(
        [sys.executable, "-I", str(tmp_path / "missing-shell-contract.py"), "array"],
        cwd=tmp_path,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    assert "can't open file" in result.stderr


def test_cli_protocol_rejects_usage_missing_input_and_oversized_input(tmp_path: Path) -> None:
    usage = subprocess.run(
        [sys.executable, "-I", str(SHELL_CONTRACT)],
        text=True, capture_output=True, check=False, timeout=10,
    )
    assert usage.returncode == 2 and usage.stdout == "" and "usage:" in usage.stderr
    missing = subprocess.run(
        [sys.executable, "-I", str(SHELL_CONTRACT), "array", "--path", str(tmp_path / "missing"), "--name", "A"],
        text=True, capture_output=True, check=False, timeout=10,
    )
    assert missing.returncode == 3 and missing.stdout == ""
    assert missing.stderr.startswith("shell-contract: ")
    oversized = tmp_path / "oversized.sh"
    oversized.write_bytes(b"A=(" + b"a" * (1024 * 1024) + b")")
    too_large = subprocess.run(
        [sys.executable, "-I", str(SHELL_CONTRACT), "array", "--path", str(oversized), "--name", "A"],
        text=True, capture_output=True, check=False, timeout=10,
    )
    assert too_large.returncode == 3 and "bounded parser limit" in too_large.stderr


def test_cli_consumer_rejects_malformed_json_stderr_and_timeout(tmp_path: Path) -> None:
    scripts = {
        "malformed": "import sys; print('not-json')\n",
        "stderr": "import sys; print('{}'); print('noise', file=sys.stderr)\n",
        "blocked": "import threading; threading.Event().wait()\n",
    }
    for name, body in scripts.items():
        fake = tmp_path / f"{name}.py"
        fake.write_text(
            "import os\n"
            "ready_fd = int(os.environ['RLDYOUR_TEST_READY_FD'])\n"
            "os.write(ready_fd, b'\\x01')\n"
            "os.close(ready_fd)\n" + body,
            encoding="utf-8",
        )
        read_fd, write_fd = os.pipe()
        environment = {
            "PATH": os.environ.get("PATH", ""),
            "RLDYOUR_TEST_READY_FD": str(write_fd),
        }
        try:
            result = FUNCTION_HARNESS_MODULE.run_owned(
                [sys.executable, "-I", str(fake)],
                env=environment,
                timeout=0.1 if name == "blocked" else 2,
                pass_fds=(write_fd,), readiness_fd=read_fd,
                close_after_spawn_fds=(write_fd,),
            )
        except FUNCTION_HARNESS_MODULE.HarnessError as error:
            assert name == "blocked" and "timed out" in str(error)
        else:
            if name == "malformed":
                with pytest.raises(json.JSONDecodeError):
                    json.loads(result.stdout)
            else:
                assert name == "stderr" and result.stderr != ""


def test_internal_apt_allowlist_matches_contract_without_drift() -> None:
    helper = HELPER.read_text(encoding="utf-8")
    desktop = _shell_array("DESKTOP_APT_PACKAGES", helper)
    gui = _shell_array("GUI_APT_PACKAGES", helper)
    desktop_expected = _shell_contract(
        "ubuntu-packages", "--contract", str(CONTRACT), "--consumer", "ubuntu-desktop-system"
    )
    gui_expected = _shell_contract(
        "ubuntu-packages", "--contract", str(CONTRACT), "--consumer", "ubuntu-desktop-gui-addon"
    )
    assert desktop == desktop_expected
    assert gui == gui_expected
    accepted = _run_helper_function(
        "apt_arguments_allowed " + " ".join([*desktop, *gui])
    )
    assert accepted.returncode == 0, accepted.stderr


def _package_tool_array_inventory(paths: list[Path]) -> dict[tuple[str, str], tuple[str, ...]]:
    declarations: dict[tuple[str, str], tuple[str, ...]] = {}
    pattern = re.compile(
        r"(?m)^(?:[ \t]*local[ \t]+-a[ \t]+)?"
        r"(?P<name>[A-Z][A-Z0-9_]*(?:PACKAGES|TOOLS|ASSETS))[ \t]*=\("
    )
    for path in paths:
        text = path.read_text(encoding="utf-8")
        relative = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else path.name
        for match in pattern.finditer(text):
            name = match.group("name")
            key = (relative, name)
            assert key not in declarations, f"duplicate array declaration: {key}"
            values = tuple(_shell_contract("array", "--path", str(path), "--name", name))
            assert values and len(values) == len(set(values)), f"empty/duplicate array payload: {key}"
            assert len(re.findall(rf"\b{re.escape(name)}\b", text)) >= 2, f"orphan array: {key}"
            declarations[key] = values
    payload_owners: dict[tuple[str, ...], tuple[str, str]] = {}
    for key, values in declarations.items():
        assert values not in payload_owners, (
            f"duplicate array authority: {payload_owners.get(values)} and {key}"
        )
        payload_owners[values] = key
    return declarations


def test_package_and_tool_arrays_have_one_owner_and_a_consumer() -> None:
    paths = [
        ROOT / "scripts/ubuntu/desktop.sh",
        ROOT / "scripts/ubuntu/install.sh",
        ROOT / "scripts/ubuntu/server.sh",
        HELPER,
    ]
    observed = _package_tool_array_inventory(paths)
    assert set(observed) == {
        ("scripts/ubuntu/install.sh", "APT_SOURCE_PACKAGES"),
        ("scripts/ubuntu/install.sh", "BUN_LSP_PACKAGES"),
        ("scripts/ubuntu/install.sh", "PYTHON_SOURCE_TOOLS"),
        ("scripts/ubuntu/install.sh", "PINNED_SOURCE_TOOLS"),
        ("scripts/ubuntu/install.sh", "USER_TOOLS"),
        ("scripts/ubuntu/install.sh", "TELEGRAM_DESKTOP_ASSETS"),
        ("scripts/ubuntu/privileged-helper.sh", "DESKTOP_APT_PACKAGES"),
        ("scripts/ubuntu/privileged-helper.sh", "GUI_APT_PACKAGES"),
        # Removal has its own allowlist rather than widening the install one.
        ("scripts/ubuntu/privileged-helper.sh", "REMOVABLE_APT_PACKAGES"),
    }
    server = (ROOT / "scripts/ubuntu/server.sh").read_text(encoding="utf-8")
    docker_body = server.split("rldyour::ubuntu_server::install_docker_packages() {", 1)[1].split("\n}", 1)[0]
    assert "local -a packages=(" in docker_body
    assert docker_body.count('"${packages[@]}"') >= 2


def test_superseded_declarations_are_absent_without_losing_cas_checks() -> None:
    install = (ROOT / "scripts/ubuntu/install.sh").read_text(encoding="utf-8")
    helper = HELPER.read_text(encoding="utf-8")
    privilege = PRIVILEGE.read_text(encoding="utf-8")
    assert "APT_DESKTOP_BUILD_PACKAGES" not in install
    assert "RECEIPT_MARKER" not in helper
    declaration = re.search(r"provision_bundle\(\) \{\n[ \t]*local ([^\n]+)", privilege)
    assert declaration and "old" not in declaration.group(1).split()
    assert 'current=$(rldyour::privilege::file_sha256 "$destination")' in privilege
    assert 'expected=$(rldyour::privilege::file_sha256 "$source")' in privilege
    assert 'if [ "$current" != "$expected" ]; then' in privilege


def test_explicit_control_flow_predicates_cover_true_false_and_error(tmp_path: Path) -> None:
    receipt_prelude = '''
rldyour::privilege::receipt_value() {
  [ "${FAIL_RECEIPT:-0}" -eq 0 ] || return 9
  case "$2" in
    helper_sha256) printf h ;;
    contract_sha256) printf c ;;
    policy_sha256) printf p ;;
  esac
}
'''
    accepted = _run_structural_function(
        tmp_path, PRIVILEGE, "rldyour::privilege::transaction_matches_sources",
        receipt_prelude, "rldyour::privilege::transaction_matches_sources receipt h c p",
    )
    assert accepted["returncode"] == 0
    mismatch = _run_structural_function(
        tmp_path, PRIVILEGE, "rldyour::privilege::transaction_matches_sources",
        receipt_prelude, "rldyour::privilege::transaction_matches_sources receipt h WRONG p",
    )
    assert mismatch["returncode"] != 0
    producer_error = _run_structural_function(
        tmp_path, PRIVILEGE, "rldyour::privilege::transaction_matches_sources",
        "FAIL_RECEIPT=1\n" + receipt_prelude,
        "rldyour::privilege::transaction_matches_sources receipt h c p",
    )
    assert producer_error["returncode"] != 0

    trusted_true = _run_structural_function(
        tmp_path, HELPER, "trusted_runtime_inputs",
        "EXPECTED_PATH=/helper\nCONTRACT=/contract\ntrusted_file(){ return 0; }\n",
        "trusted_runtime_inputs 9",
    )
    assert trusted_true["returncode"] == 0
    trusted_false = _run_structural_function(
        tmp_path, HELPER, "trusted_runtime_inputs",
        "EXPECTED_PATH=/helper\nCONTRACT=/contract\ntrusted_file(){ return 1; }\n",
        "trusted_runtime_inputs 9",
    )
    assert trusted_false["returncode"] != 0
    trusted_error = _run_structural_function(
        tmp_path, HELPER, "trusted_runtime_inputs",
        "EXPECTED_PATH=/helper\nCONTRACT=/contract\nCOUNT=0\n"
        "trusted_file(){ COUNT=$((COUNT + 1)); [ \"$COUNT\" -eq 1 ] || return 7; }\n",
        "trusted_runtime_inputs 9",
    )
    assert trusted_error["returncode"] != 0

    # chrome_fingerprint_set_valid used to be exercised here. It was superseded
    # by rldyour::ubuntu_verify::chrome_key_trusted, which delegates to the
    # shared rldyour::gpg_primary_fingerprint primitive: the old helper counted
    # matching fingerprint *lines*, so a keyring whose subkey matched satisfied
    # it, while the primitive requires exactly one primary key. The replacement
    # is executed against real generated keyrings in
    # tests/test_desktop_customization.py rather than through this structural
    # harness, because key identity is a gpg behaviour and not a control-flow one.
    for expected_ok, expected_fingerprint in ((True, "$observed"), (False, "0" * 40)):
        result = _run_structural_function(
            tmp_path, ROOT / "scripts/ubuntu/verify.sh",
            "rldyour::ubuntu_verify::chrome_key_trusted",
            'rldyour::gpg_primary_fingerprint(){ printf "%s\\n" AAAA; }\n',
            'rldyour::ubuntu_verify::chrome_key_trusted /dev/null '
            + ("AAAA" if expected_ok else "BBBB"),
        )
        assert (result["returncode"] == 0) == expected_ok


def test_package_array_inventory_rejects_orphans_and_duplicate_authorities(tmp_path: Path) -> None:
    orphan = tmp_path / "orphan.sh"
    orphan.write_text("ORPHAN_PACKAGES=(one)\n", encoding="utf-8")
    with pytest.raises(AssertionError, match="orphan array"):
        _package_tool_array_inventory([orphan])
    one = tmp_path / "one.sh"
    two = tmp_path / "two.sh"
    one.write_text("ONE_PACKAGES=(same)\nprintf '%s' \"${ONE_PACKAGES[@]}\"\n", encoding="utf-8")
    two.write_text("TWO_PACKAGES=(same)\nprintf '%s' \"${TWO_PACKAGES[@]}\"\n", encoding="utf-8")
    with pytest.raises(AssertionError, match="duplicate array authority"):
        _package_tool_array_inventory([one, two])


def test_package_transformations_fail_closed_on_reorder_duplicate_and_omission(tmp_path: Path) -> None:
    canonical = _shell_contract(
        "ubuntu-packages", "--contract", str(CONTRACT), "--consumer", "ubuntu-install-source-baseline"
    )
    mutations = (
        [canonical[1], canonical[0], *canonical[2:]],
        [*canonical, canonical[-1]],
        canonical[:-1],
    )
    for index, mutated in enumerate(mutations):
        path = tmp_path / f"consumer-{index}.sh"
        path.write_text(
            "PACKAGES=(\n" + "\n".join(f"  {item}" for item in mutated) + "\n)\n",
            encoding="utf-8",
        )
        observed = _shell_contract("array", "--path", str(path), "--name", "PACKAGES")
        assert observed != canonical


def test_helper_has_no_password_or_arbitrary_external_root_channel() -> None:
    text = HELPER.read_text(encoding="utf-8")
    forbidden = ("sudo -S", "eval ", "bash -c", "sh -c", "PASSWORD", "read -s")
    assert all(value not in text for value in forbidden)
    assert "[ \"$#\" -eq 1 ]" in text
    assert 'validate_external_request "$@"' in text
    assert 'apt_arguments_allowed "$@"' in text
    assert "PKEXEC_UID" in text
    assert "ubuntu-desktop-gui-system" in text
    main = text.split("main() {", 1)[1].split("\n}\n\nvalidate_external_request()", 1)[0]
    assert "$2" not in main and "shift" not in main
    assert main.index('validate_external_request "$@"') < main.index("load_contract_values")


def _python_surfaces(path: Path) -> list[dict[str, str]]:
    result = _shell_contract(
        "python-surfaces", "--root", str(ROOT), "--path", str(path)
    )
    assert isinstance(result, list)
    return result


def test_structural_heredoc_scanner_handles_control_and_redirection_forms(tmp_path: Path) -> None:
    fixture = tmp_path / "forms.sh"
    fixture.write_text(
        "# python-surface: quoted-control\n"
        "/usr/bin/python3 -I - <<'FIRST' || exit 7\n"
        "print('first')\nFIRST\n"
        "# python-surface: tabbed-redirection\n"
        "/usr/bin/python3 -I - 2>/dev/null <<-'SECOND' && :\n"
        "\tprint('second')\n\tSECOND\n",
        encoding="utf-8",
    )
    surfaces = _python_surfaces(fixture)
    assert [(item["id"], item["kind"]) for item in surfaces] == [
        ("quoted-control", "heredoc"), ("tabbed-redirection", "heredoc")
    ]
    assert [item["body"] for item in surfaces] == ["print('first')\n", "print('second')\n"]


def test_scanner_records_delimiter_quoting_and_refuses_an_expanding_body(
    tmp_path: Path,
) -> None:
    """`<<'PY'` and `<<PY` are not the same surface.

    The scanner tokenized with `shlex(posix=True)`, which strips quotes, so both
    spellings produced the token `PY` and the inventory could not tell them
    apart. Bash expands the body of the unquoted form before Python receives it,
    so `$(...)`, backticks and `${...}` inside what reads as a Python literal are
    shell code running at this surface's privilege.

    Every production surface is quoted today, so this is not a live injection --
    it is the gate being unable to refuse the next one.
    """
    for spelling in ("<<PY", "<<-PY"):
        fixture = tmp_path / f"expanding{spelling.count('-')}.sh"
        fixture.write_text(
            "# python-surface: expanding\n"
            f"/usr/bin/python3 -I - {spelling}\n"
            "print('x')\nPY\n",
            encoding="utf-8",
        )
        result = subprocess.run(
            [sys.executable, "-I", str(SHELL_CONTRACT),
             "python-surfaces", "--root", str(ROOT), "--path", str(fixture)],
            text=True, capture_output=True, check=False, timeout=10,
        )
        assert result.returncode != 0, result.stdout
        assert "unquoted heredoc delimiter" in result.stderr, result.stderr

    # Both quoted spellings stay accepted, and the tab-stripping form still works.
    for spelling in ("<<'PY'", '<<"PY"'):
        fixture = tmp_path / f"quoted{len(spelling)}.sh"
        fixture.write_text(
            "# python-surface: quoted\n"
            f"/usr/bin/python3 -I - {spelling}\n"
            "print('x')\nPY\n",
            encoding="utf-8",
        )
        surfaces = _python_surfaces(fixture)
        assert [item["body"] for item in surfaces] == ["print('x')\n"]


def test_all_privileged_python_surfaces_match_manifest_and_python_312() -> None:
    expected = contract()["privilege"]["system_python_surfaces"]
    expected_shell_paths = {
        ROOT / item["path"] for item in expected if Path(item["path"]).suffix == ".sh"
    }
    discovered_shell_paths = {
        path for path in (ROOT / "scripts/ubuntu").glob("*.sh")
        if "/usr/bin/python3 -I" in path.read_text(encoding="utf-8")
    }
    assert discovered_shell_paths == expected_shell_paths
    paths = tuple(
        ROOT / relative for relative in dict.fromkeys(item["path"] for item in expected)
        if Path(relative).suffix == ".sh"
    )
    observed = [surface for path in paths for surface in _python_surfaces(path)]
    assert [
        {key: item[key] for key in ("id", "path", "kind")} for item in observed
    ] == expected
    for surface in observed:
        if surface["kind"] == "heredoc":
            ast.parse(surface["body"], feature_version=(3, 12))
    ast.parse(PUBLISHER.read_text(encoding="utf-8"), feature_version=(3, 12))


def test_system_python_inventory_is_complete_and_isolated() -> None:
    docs = (ROOT / "docs/reference/source-register.md").read_text(encoding="utf-8")
    for surface in (
        "scripts/ubuntu/privilege.sh", "scripts/ubuntu/privileged-helper.sh",
        "scripts/ubuntu/secure-publish.py", "scripts/ubuntu/verify.sh",
        "scripts/ubuntu/server.sh",
    ):
        assert surface in docs
    assert "/usr/bin/python3 -I" in PRIVILEGE.read_text(encoding="utf-8")
    assert "/usr/bin/python3 -I" in HELPER.read_text(encoding="utf-8")
    assert "/usr/bin/python3 -I" in (ROOT / "scripts/ubuntu/verify.sh").read_text(encoding="utf-8")
    assert "scripts/ci/shell_contract.py chrome-runtime" in docs
    helper = HELPER.read_text(encoding="utf-8")
    assert "zip(names, values, strict=True)" not in helper
    assert "assert len(names) == 7 and len(values) == 7" in helper


def test_secure_publisher_uses_anchored_no_follow_no_replace_and_fsync() -> None:
    text = PUBLISHER.read_text(encoding="utf-8")
    ast.parse(text)
    assert "dir_fd=" in text and "os.O_NOFOLLOW" in text
    assert "os.link(temp, leaf" in text
    assert "os.replace" not in text and "os.rename" not in text
    assert text.count("os.fsync(") >= 3
    assert "revalidate_authorized_chain(parent, chain, authority, sandbox_root)" in text
    assert "destination exists with divergent" in text


def test_publisher_race_contract_never_removes_destination() -> None:
    tree = ast.parse(PUBLISHER.read_text(encoding="utf-8"))
    calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
    unlink_args = [ast.unparse(node.args[0]) for node in calls if ast.unparse(node.func) == "os.unlink"]
    assert unlink_args and set(unlink_args) == {"temp"}


def _publisher_module():
    spec = importlib.util.spec_from_file_location("secure_publish", PUBLISHER)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class _RootStat:
    def __init__(self, value):
        self._value = value
        self.st_uid = 0
        self.st_gid = 0
        self.st_mode = value.st_mode & ~0o022

    def __getattr__(self, name):
        return getattr(self._value, name)


def _unprivileged_publisher(module, monkeypatch) -> None:
    real_fstat = module.os.fstat
    monkeypatch.setattr(module.os, "fstat", lambda fd: _RootStat(real_fstat(fd)))
    monkeypatch.setattr(module.os, "fchown", lambda _fd, _uid, _gid: None)


def test_no_replace_preserves_concurrent_destination_and_cleans_temp(tmp_path: Path, monkeypatch) -> None:
    module = _publisher_module()
    _unprivileged_publisher(module, monkeypatch)
    source = tmp_path / "source"
    destination = tmp_path / "destination"
    source.write_bytes(b"managed")
    digest = __import__("hashlib").sha256(source.read_bytes()).hexdigest()
    real_link = module.os.link

    def racing_link(*args, **kwargs):
        destination.symlink_to("unmanaged")
        return real_link(*args, **kwargs)

    monkeypatch.setattr(module.os, "link", racing_link)
    try:
        module.publish(str(source), str(destination), digest, 0o644)
    except FileExistsError:
        pass
    else:
        raise AssertionError("concurrent unmanaged destination was replaced")
    assert destination.is_symlink() and os.readlink(destination) == "unmanaged"
    assert not list(tmp_path.glob(".rldyour-publish.*"))


def test_ancestor_identity_race_stops_before_publish_and_cleans(tmp_path: Path, monkeypatch) -> None:
    module = _publisher_module()
    _unprivileged_publisher(module, monkeypatch)
    source = tmp_path / "source"
    destination = tmp_path / "destination"
    source.write_bytes(b"managed")
    digest = __import__("hashlib").sha256(source.read_bytes()).hexdigest()
    calls = 0
    real_revalidate = module.revalidate_authorized_chain

    def changed(path, expected, authority, sandbox_root):
        nonlocal calls
        calls += 1
        if calls == 1:
            raise RuntimeError("destination ancestor identity changed")
        return real_revalidate(path, expected, authority, sandbox_root)

    monkeypatch.setattr(module, "revalidate_authorized_chain", changed)
    try:
        module.publish(str(source), str(destination), digest, 0o644)
    except RuntimeError as error:
        assert "ancestor identity" in str(error)
    else:
        raise AssertionError("ancestor replacement was accepted")
    assert not destination.exists()
    assert not list(tmp_path.glob(".rldyour-publish.*"))


def test_publish_preserves_primary_error_and_reports_cleanup_error(tmp_path: Path, monkeypatch, capsys) -> None:
    module = _publisher_module()
    _unprivileged_publisher(module, monkeypatch)
    source = tmp_path / "source"
    destination = tmp_path / "destination"
    source.write_bytes(b"managed")
    digest = __import__("hashlib").sha256(source.read_bytes()).hexdigest()
    monkeypatch.setattr(module.os, "link", lambda *_a, **_kw: (_ for _ in ()).throw(PermissionError("primary")))
    monkeypatch.setattr(module.os, "unlink", lambda *_a, **_kw: (_ for _ in ()).throw(OSError("cleanup")))
    try:
        module.publish(str(source), str(destination), digest, 0o644)
    except PermissionError as error:
        assert str(error) == "primary"
    else:
        raise AssertionError("primary publication failure was lost")
    assert "secure-publish cleanup failed: cleanup" in capsys.readouterr().err


def test_actor_sandbox_publishes_only_beneath_private_owned_anchor(tmp_path: Path) -> None:
    module = _publisher_module()
    anchor = tmp_path / "actor-root"
    anchor.mkdir(mode=0o700)
    managed = anchor / "managed"
    managed.mkdir(mode=0o755)
    source = tmp_path / "source"
    source.write_bytes(b"managed")
    digest = __import__("hashlib").sha256(source.read_bytes()).hexdigest()
    destination = managed / "payload"
    module.publish(
        str(source), str(destination), digest, 0o644,
        module.AUTHORITY_SANDBOX, str(anchor),
    )
    assert destination.read_bytes() == b"managed"
    assert destination.stat().st_uid == os.geteuid()
    assert destination.stat().st_gid == os.getegid()


@pytest.mark.parametrize("mode", [0o755, 0o770, 0o777])
def test_actor_sandbox_rejects_nonprivate_anchor(tmp_path: Path, mode: int) -> None:
    module = _publisher_module()
    anchor = tmp_path / "actor-root"
    anchor.mkdir(mode=mode)
    anchor.chmod(mode)
    with pytest.raises(PermissionError, match="anchor"):
        module.open_actor_sandbox_chain(str(anchor), str(anchor))


def test_actor_sandbox_rejects_escape_symlink_mixed_authority_and_race(
    tmp_path: Path, monkeypatch,
) -> None:
    module = _publisher_module()
    anchor = tmp_path / "actor-root"
    anchor.mkdir(mode=0o700)
    outside = tmp_path / "outside"
    outside.mkdir(mode=0o700)
    with pytest.raises(PermissionError, match="production or escaped"):
        module.open_actor_sandbox_chain(str(outside), str(anchor))
    with pytest.raises(PermissionError, match="authority mode"):
        module.open_authorized_chain(str(anchor), module.AUTHORITY_ROOT, str(anchor))
    link = anchor / "link"
    link.symlink_to(outside, target_is_directory=True)
    with pytest.raises(OSError):
        module.open_actor_sandbox_chain(str(link), str(anchor))

    source = tmp_path / "source"
    source.write_bytes(b"managed")
    digest = __import__("hashlib").sha256(source.read_bytes()).hexdigest()
    real = module.revalidate_authorized_chain
    monkeypatch.setattr(
        module,
        "revalidate_authorized_chain",
        lambda *_args: (_ for _ in ()).throw(RuntimeError("destination ancestor identity changed")),
    )
    with pytest.raises(RuntimeError, match="identity changed"):
        module.publish(
            str(source), str(anchor / "payload"), digest, 0o644,
            module.AUTHORITY_SANDBOX, str(anchor),
        )
    monkeypatch.setattr(module, "revalidate_authorized_chain", real)
    assert not (anchor / "payload").exists()


def _receipt(error: BaseException) -> dict:
    marker = "authority-receipt="
    assert marker in str(error)
    return json.loads(str(error).split(marker, 1)[1])


def test_authority_diagnostic_contract_is_bounded_deterministic_and_redacted(tmp_path: Path) -> None:
    module = _publisher_module()
    observed = (11, 12, 501, 20, 0o775, 2, "directory")
    parent = (1, 2, 0, 0, 0o755, 2, "directory")
    values = [
        module.authority_error(
            "destination ancestor is not root-owned and non-writable",
            code="ANCESTOR_POLICY_MISMATCH", authority=module.AUTHORITY_ROOT,
            path_class="privilege-helper-directory", component_index=2,
            component_count=4,
            expected={"owner_uid": 0, "type": "directory", "writable_mask_forbidden": "0022"},
            observed=observed, parent=parent,
        )
        for _ in range(2)
    ]
    assert str(values[0]) == str(values[1])
    assert len(str(values[0]).encode()) <= module.MAX_DIAGNOSTIC_BYTES
    assert str(tmp_path) not in str(values[0])
    receipt = _receipt(values[0])
    assert receipt["schema"] == "rldyour.secure-publish-authority/v1"
    assert receipt["component_index"] == 2
    assert receipt["path_class"] == "privilege-helper-directory"
    assert receipt["observed"] == {
        "device": 11, "gid": 20, "inode": 12, "mode": "0775",
        "nlink": 2, "type": "directory", "uid": 501,
    }


def test_root_chain_reports_each_failing_ancestor_without_path_disclosure(
    tmp_path: Path, monkeypatch,
) -> None:
    module = _publisher_module()
    destination = tmp_path / "one" / "two"
    destination.mkdir(parents=True)
    components = list(filter(None, str(destination).split("/")))
    real_fstat = module.os.fstat

    for failed_index in range(len(components) + 1):
        calls = 0
        failing_call = 0 if failed_index == 0 else failed_index * 2

        def controlled(fd):
            nonlocal calls
            value = _RootStat(real_fstat(fd))
            current = calls
            calls += 1
            if current == failing_call:
                value.st_uid = 501
            return value

        monkeypatch.setattr(module.os, "fstat", controlled)
        with pytest.raises(module.AuthorityError) as caught:
            module.open_directory_chain(str(destination))
        receipt = _receipt(caught.value)
        assert receipt["component_index"] == failed_index
        assert receipt["code"] in {"ROOT_POLICY_MISMATCH", "ANCESTOR_POLICY_MISMATCH"}
        assert str(destination) not in str(caught.value)


def test_actor_chain_reports_anchor_and_descendant_policy_without_secret_paths(
    tmp_path: Path, monkeypatch,
) -> None:
    module = _publisher_module()
    anchor = tmp_path / "private-secret-anchor"
    descendant = anchor / "managed-secret-child"
    descendant.mkdir(parents=True)
    anchor.chmod(0o700)
    descendant.chmod(0o755)
    real_fstat = module.os.fstat
    actor = os.geteuid()

    class ActorStat:
        def __init__(self, value, *, mode=None, uid=None):
            self._value = value
            self.st_uid = actor if uid is None else uid
            self.st_gid = os.getegid()
            self.st_mode = value.st_mode if mode is None else stat.S_IFDIR | mode

        def __getattr__(self, name):
            return getattr(self._value, name)

    calls = 0
    anchor_call = len(list(filter(None, str(anchor).split("/"))))

    def bad_anchor(fd):
        nonlocal calls
        value = ActorStat(real_fstat(fd), mode=0o700)
        if calls == anchor_call:
            value.st_mode = stat.S_IFDIR | 0o770
        calls += 1
        return value

    monkeypatch.setattr(module.os, "fstat", bad_anchor)
    with pytest.raises(module.AuthorityError) as caught:
        module.open_actor_sandbox_chain(str(descendant), str(anchor))
    assert _receipt(caught.value)["code"] == "SANDBOX_ANCHOR_POLICY_MISMATCH"
    assert "private-secret" not in str(caught.value)

    calls = 0

    def bad_descendant(fd):
        nonlocal calls
        value = ActorStat(real_fstat(fd), mode=0o700 if calls <= anchor_call else 0o755)
        if calls == anchor_call + 2:
            value.st_uid = actor + 1
        calls += 1
        return value

    monkeypatch.setattr(module.os, "fstat", bad_descendant)
    with pytest.raises(module.AuthorityError) as caught:
        module.open_actor_sandbox_chain(str(descendant), str(anchor))
    assert _receipt(caught.value)["code"] == "SANDBOX_ANCESTOR_POLICY_MISMATCH"
    assert "managed-secret" not in str(caught.value)


def test_directory_identity_excludes_operational_metadata_but_detects_replacement() -> None:
    module = _publisher_module()
    diagnostics = contract()["privilege"]["authority_diagnostics"]
    assert diagnostics["directory_replacement_identity"] == ["device", "inode", "type"]
    assert diagnostics["directory_policy_revalidation"] == ["uid", "gid", "mode"]
    assert diagnostics["directory_operational_metadata"] == ["nlink", "size", "timestamps"]
    original = (11, 12, 0, 0, 0o755, 2, "directory")
    metadata_changed = (11, 12, 0, 0, 0o700, 99, "directory")
    assert module.first_directory_identity_mismatch([original], [metadata_changed]) is None
    assert module.first_directory_identity_mismatch(
        [original], [(11, 13, 0, 0, 0o755, 2, "directory")],
    ) == 0
    assert module.first_directory_identity_mismatch(
        [original], [(11, 12, 0, 0, 0o755, 2, "regular")],
    ) == 0


def test_root_chain_allows_owned_file_and_subdirectory_creation_but_detects_swap(
    tmp_path: Path, monkeypatch,
) -> None:
    module = _publisher_module()
    _unprivileged_publisher(module, monkeypatch)
    managed = tmp_path / "managed"
    managed.mkdir()
    fd, expected = module.open_directory_chain(str(managed))
    os.close(fd)
    (managed / "payload").write_bytes(b"owned")
    (managed / "child").mkdir()
    module.revalidate_authorized_chain(str(managed), expected, module.AUTHORITY_ROOT, None)

    displaced = tmp_path / "displaced"
    managed.rename(displaced)
    managed.mkdir()
    with pytest.raises(module.AuthorityError) as caught:
        module.revalidate_authorized_chain(str(managed), expected, module.AUTHORITY_ROOT, None)
    assert _receipt(caught.value)["code"] == "ANCESTOR_IDENTITY_CHANGED"


def test_actor_chain_distinguishes_policy_change_identity_change_and_symlink(
    tmp_path: Path,
) -> None:
    module = _publisher_module()
    anchor = tmp_path / "actor-root"
    managed = anchor / "managed"
    managed.mkdir(parents=True, mode=0o755)
    anchor.chmod(0o700)
    fd, expected = module.open_actor_sandbox_chain(str(managed), str(anchor))
    os.close(fd)

    (managed / "payload").write_bytes(b"owned")
    (managed / "child").mkdir()
    module.revalidate_authorized_chain(
        str(managed), expected, module.AUTHORITY_SANDBOX, str(anchor),
    )

    managed.chmod(0o777)
    with pytest.raises(module.AuthorityError) as policy_error:
        module.revalidate_authorized_chain(
            str(managed), expected, module.AUTHORITY_SANDBOX, str(anchor),
        )
    assert _receipt(policy_error.value)["code"] == "SANDBOX_ANCESTOR_POLICY_MISMATCH"
    managed.chmod(0o755)

    displaced = anchor / "displaced"
    managed.rename(displaced)
    managed.mkdir(mode=0o755)
    with pytest.raises(module.AuthorityError) as identity_error:
        module.revalidate_authorized_chain(
            str(managed), expected, module.AUTHORITY_SANDBOX, str(anchor),
        )
    assert _receipt(identity_error.value)["code"] == "ANCESTOR_IDENTITY_CHANGED"

    managed.rmdir()
    managed.symlink_to(displaced, target_is_directory=True)
    with pytest.raises(module.AuthorityError) as symlink_error:
        module.open_actor_sandbox_chain(str(managed), str(anchor))
    assert _receipt(symlink_error.value)["code"] == "SANDBOX_ANCESTOR_OPEN_FAILED"


def test_regular_file_identity_keeps_type_mode_size_and_digest_invariants(tmp_path: Path) -> None:
    module = _publisher_module()
    payload = tmp_path / "payload"
    payload.write_bytes(b"managed")
    digest = __import__("hashlib").sha256(b"managed").hexdigest()
    parent_fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        assert module.verify_existing(
            parent_fd, payload.name, digest, 0o644, os.geteuid(), os.getegid(),
        )
        payload.write_bytes(b"changed-size")
        with pytest.raises(FileExistsError, match="divergent identity or content"):
            module.verify_existing(
                parent_fd, payload.name, digest, 0o644, os.geteuid(), os.getegid(),
            )
        payload.unlink()
        payload.mkdir()
        with pytest.raises(PermissionError, match="regular file"):
            module.verify_existing(
                parent_fd, payload.name, digest, 0o644, os.geteuid(), os.getegid(),
            )
    finally:
        os.close(parent_fd)


def test_privilege_receipts_remain_private_and_use_fixed_privileged_reader() -> None:
    text = PRIVILEGE.read_text(encoding="utf-8")
    read_record = text.split("rldyour::privilege::read_record()", 1)[1].split("\n}", 1)[0]
    assert '"$RLDYOUR_PRIVILEGE_RECEIPT"|"$RLDYOUR_PRIVILEGE_TRANSACTION"' in read_record
    assert "rldyour::privilege::root_exec /bin/cat" in read_record
    assert "*" not in read_record.split("case", 1)[1].split("esac", 1)[0].replace("*)", "")
    assert "--mode 0600" in text


def test_hosted_native_fixture_models_clean_root_destination_authority() -> None:
    evidence = (ROOT / "scripts/ci/platform-evidence.sh").read_text(encoding="utf-8")
    assert "sudo chown root:root /usr/local" in evidence
    assert "sudo chmod 0755 /usr/local" in evidence
    assert "/usr/share /usr/share/polkit-1 /usr/share/polkit-1/actions" in evidence
    assert '"/usr/share", "/usr/share/polkit-1"' in evidence
    assert "not stat.S_IMODE(value.st_mode) & 0o022" in evidence
    assert "RLDYOUR_PRIVILEGE_SANDBOX_ROOT" not in evidence


def test_trusted_helper_binds_full_chain_and_running_script_descriptor() -> None:
    text = HELPER.read_text(encoding="utf-8")
    assert "os.O_DIRECTORY" in text and "os.O_NOFOLLOW" in text
    assert "value.st_uid == 0" in text
    assert "not stat.S_IMODE(value.st_mode) & 0o022" in text
    assert 'f"/proc/{os.getppid()}/fd/255"' in text
    assert "(expected.st_dev, expected.st_ino) == (actual.st_dev, actual.st_ino)" in text


def test_external_github_comment_examples_are_literal_body_file_only() -> None:
    candidates = list((ROOT / "scripts").rglob("*.sh")) + list((ROOT / ".github").rglob("*.yml"))
    for path in candidates:
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            if "gh issue comment" in line:
                assert "--body-file" in line and "--body " not in line, path


def test_environment_is_sanitized_before_helper_dispatch() -> None:
    text = HELPER.read_text(encoding="utf-8")
    for name in ("BASH_ENV", "ENV", "LD_PRELOAD", "PYTHONPATH", "RUBYLIB", "PERL5LIB"):
        assert name in text
    assert text.startswith("#!/bin/bash -p\n")
    assert "PATH=$SAFE_PATH" in text


def test_state_machine_has_one_tty_prompt_then_only_noninteractive_sudo() -> None:
    text = PRIVILEGE.read_text(encoding="utf-8")
    assert text.count("/usr/bin/sudo -v") == 1
    assert "/usr/bin/sudo -S" not in text
    assert text.count("/usr/bin/sudo -n") >= 4
    assert "[ -t 0 ] && [ -t 1 ]" in text
    assert "NONINTERACTIVE_AUTH_UNAVAILABLE" in text
    assert "CACHE_EXPIRED" in text


def test_root_desktop_preflight_provisions_fixed_helper_but_server_stays_sourceable() -> None:
    text = PRIVILEGE.read_text(encoding="utf-8")
    provision = text.split("rldyour::privilege::provision_for_profile()", 1)[1].split("\n}\n", 1)[0]
    assert '[ "$profile" = server ] && return 0' in provision
    assert "rldyour::privilege::provision_bundle" in provision
    root_block = text.split('if [ "${EUID:-$(/usr/bin/id -u)}" -eq 0 ]; then', 1)[1].split(
        'if rldyour::privilege::absolute_tool /usr/bin/sudo', 1
    )[0]
    assert 'rldyour::privilege::provision_for_profile "$profile"' in root_block


def test_policykit_failure_results_are_typed_and_never_fall_back() -> None:
    text = PRIVILEGE.read_text(encoding="utf-8")
    operation = text.split("rldyour::privilege::operation()", 1)[1]
    for status in (
        "AUTH_TIMEOUT", "AUTH_CANCELLED", "AUTH_DENIED_OR_UNAVAILABLE",
        "OPERATION_FAILED", "UNKNOWN_OR_INCOMPATIBLE_OPERATION",
    ):
        assert status in operation
    policy_block = operation.split("policykit)", 1)[1].split("plan)", 1)[0]
    assert "/usr/bin/sudo" not in policy_block
    # pkexec moved into rldyour::privilege::policykit_wait, which is where the
    # authentication bound now lives; the branch that types the outcome must not
    # invoke it a second time.
    assert policy_block.count("/usr/bin/pkexec") == 0
    assert "rldyour::privilege::policykit_wait" in policy_block
    wait_block = text.split("rldyour::privilege::policykit_wait() {", 1)[1].split("\n}", 1)[0]
    assert wait_block.count("/usr/bin/pkexec") == 1
    # The bound it applies is authentication, and it must no longer be applied
    # through `timeout --foreground`, which GNU coreutils documents as not timing
    # out children at all. Comments are stripped first: the replacement explains
    # what it replaced, and naming the old spelling must stay allowed.
    executable = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    assert "timeout --foreground" not in executable


def test_profile_callers_use_only_composed_contract_operations() -> None:
    install = (ROOT / "scripts/ubuntu/install.sh").read_text(encoding="utf-8")
    desktop = (ROOT / "scripts/ubuntu/desktop.sh").read_text(encoding="utf-8")
    server = (ROOT / "scripts/ubuntu/server.sh").read_text(encoding="utf-8")
    assert "ubuntu-desktop-system" in install and "ubuntu-desktop-gui-system" in install
    assert "rldyour::privilege::operation" not in desktop
    assert "rldyour::privilege::as_root" in server
    assert "ubuntu-server-system) result DELEGATED_TO_SERVER_MODULE" in HELPER.read_text(encoding="utf-8")


def test_receipt_and_partial_transaction_are_immutable_fail_closed() -> None:
    text = PRIVILEGE.read_text(encoding="utf-8")
    assert "record_valid \"$RLDYOUR_PRIVILEGE_TRANSACTION\"" in text
    assert "targets another source revision" in text
    assert "unmanaged privilege destination exists; preserved" in text
    assert "bundle is divergent; preserving it unchanged" in text
    assert "/bin/rm -f -- \"$RLDYOUR_PRIVILEGE_TRANSACTION\"" not in text
    assert "--destination \"$destination\"" in text


def test_helper_rejects_hostile_pkexec_subject_and_non_gui_operation() -> None:
    text = HELPER.read_text(encoding="utf-8")
    assert "policykit_subject_valid \"$caller_uid\"" in text
    assert '"/proc/{int(sys.argv[1])}/exe"' in text
    assert "/usr/bin/loginctl show-user" in text
    assert "[ \"$operation\" = ubuntu-desktop-gui-system ]" in text
    assert "POLICYKIT_OPERATION_DENIED" in text


def test_helper_cleanup_aggregates_primary_signal_and_cleanup_results() -> None:
    text = HELPER.read_text(encoding="utf-8")
    assert "local status=$?" in text
    assert "CLEANUP_FAILED" in text
    for signal_status in (129, 130, 143):
        assert f"on_signal {signal_status}" in text


def test_absolute_tool_follows_a_root_owned_alternatives_chain() -> None:
    """Ubuntu 26.04 ships sudo through the alternatives system (#57).

        /usr/bin/sudo -> /etc/alternatives/sudo -> /usr/bin/sudo.ws  (4755 root root)

    On 24.04 `/usr/bin/sudo` is that setuid file directly. `trusted_root_path`
    refuses symlinks outright, so on 26.04 the sudo-noninteractive branch was
    skipped and a non-TTY host fell through to NONINTERACTIVE_AUTH_UNAVAILABLE:
    the privilege state machine could not use sudo at all on a release the
    contract claims to support. Every 26.04 sandbox lane failed on it.

    The property is not "no symlinks" -- it is "nobody but root can change where
    this path leads". Ownership and the writability of each containing directory
    carry that; symlink modes do not, because Linux does not enforce them.
    """
    source = PRIVILEGE.read_text(encoding="utf-8")
    block = source.split("rldyour::privilege::absolute_tool() {", 1)[1].split("\n}", 1)[0]

    # Each hop's owner is checked, and the chain is bounded.
    assert "RLDYOUR_PRIVILEGE_MAX_LINK_DEPTH" in source
    assert "readlink" in block
    assert "'%u'" in block, "the link owner is no longer checked"
    # Directories above every hop keep the strict contract.
    assert "trusted_root_path \"$parent\"" in block
    # The resolved file keeps the mode contract.
    assert "0022" in block

    # Artifacts this repository publishes keep the strict, symlink-free check.
    strict = source.split("rldyour::privilege::trusted_root_path() {", 1)[1].split("\n}", 1)[0]
    assert '[ -L "$path" ]' in strict, (
        "the strict path check stopped refusing symlinks; only distribution "
        "tools may be reached through an alternatives chain"
    )


def test_only_distribution_tools_use_the_link_following_check() -> None:
    """Our own artifacts must still be real files at a fixed path."""
    source = PRIVILEGE.read_text(encoding="utf-8")
    callers = re.findall(r"absolute_tool (\S+)", source)
    assert callers, "absolute_tool has no callers"
    for target in callers:
        assert target.startswith("/usr/bin/"), (
            f"absolute_tool used for {target}, which is not a distribution tool"
        )
