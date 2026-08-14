from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "config/script-inventory.json"
LAUNCHER = ROOT / "scripts/ci/run-locked-test-audit.sh"
RESOLVER = ROOT / "scripts/ci/resolve_validation_path.py"


def _owned_external_executable(tmp_path: Path, name: str = "external-tool") -> tuple[Path, tuple[int, int]]:
    target = tmp_path / "outside-managed-root" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"test-owned regular executable\n")
    target.chmod(0o755)
    value = target.stat()
    return target, (value.st_dev, value.st_ino)


def _resolver_module():
    spec = importlib.util.spec_from_file_location("resolve_validation_path", RESOLVER)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _imports(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    result: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            result.update(alias.name.split(".", 1)[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            result.add(node.module.split(".", 1)[0])
    return result - {"__future__"}


def _manifest() -> dict[str, dict[str, object]]:
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert data["schema"] == "rldyour.script-inventory/v1"
    return {
        entry["path"]: entry
        for entry in data["entries"]
        if entry["interpreter"] == "python" and entry["path"].startswith("scripts/ci/")
    }


def test_every_ci_python_entrypoint_has_one_dependency_class_and_launcher() -> None:
    entries = _manifest()
    discovered = {
        str(path.relative_to(ROOT)) for path in (ROOT / "scripts/ci").glob("*.py")
    }
    assert set(entries) == discovered
    for relative, declaration in entries.items():
        imports = _imports(ROOT / relative)
        third_party = imports - sys.stdlib_module_names
        if third_party:
            assert third_party == {"pyflakes"}
            assert declaration["dependency_class"] == "locked-test-tooling"
            assert declaration["launcher"] == "scripts/ci/run-locked-test-audit.sh"
        else:
            assert declaration["dependency_class"] in {"runtime-stdlib", "test-stdlib"}
            assert declaration["launcher"] in {"direct", "isolated-python"}


def test_runtime_validation_does_not_launch_or_import_test_tooling() -> None:
    validate = (ROOT / "scripts/ci/validate.sh").read_text(encoding="utf-8")
    assert 'python3 "$REPO_ROOT/scripts/ci/audit_test_modules.py"' not in validate
    assert "pyflakes" not in validate
    assert 'bash "$REPO_ROOT/scripts/ci/run-locked-test-audit.sh"' not in validate
    launcher = LAUNCHER.read_text(encoding="utf-8")
    assert all(token not in launcher for token in ("uv ", "pip ", "curl ", "wget "))


def test_locked_audit_has_one_workflow_launcher() -> None:
    workflow = (ROOT / ".github/workflows/pytest.yml").read_text(encoding="utf-8")
    assert workflow.count("bash scripts/ci/run-locked-test-audit.sh") == 1
    assert "RLDYOUR_LOCKED_TEST_PYTHON=\"$PWD/.venv/bin/python\"" in workflow
    assert "uv pip install --require-hashes -r requirements-test.txt" in workflow
    assert ".venv/.rldyour-requirements-test.sha256" in workflow


def test_locked_launcher_rejects_ambient_and_unlocked_interpreters(tmp_path: Path) -> None:
    environment = {
        **os.environ,
        "PYTHONHOME": str(tmp_path / "hostile-home"),
        "PYTHONPATH": str(tmp_path / "hostile-path"),
    }
    system_python = shutil.which("python3", path="/usr/bin:/bin")
    for selected in ("", "python3", system_python or "/usr/bin/python3"):
        result = subprocess.run(
            ["bash", str(LAUNCHER)],
            cwd=tmp_path,
            env={**environment, "RLDYOUR_LOCKED_TEST_PYTHON": selected},
            text=True,
            capture_output=True,
            check=False,
        )
        assert result.returncode != 0


def test_locked_python_predicate_and_main_preserve_all_exit_paths(tmp_path: Path) -> None:
    missing = tmp_path / "missing"
    directory = tmp_path / "directory"
    regular = tmp_path / "regular"
    executable = tmp_path / "executable"
    directory.mkdir()
    regular.write_text("not executable", encoding="utf-8")
    executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    executable.chmod(0o755)
    for candidate, expected in (
        (missing, 1), (directory, 1), (regular, 1), (executable, 0),
    ):
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; rldyour::ci::locked_python_usable "$2"',
             "_", str(LAUNCHER), str(candidate)],
            text=True, capture_output=True, check=False,
        )
        assert result.returncode == expected

    for candidate in (missing, directory, regular):
        result = subprocess.run(
            ["bash", str(LAUNCHER)],
            env={**os.environ, "RLDYOUR_LOCKED_TEST_PYTHON": str(candidate)},
            text=True, capture_output=True, check=False,
        )
        assert result.returncode == 2
        assert result.stderr == "locked test Python is missing or not executable\n"

    successful = subprocess.run(
        ["bash", str(LAUNCHER)],
        env={**os.environ, "RLDYOUR_LOCKED_TEST_PYTHON": str(executable)},
        text=True, capture_output=True, check=False,
    )
    assert successful.returncode == 0

    failing = tmp_path / "failing-python"
    failing.write_text("#!/bin/sh\nexit 37\n", encoding="utf-8")
    failing.chmod(0o755)
    result = subprocess.run(
        ["bash", str(LAUNCHER)],
        env={**os.environ, "RLDYOUR_LOCKED_TEST_PYTHON": str(failing)},
        text=True, capture_output=True, check=False,
    )
    assert result.returncode == 37


def test_new_security_shell_boundaries_forbid_ambiguous_and_or_fallbacks() -> None:
    paths = (
        ROOT / "scripts/ci/run-clean-validation.sh",
        ROOT / "scripts/ci/run-locked-test-audit.sh",
        ROOT / "scripts/ci/validate.sh",
        ROOT / "scripts/ubuntu/privilege.sh",
        ROOT / "scripts/ubuntu/privileged-helper.sh",
    )
    for path in paths:
        text = path.read_text(encoding="utf-8")
        assert "shellcheck disable=SC2015" not in text
        logical = text.replace("\\\n", " ")
        for number, line in enumerate(logical.splitlines(), 1):
            # The two branches of the double-quoted alternative must be
            # disjoint. `\\.` and `[^"]` both match a backslash, so the
            # alternation was ambiguous inside `*` and a run of backslashes with
            # no closing quote backtracked exponentially (CodeQL py/redos).
            # Excluding the backslash from the literal branch makes each
            # character match exactly one way.
            shell_tokens = re.sub(r"'[^']*'|\"(?:[^\"\\\\]|\\\\.)*\"", "", line)
            shell_tokens = shell_tokens.split("#", 1)[0]
            assert not re.search(r"&&.*\|\|", shell_tokens), f"{path}:{number}: {line}"


def test_dependency_classifier_rejects_undeclared_third_party_and_stale_launcher(tmp_path: Path) -> None:
    fixture = tmp_path / "fixture.py"
    fixture.write_text("import requests\n", encoding="utf-8")
    imports = _imports(fixture) - sys.stdlib_module_names
    assert imports == {"requests"}
    declaration = {"dependency_class": "runtime-stdlib", "launcher": "isolated-python"}
    with pytest.raises(AssertionError):
        assert not imports
    declaration = {"dependency_class": "locked-test-tooling", "launcher": "stale.sh"}
    with pytest.raises(AssertionError):
        assert declaration["launcher"] == "scripts/ci/run-locked-test-audit.sh"


def test_validation_path_resolution_supports_host_layouts_and_rejects_shadowing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = _resolver_module()
    monkeypatch.setattr(resolver, "_system_trusted", lambda path: path.resolve(strict=True))
    homebrew = tmp_path / "opt/homebrew/bin"
    system = tmp_path / "usr/bin"
    hosted = tmp_path / "hosted/bin"
    for directory in (homebrew, system, hosted):
        directory.mkdir(parents=True)
    for directory, names in (
        (homebrew, ("python3", "shellcheck")),
        (system, ("bash", "dirname", "find", "sort", "uname", "python3")),
        (hosted, ("rg",)),
    ):
        for name in names:
            target = directory / name
            target.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            target.chmod(0o755)
    assert resolver._candidate("rg", [hosted]) == hosted / "rg"
    assert resolver._candidate("python3", [system, homebrew], ignored_shadows=(homebrew,)) == system / "python3"
    with pytest.raises(resolver.ResolutionError, match="missing required command"):
        resolver._candidate("missing", [homebrew, system])
    duplicate = tmp_path / "shadow/bin"
    duplicate.mkdir(parents=True)
    shadow = duplicate / "rg"
    shadow.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    shadow.chmod(0o755)
    with pytest.raises(resolver.ResolutionError, match="duplicate or shadowed"):
        resolver._candidate("rg", [hosted, duplicate])


def test_validation_path_trust_rejects_group_writable_tool(tmp_path: Path) -> None:
    resolver = _resolver_module()
    tool = tmp_path / "tool"
    tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    tool.chmod(0o775)
    with pytest.raises(resolver.ResolutionError, match="untrusted"):
        resolver._system_trusted(tool)


def test_validation_path_manifest_declares_provider_neutral_managed_anchors() -> None:
    contract = json.loads((ROOT / "config/rldyour-contract.json").read_text(encoding="utf-8"))
    anchors = contract["ci_validation"]["managed_package_anchors"]
    assert {(item["command"], item["provider"]) for item in anchors} == {
        ("shellcheck", "homebrew"),
        ("rg", "homebrew"),
        ("rg", "codex-bundle"),
    }
    for anchor in anchors:
        assert anchor["version"] and anchor["package"] and anchor["executable"]
        assert anchor["version_pattern"] and anchor["version_argument"] == "--version"
        if anchor["provider"] == "homebrew":
            assert anchor["prefix"] == "/opt/homebrew"
            # ADR 0010: a rolling formula declares its class, not a build digest.
            assert anchor["determinism_class"] == "rolling-homebrew-formula"
            assert len(anchor["provenance_note"]) > 60
            for field in ("provenance_variants", "formula_revision", "bottle_tag",
                          "bottle_rebuild", "bottle_sha256", "executable_sha256"):
                assert field not in anchor, (
                    f"{anchor['command']} regained {field}, which homebrew-core moves "
                    "on every rebuild"
                )
        else:
            assert anchor["root"].startswith("$HOME/")
            assert len(anchor["receipt_sha256"]) == 64
            assert len(anchor["executable_sha256"]) == 64


def test_managed_anchor_inventory_rejects_duplicate_and_unknown_provider() -> None:
    resolver = _resolver_module()
    contract = json.loads((ROOT / "config/rldyour-contract.json").read_text(encoding="utf-8"))
    resolver._managed_anchors(contract, "darwin", "arm64")
    duplicate = json.loads(json.dumps(contract))
    duplicate["ci_validation"]["managed_package_anchors"].append(
        duplicate["ci_validation"]["managed_package_anchors"][0])
    with pytest.raises(resolver.ResolutionError, match="duplicated"):
        resolver._managed_anchors(duplicate, "darwin", "arm64")
    unknown = json.loads(json.dumps(contract))
    unknown["ci_validation"]["managed_package_anchors"][0]["provider"] = "ambient"
    with pytest.raises(resolver.ResolutionError, match="malformed"):
        resolver._managed_anchors(unknown, "darwin", "arm64")

    # Build provenance a resolver cannot verify must be refused, not ignored.
    # Leaving it accepted-but-unread is what let the schema read as a guarantee
    # while the resolver only tested a flat set of digests (ADR 0010).
    for field, value in (
        ("executable_sha256", "a" * 64),
        ("bottle_sha256", "a" * 64),
        ("formula_revision", "a" * 40),
        ("provenance_variants", [{"executable_sha256": "a" * 64}]),
    ):
        regressed = json.loads(json.dumps(contract))
        anchor = next(
            item for item in regressed["ci_validation"]["managed_package_anchors"]
            if item["provider"] == "homebrew"
        )
        anchor[field] = value
        with pytest.raises(resolver.ResolutionError, match="malformed|cannot verify"):
            resolver._managed_anchors(regressed, "darwin", "arm64")

    unclassified = json.loads(json.dumps(contract))
    anchor = next(
        item for item in unclassified["ci_validation"]["managed_package_anchors"]
        if item["provider"] == "homebrew"
    )
    del anchor["determinism_class"]
    with pytest.raises(resolver.ResolutionError, match="malformed"):
        resolver._managed_anchors(unclassified, "darwin", "arm64")


def test_candidate_requires_declared_provider_and_rejects_higher_shadow(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = _resolver_module()
    shadow_dir = tmp_path / "shadow"
    managed_dir = tmp_path / "managed"
    shadow_dir.mkdir()
    managed_dir.mkdir()
    for directory in (shadow_dir, managed_dir):
        tool = directory / "rg"
        tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        tool.chmod(0o755)
    monkeypatch.setattr(resolver, "_system_trusted", lambda _path: (_ for _ in ()).throw(
        resolver.ResolutionError("not system")))
    monkeypatch.setattr(resolver, "_bundle_trusted", lambda path, _anchor: (
        path.resolve() if path.parent == managed_dir else (_ for _ in ()).throw(
            resolver.ResolutionError("not declared bundle"))))
    anchor = {"provider": "codex-bundle"}
    with pytest.raises(resolver.ResolutionError, match="untrusted required command"):
        resolver._candidate("rg", [shadow_dir, managed_dir], anchors=(anchor,))
    assert resolver._candidate("rg", [managed_dir], anchors=(anchor,)) == managed_dir / "rg"


def test_managed_provider_precedence_is_manifest_owned(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = _resolver_module()
    home = tmp_path / "home"
    monkeypatch.setattr(resolver.Path, "home", classmethod(lambda _cls: home))
    brew = tmp_path / "brew"
    brew_tool = brew / "bin/rg"
    bundle_tool = home / "bundle/bin/rg"
    for tool in (brew_tool, bundle_tool):
        tool.parent.mkdir(parents=True, exist_ok=True)
        tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        tool.chmod(0o755)
    anchors = (
        {"provider": "homebrew", "prefix": str(brew), "command": "rg"},
        {"provider": "codex-bundle", "root": "$HOME/bundle", "executable": "bin/rg", "command": "rg"},
    )
    monkeypatch.setattr(resolver, "_homebrew_trusted", lambda path, _anchor: path)
    monkeypatch.setattr(resolver, "_bundle_trusted", lambda path, _anchor: path)
    assert resolver._managed_candidate("rg", [brew_tool.parent, bundle_tool.parent], anchors) == brew_tool
    with pytest.raises(resolver.ResolutionError, match="higher-precedence shadow"):
        resolver._managed_candidate("rg", [bundle_tool.parent, brew_tool.parent], anchors)


def test_managed_relative_paths_reject_escape_and_ambiguity() -> None:
    resolver = _resolver_module()
    for value in ("../bin/tool", "/bin/tool", "bin/../tool", ""):
        with pytest.raises(resolver.ResolutionError, match="escapes|invalid"):
            resolver._bounded_relative(value, "executable")


def test_bundle_anchor_binds_receipt_leaf_version_and_rejects_drift(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = _resolver_module()
    monkeypatch.setenv("HOME", str(tmp_path))
    root = tmp_path / "bundle"
    receipt = root / "package.json"
    executable = root / "vendor/bin/rg"
    executable.parent.mkdir(parents=True)
    receipt.write_text('{"name":"vendor/tool","version":"1.2.3"}\n', encoding="utf-8")
    executable.write_text("#!/bin/sh\necho 'ripgrep 9.8.7'\n", encoding="utf-8")
    executable.chmod(0o755)
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    anchor = {
        "root": "$HOME/bundle", "receipt": "package.json", "executable": "vendor/bin/rg",
        "package": "vendor/tool", "version": "1.2.3",
        "receipt_sha256": digest(receipt), "executable_sha256": digest(executable),
        "version_argument": "--version", "version_pattern": "ripgrep 9.8.7",
    }
    assert resolver._bundle_trusted(executable, anchor) == executable
    bad = {**anchor, "executable_sha256": "0" * 64}
    with pytest.raises(resolver.ResolutionError, match="hash mismatch"):
        resolver._bundle_trusted(executable, bad)
    outside, outside_identity = _owned_external_executable(tmp_path)
    executable.unlink()
    executable.symlink_to(outside)
    with pytest.raises(resolver.ResolutionError, match="escaped"):
        resolver._bundle_trusted(executable, anchor)
    value = outside.stat()
    assert (value.st_dev, value.st_ino) == outside_identity


def test_homebrew_anchor_binds_formula_receipt_alias_and_bottle(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = _resolver_module()
    prefix = tmp_path / "brew"
    keg = prefix / "Cellar/tool/1.2.3"
    executable = keg / "bin/tool"
    executable.parent.mkdir(parents=True)
    executable.write_text("#!/bin/sh\necho 'tool 1.2.3'\n", encoding="utf-8")
    executable.chmod(0o755)
    receipt = {
        "poured_from_bottle": True,
        "arch": "arm64",
        "source": {"tap": "homebrew/core", "versions": {"stable": "1.2.3"}},
    }
    (keg / "INSTALL_RECEIPT.json").write_text(json.dumps(receipt), encoding="utf-8")
    alias = prefix / "bin/tool"
    alias.parent.mkdir(parents=True)
    alias.symlink_to("../Cellar/tool/1.2.3/bin/tool")
    (prefix / "bin/brew").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (prefix / "bin/brew").chmod(0o755)
    observed_argv: list[list[str]] = []

    def fake_run(argv, **kwargs):
        del kwargs
        observed_argv.append(argv)
        return subprocess.CompletedProcess(argv, 0, "tool 1.2.3\n", "")

    monkeypatch.setattr(resolver.subprocess, "run", fake_run)
    anchor = {
        "prefix": str(prefix), "command": "tool", "package": "tool", "version": "1.2.3",
        "architecture": "arm64",
        "executable": "bin/tool",
        "determinism_class": "rolling-homebrew-formula",
        "version_argument": "--version", "version_pattern": "tool 1.2.3",
    }
    assert resolver._homebrew_trusted(alias, anchor) == executable
    assert observed_argv == [[str(executable), "--version"]]

    # A rebuilt bottle -- same formula, same version, different bytes -- must
    # still resolve. Under the previous frozen-digest model this was the failure
    # that turned an ordinary homebrew-core rebuild into a red required check,
    # and the reflex fix was to append another accepted hash (ADR 0010).
    executable.write_text("#!/bin/sh\necho 'tool 1.2.3'\n# rebuilt\n", encoding="utf-8")
    executable.chmod(0o755)
    observed_argv.clear()
    assert resolver._homebrew_trusted(alias, anchor) == executable

    # The locally verifiable chain still has to hold. A version the executable
    # does not report is refused.
    with pytest.raises(resolver.ResolutionError):
        resolver._homebrew_trusted(alias, {**anchor, "version_pattern": "tool 9.9.9"})

    # And a keg whose install receipt names a different stable version is refused,
    # which is what actually binds the executable to the declared version now.
    (keg / "INSTALL_RECEIPT.json").write_text(
        json.dumps({**receipt, "source": {"tap": "homebrew/core",
                                          "versions": {"stable": "9.9.9"}}}),
        encoding="utf-8",
    )
    with pytest.raises(resolver.ResolutionError):
        resolver._homebrew_trusted(alias, anchor)
    (keg / "INSTALL_RECEIPT.json").write_text(json.dumps(receipt), encoding="utf-8")

    outside, outside_identity = _owned_external_executable(tmp_path)
    alias.unlink()
    alias.symlink_to(outside)
    with pytest.raises(resolver.ResolutionError, match="target does not match"):
        resolver._homebrew_trusted(alias, anchor)
    value = outside.stat()
    assert (value.st_dev, value.st_ino) == outside_identity


def test_homebrew_anchor_rejects_missing_malformed_stale_and_wrong_arch_receipts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = _resolver_module()
    prefix = tmp_path / "brew"
    keg = prefix / "Cellar/tool/1"
    executable = keg / "bin/tool"
    executable.parent.mkdir(parents=True)
    executable.write_text("tool", encoding="utf-8")
    executable.chmod(0o755)
    alias = prefix / "bin/tool"
    alias.parent.mkdir(parents=True)
    alias.symlink_to("../Cellar/tool/1/bin/tool")
    anchor = {
        "prefix": str(prefix), "command": "tool", "package": "tool", "version": "1",
        "architecture": "arm64", "executable": "bin/tool", "provenance_variants": [{
            "formula_revision": "a" * 40, "bottle_tag": "arm64_test", "bottle_rebuild": 0,
            "bottle_sha256": "a" * 64,
            "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        }],
        "version_argument": "--version", "version_pattern": "tool 1",
    }
    receipt_path = keg / "INSTALL_RECEIPT.json"
    with pytest.raises(resolver.ResolutionError, match="unavailable or malformed"):
        resolver._homebrew_trusted(alias, anchor)
    receipt_path.write_text("not-json", encoding="utf-8")
    with pytest.raises(resolver.ResolutionError, match="unavailable or malformed"):
        resolver._homebrew_trusted(alias, anchor)
    base = {"poured_from_bottle": True, "arch": "arm64", "source": {
        "tap": "homebrew/core", "versions": {"stable": "1"}}}
    monkeypatch.setattr(resolver, "_run_version", lambda _path, _arg: "tool 1")
    for mutation in (
        {**base, "arch": "x86_64"},
        {**base, "source": {"tap": "other/core", "versions": {"stable": "1"}}},
        {**base, "source": {"tap": "homebrew/core", "versions": {"stable": "2"}}},
        {**base, "poured_from_bottle": False},
    ):
        receipt_path.write_text(json.dumps(mutation), encoding="utf-8")
        with pytest.raises(resolver.ResolutionError, match="identity/version mismatch"):
            resolver._homebrew_trusted(alias, anchor)


def test_bundle_anchor_rejects_missing_dangling_chain_and_wrong_object_kind(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = _resolver_module()
    monkeypatch.setenv("HOME", str(tmp_path))
    root = tmp_path / "bundle"
    root.mkdir()
    receipt = root / "package.json"
    receipt.write_text('{"name":"vendor/tool","version":"1"}\n', encoding="utf-8")
    executable = root / "bin/tool"
    executable.parent.mkdir()
    anchor = {
        "root": "$HOME/bundle", "receipt": "package.json", "executable": "bin/tool",
        "package": "vendor/tool", "version": "1",
        "receipt_sha256": hashlib.sha256(receipt.read_bytes()).hexdigest(),
        "executable_sha256": "0" * 64, "version_argument": "--version",
        "version_pattern": "tool 1",
    }
    with pytest.raises(resolver.ResolutionError, match="missing, dangling"):
        resolver._bundle_trusted(executable, anchor)
    executable.symlink_to(tmp_path / "does-not-exist")
    with pytest.raises(resolver.ResolutionError, match="missing, dangling"):
        resolver._bundle_trusted(executable, anchor)
    executable.unlink()
    loop = root / "bin/loop"
    executable.symlink_to(loop.name)
    loop.symlink_to(executable.name)
    with pytest.raises(resolver.ResolutionError, match="invalid symlink chain"):
        resolver._bundle_trusted(executable, anchor)
    executable.unlink()
    loop.unlink()
    intermediate = root / "bin/intermediate"
    outside, _identity = _owned_external_executable(tmp_path, "chain-target")
    intermediate.symlink_to(outside)
    executable.symlink_to(intermediate.name)
    with pytest.raises(resolver.ResolutionError, match="escaped"):
        resolver._bundle_trusted(executable, anchor)
    executable.unlink()
    executable.mkdir()
    with pytest.raises(resolver.ResolutionError, match="type is invalid"):
        resolver._bundle_trusted(executable, anchor)


def test_bundle_anchor_detects_identity_replacement_during_version_probe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = _resolver_module()
    monkeypatch.setenv("HOME", str(tmp_path))
    root = tmp_path / "bundle"
    receipt = root / "package.json"
    executable = root / "bin/tool"
    executable.parent.mkdir(parents=True)
    receipt.write_text('{"name":"vendor/tool","version":"1"}\n', encoding="utf-8")
    executable.write_text("original", encoding="utf-8")
    executable.chmod(0o755)
    anchor = {
        "root": "$HOME/bundle", "receipt": "package.json", "executable": "bin/tool",
        "package": "vendor/tool", "version": "1",
        "receipt_sha256": hashlib.sha256(receipt.read_bytes()).hexdigest(),
        "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "version_argument": "--version", "version_pattern": "tool 1",
    }

    def replace_during_probe(_path: Path, _argument: str) -> str:
        replacement = executable.with_name("replacement")
        replacement.write_text("replacement", encoding="utf-8")
        replacement.chmod(0o755)
        replacement.replace(executable)
        return "tool 1"

    monkeypatch.setattr(resolver, "_run_version", replace_during_probe)
    with pytest.raises(resolver.ResolutionError, match="identity changed"):
        resolver._bundle_trusted(executable, anchor)
