from __future__ import annotations

import importlib.util
import os
import signal
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "scripts/ci/shell_function_harness.py"


def load_module():
    spec = importlib.util.spec_from_file_location("shell_function_harness", HARNESS)
    assert spec and spec.loader
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


HARNESS_MODULE = load_module()


def test_structural_extraction_preserves_nested_braces_comments_and_heredocs() -> None:
    source = '''before(){ :; }
target() {
  local text="{ quoted }" # } comment
  nested() { printf '%s' "${1:-value}"; }
  cat <<'PAYLOAD'
} literal heredoc
PAYLOAD
  nested
}
after(){ :; }
'''
    extracted = HARNESS_MODULE.extract_function(source, "target")
    assert extracted == source[source.index("target()"):source.index("\nafter()")]


@pytest.mark.parametrize("suffix", ["", "\n", "\r\n"])
def test_function_representation_ends_at_closing_brace(suffix: str) -> None:
    function = "target() {\n  :\n}"
    assert HARNESS_MODULE.extract_function(function + suffix, "target") == function


def test_adjacent_function_separator_is_not_part_of_representation() -> None:
    source = "first(){ :; }\n\nsecond() {\n  :\n}\nthird(){ :; }"
    assert HARNESS_MODULE.extract_function(source, "second") == "second() {\n  :\n}"


@pytest.mark.parametrize("operator,terminator", [
    ("<<EOF", "EOF"),
    ("<< 'EOF'", "EOF"),
    ('<<\"EOF\"', "EOF"),
    (r"<<\EOF", "EOF"),
    ("<<-\t'EOF'", "\tEOF"),
])
def test_structural_extraction_accepts_supported_literal_heredocs(
    operator: str, terminator: str,
) -> None:
    source = f"target() {{\n  cat {operator}\n}} ignored body brace\n{terminator}\n  :\n}}\n"
    expected = source[:source.rindex("}") + 1]
    assert HARNESS_MODULE.extract_function(source, "target") == expected


def test_structural_extraction_distinguishes_here_strings_from_heredocs() -> None:
    source = 'target() {\n  grep -q value <<<"$payload"\n}\n'
    assert HARNESS_MODULE.extract_function(source, "target") == source[:-1]


def test_structural_extraction_handles_queued_heredocs_and_crlf() -> None:
    source = "target() {\r\n  cat <<A <<-'B'\r\none\r\nA\r\n\ttwo } ignored\r\n\tB\r\n  :\r\n}\r\n"
    assert HARNESS_MODULE.extract_function(source, "target") == source[:-2]


def test_inventory_accepts_every_repository_shell_function() -> None:
    for path in sorted((ROOT / "scripts").rglob("*.sh")):
        source = HARNESS_MODULE.read_bounded(path)
        for name in HARNESS_MODULE.function_names(source):
            HARNESS_MODULE.extract_function(source, name)


@pytest.mark.parametrize("source", [
    "target(){ echo $(id); }\ntarget(){ :; }\n",
    "target(){ cat <<BAD-DASH\nvalue\nBAD-DASH\n}\n",
    "target(){ cat <<$DYNAMIC\nvalue\nDYNAMIC\n}\n",
    "target(){ cat <<'PART'IAL\nvalue\nPARTIAL\n}\n",
    "target(){ cat <<'UNCLOSED\nvalue\nUNCLOSED\n}\n",
    "target(){ cat <<EOF\nvalue\nEOF trailing\n}\n",
    "target(){ if true; then { :; }; fi\n",
])
def test_structural_extraction_rejects_duplicate_or_malformed_input(source: str) -> None:
    with pytest.raises(HARNESS_MODULE.HarnessError):
        HARNESS_MODULE.extract_function(source, "target")


def test_owned_capture_accepts_split_multibyte_utf8() -> None:
    result = HARNESS_MODULE.run_owned([
        sys.executable, "-c",
        "import os,time; os.write(1, b'\\xe2'); time.sleep(.05); os.write(1, b'\\x82\\xac')",
    ], timeout=1)
    assert result.stdout == "€"


def test_owned_capture_fails_closed_on_output_overflow() -> None:
    with pytest.raises(HARNESS_MODULE.HarnessError, match="bounded limit"):
        HARNESS_MODULE.run_owned([sys.executable, "-c", "import os; os.write(1, b'x'*300000)"], timeout=1)


def test_owned_capture_times_out_and_reaps_group() -> None:
    with pytest.raises(HARNESS_MODULE.HarnessError, match="timed out"):
        HARNESS_MODULE.run_owned([sys.executable, "-c", "import time; time.sleep(30)"], timeout=.1)


def _process_group_states(process_group: int) -> dict[int, str]:
    ps = shutil.which("ps")
    assert ps is not None
    observed = subprocess.run(
        [ps, "-axo", "pid=,pgid=,stat="], capture_output=True, text=True, check=True,
    )
    states: dict[int, str] = {}
    for line in observed.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and int(fields[1]) == process_group:
            states[int(fields[0])] = fields[2]
    return states


def test_leader_exit_with_term_ignoring_descendant_is_killed(tmp_path: Path) -> None:
    state_file = tmp_path / "child.state"
    code = (
        "import os,signal,time; p=os.fork(); "
        f"((open({str(state_file)!r},'w').write(f'{{p}} {{os.getpgid(p)}}'), os._exit(0)) "
        "if p else (signal.signal(signal.SIGTERM, signal.SIG_IGN), time.sleep(30)))"
    )
    with pytest.raises(HARNESS_MODULE.HarnessError, match="descendant retained"):
        HARNESS_MODULE.run_owned([sys.executable, "-c", code], timeout=2)
    child, process_group = map(int, state_file.read_text().split())
    states = _process_group_states(process_group)
    assert child not in states or states[child].startswith("Z"), states
    assert all(state.startswith("Z") for state in states.values()), states
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        states = _process_group_states(process_group)
        assert all(state.startswith("Z") for state in states.values()), states
        if not states:
            break
        time.sleep(.05)
    else:
        pytest.fail(f"terminated non-child process group was not system-reaped: {states}")


def test_spawn_signal_path_does_not_leave_a_child(monkeypatch) -> None:
    def interrupted(*_args, **_kwargs):
        raise KeyboardInterrupt
    monkeypatch.setattr(HARNESS_MODULE.subprocess, "Popen", interrupted)
    with pytest.raises(KeyboardInterrupt):
        HARNESS_MODULE.run_owned([sys.executable, "-c", "raise SystemExit(0)"])


def test_input_symlink_and_nonregular_are_rejected(tmp_path: Path) -> None:
    regular = tmp_path / "regular"
    regular.write_text("value")
    symlink = tmp_path / "link"
    symlink.symlink_to(regular)
    with pytest.raises(HARNESS_MODULE.HarnessError, match="regular file"):
        HARNESS_MODULE.read_bounded(symlink)
    with pytest.raises(HARNESS_MODULE.HarnessError, match="regular file"):
        HARNESS_MODULE.read_bounded(tmp_path)


def test_temp_replacement_is_preserved_and_reported(tmp_path: Path, monkeypatch) -> None:
    source = tmp_path / "source"; source.write_text("target(){ :; }\n")
    prelude = tmp_path / "prelude"; prelude.write_text("")
    call = tmp_path / "call"; call.write_text("target\n")
    monkeypatch.setattr(HARNESS_MODULE.tempfile, "gettempdir", lambda: str(tmp_path))
    real_run = HARNESS_MODULE.run_owned
    calls = 0
    def replace(argv, **kwargs):
        nonlocal calls
        calls += 1
        result = real_run(argv, **kwargs)
        if calls == 2:
            stage = next(tmp_path.glob(f"{HARNESS_MODULE.TEMP_PREFIX}*"))
            script = stage / "run.sh"
            script.unlink()
            script.symlink_to("attacker")
        return result
    monkeypatch.setattr(HARNESS_MODULE, "run_owned", replace)
    with pytest.raises(HARNESS_MODULE.HarnessError, match="TEMP_ENTRY_REPLACED"):
        HARNESS_MODULE.run(source, "target", prelude, call)
    stage = next(tmp_path.glob(f"{HARNESS_MODULE.TEMP_PREFIX}*"))
    assert (stage / "run.sh").is_symlink()


def test_primary_error_retains_cleanup_residual(tmp_path: Path, monkeypatch) -> None:
    source = tmp_path / "source"; source.write_text("target(){ :; }\n")
    prelude = tmp_path / "prelude"; prelude.write_text("")
    call = tmp_path / "call"; call.write_text("target\n")
    monkeypatch.setattr(HARNESS_MODULE, "run_owned", lambda *_a, **_kw: (_ for _ in ()).throw(RuntimeError("primary")))
    monkeypatch.setattr(HARNESS_MODULE.os, "unlink", lambda *_a, **_kw: (_ for _ in ()).throw(OSError("cleanup")))
    with pytest.raises(RuntimeError) as caught:
        HARNESS_MODULE.run(source, "target", prelude, call)
    assert any("TEMP_UNLINK_FAILED" in note for note in caught.value.__notes__)


def test_fd_close_failure_is_not_silently_successful(tmp_path: Path, monkeypatch) -> None:
    real_selector = HARNESS_MODULE.selectors.DefaultSelector
    class FaultySelector:
        def __init__(self): self.inner = real_selector()
        def register(self, *args): return self.inner.register(*args)
        def unregister(self, *args): return self.inner.unregister(*args)
        def select(self, *args): return self.inner.select(*args)
        def get_map(self): return self.inner.get_map()
        def close(self):
            self.inner.close()
            raise OSError("selector-close")
    monkeypatch.setattr(HARNESS_MODULE.selectors, "DefaultSelector", FaultySelector)
    owned = tmp_path / "portable-fixture.py"
    owned.write_text("raise SystemExit(0)\n", encoding="utf-8")
    owned.chmod(0o700)
    with pytest.raises(OSError, match="selector-close"):
        HARNESS_MODULE.run_owned([sys.executable, str(owned)], timeout=1)


def test_successful_transaction_leaves_no_temp_or_fd_leak(tmp_path: Path, monkeypatch) -> None:
    source = tmp_path / "source"; source.write_text("target(){ printf ok; }\n")
    prelude = tmp_path / "prelude"; prelude.write_text("")
    call = tmp_path / "call"; call.write_text("target\n")
    monkeypatch.setattr(HARNESS_MODULE.tempfile, "gettempdir", lambda: str(tmp_path))
    before = len(list(Path("/dev/fd").iterdir())) if Path("/dev/fd").exists() else 0
    result = HARNESS_MODULE.run(source, "target", prelude, call)
    after = len(list(Path("/dev/fd").iterdir())) if Path("/dev/fd").exists() else 0
    assert result == {"returncode": 0, "stdout": "ok", "stderr": ""}
    assert not list(tmp_path.glob(f"{HARNESS_MODULE.TEMP_PREFIX}*"))
    assert after <= before + 1


def _owned_stage(tmp_path: Path) -> tuple[Path, int, os.stat_result, os.stat_result, int, os.stat_result, str, os.stat_result]:
    parent_path_identity = tmp_path.lstat()
    parent_fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    parent_identity = os.fstat(parent_fd)
    stage = Path(HARNESS_MODULE.tempfile.mkdtemp(prefix="stage-", dir=tmp_path))
    stage_fd = os.open(stage.name, os.O_RDONLY | os.O_DIRECTORY, dir_fd=parent_fd)
    script_fd = os.open("run.sh", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=stage_fd)
    os.write(script_fd, b"true\n"); os.close(script_fd)
    return tmp_path, parent_fd, parent_identity, parent_path_identity, stage_fd, os.fstat(stage_fd), stage.name, os.stat("run.sh", dir_fd=stage_fd)


def test_directory_identity_is_independent_of_platform_link_count(tmp_path: Path) -> None:
    observed = tmp_path.stat()
    for link_count in (1, 2, 3, 127):
        fields = list(observed)
        fields[3] = link_count
        variant = os.stat_result(fields)
        assert HARNESS_MODULE._directory_identity(variant, observed)


def test_regular_identity_requires_single_link_exact_size_and_mode(tmp_path: Path) -> None:
    target = tmp_path / "target"
    target.write_bytes(b"owned")
    target.chmod(0o600)
    expected = target.stat()
    assert HARNESS_MODULE._regular_identity(target.stat(), expected)
    for index, replacement in ((3, 2), (6, expected.st_size + 1), (0, expected.st_mode | 0o022)):
        fields = list(expected)
        fields[index] = replacement
        assert not HARNESS_MODULE._regular_identity(os.stat_result(fields), expected)


def test_cleanup_preserves_replaced_ancestor(tmp_path: Path) -> None:
    state = _owned_stage(tmp_path)
    parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, script_identity = state
    moved = tmp_path.with_name(tmp_path.name + "-moved")
    tmp_path.rename(moved)
    tmp_path.mkdir()
    errors = HARNESS_MODULE.cleanup_owned_stage(
        parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, {"run.sh": script_identity}
    )
    assert "TEMP_PARENT_PATH_REPLACED" in errors
    assert (moved / stage_name).exists()


def test_cleanup_preserves_unexpected_nested_entry(tmp_path: Path) -> None:
    state = _owned_stage(tmp_path)
    parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, script_identity = state
    os.mkdir("unexpected", dir_fd=stage_fd)
    errors = HARNESS_MODULE.cleanup_owned_stage(
        parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, {"run.sh": script_identity}
    )
    assert "TEMP_UNEXPECTED_ENTRY:unexpected" in errors
    assert (tmp_path / stage_name / "unexpected").is_dir()


def test_cleanup_preserves_expected_name_inode_swap(tmp_path: Path) -> None:
    state = _owned_stage(tmp_path)
    parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, script_identity = state
    os.unlink("run.sh", dir_fd=stage_fd)
    replacement = os.open("run.sh", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=stage_fd)
    os.write(replacement, b"attacker\n"); os.close(replacement)
    errors = HARNESS_MODULE.cleanup_owned_stage(
        parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, {"run.sh": script_identity}
    )
    assert "TEMP_ENTRY_REPLACED:run.sh" in errors
    assert (tmp_path / stage_name / "run.sh").read_bytes() == b"attacker\n"


def test_cleanup_preserves_replacement_empty_stage_with_same_mode_and_links(tmp_path: Path) -> None:
    state = _owned_stage(tmp_path)
    parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, script_identity = state
    original = tmp_path / stage_name
    os.unlink("run.sh", dir_fd=stage_fd)
    original.rename(tmp_path / f"{stage_name}-original")
    original.mkdir(mode=0o700)
    errors = HARNESS_MODULE.cleanup_owned_stage(
        parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, {}
    )
    assert "TEMP_STAGE_REPLACED" in errors
    assert original.is_dir()


def test_creation_capture_failure_preserves_unproven_stage(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(HARNESS_MODULE.tempfile, "gettempdir", lambda: str(tmp_path))
    real_fstat = HARNESS_MODULE.os.fstat
    calls = 0
    def fail_stage_capture(fd):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError("capture")
        return real_fstat(fd)
    monkeypatch.setattr(HARNESS_MODULE.os, "fstat", fail_stage_capture)
    with pytest.raises(OSError) as caught:
        HARNESS_MODULE.create_owned_stage()
    assert any("TEMP_STAGE_IDENTITY_UNAVAILABLE" in note for note in caught.value.__notes__)
    assert any(tmp_path.iterdir())


def test_cleanup_detects_stage_reopen_identity_mismatch(tmp_path: Path, monkeypatch) -> None:
    state = _owned_stage(tmp_path)
    parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, script_identity = state
    real_fstat = HARNESS_MODULE.os.fstat
    calls = 0
    def mismatch(fd):
        nonlocal calls
        calls += 1
        value = real_fstat(fd)
        if calls == 2:
            values = list(value)
            values[1] += 1
            return os.stat_result(values)
        return value
    monkeypatch.setattr(HARNESS_MODULE.os, "fstat", mismatch)
    errors = HARNESS_MODULE.cleanup_owned_stage(
        parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, {"run.sh": script_identity}
    )
    assert "TEMP_STAGE_REOPEN_MISMATCH" in errors


@pytest.mark.parametrize("operation,signature", [
    ("unlink", "TEMP_UNLINK_FAILED"),
    ("rmdir", "TEMP_RMDIR_FAILED"),
    ("close", "TEMP_STAGE_CLOSE_FAILED"),
])
def test_cleanup_faults_are_typed(tmp_path: Path, monkeypatch, operation: str, signature: str) -> None:
    state = _owned_stage(tmp_path)
    parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, script_identity = state
    real = getattr(HARNESS_MODULE.os, operation)
    calls = 0
    def fail_once(*args, **kwargs):
        nonlocal calls
        if operation == "close" and args[0] != stage_fd:
            return real(*args, **kwargs)
        calls += 1
        if calls == 1:
            raise OSError("injected")
        return real(*args, **kwargs)
    monkeypatch.setattr(HARNESS_MODULE.os, operation, fail_once)
    errors = HARNESS_MODULE.cleanup_owned_stage(
        parent_path, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name, {"run.sh": script_identity}
    )
    assert any(signature in error for error in errors)
