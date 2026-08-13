#!/usr/bin/env python3
"""Extract and execute one Bash function through a bounded test-only harness."""

from __future__ import annotations

import argparse
import json
import os
import re
import selectors
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCHEMA = "rldyour.shell-function-harness/v1"
MAX_BYTES = 1024 * 1024
MAX_OUTPUT = 256 * 1024
TIMEOUT_SECONDS = 15
TEMP_PREFIX = "rldyour-shell-harness-"
HEREDOC_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class HarnessError(ValueError):
    pass


def read_bounded(path: Path) -> str:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise HarnessError(f"input is not a regular file: {path}")
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    primary: BaseException | None = None
    value = b""
    try:
        opened = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise HarnessError(f"input identity changed: {path}")
        if opened.st_size < 0 or opened.st_size > MAX_BYTES:
            raise HarnessError(f"input exceeds {MAX_BYTES} bytes")
        chunks: list[bytes] = []
        remaining = MAX_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        value = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
            != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            or len(value) != after.st_size
        ):
            raise HarnessError(f"input changed while reading: {path}")
    except BaseException as error:
        primary = error
    try:
        os.close(descriptor)
    except OSError as error:
        if primary is not None:
            primary.add_note(f"input close residual: {error}")
        else:
            raise
    if primary is not None:
        raise primary
    if len(value) > MAX_BYTES:
        raise HarnessError(f"input exceeds {MAX_BYTES} bytes")
    return value.decode("utf-8")


def _function_starts(source: str, name: str) -> list[re.Match[str]]:
    escaped = re.escape(name)
    pattern = re.compile(
        rf"(?m)^[ \t]*(?:function[ \t]+{escaped}(?:[ \t]*\(\))?|{escaped}[ \t]*\(\))[ \t]*\{{"
    )
    return list(pattern.finditer(source))


def function_names(source: str) -> list[str]:
    names = re.findall(
        r"(?m)^[ \t]*(?:function[ \t]+([A-Za-z_][A-Za-z0-9_:]*)(?:[ \t]*\(\))?|"
        r"([A-Za-z_][A-Za-z0-9_:]*)[ \t]*\(\))[ \t]*\{",
        source,
    )
    result = [left or right for left, right in names]
    if len(result) != len(set(result)):
        raise HarnessError("duplicate function declaration")
    return result


def _heredoc_at(source: str, index: int) -> tuple[int, str, bool] | None:
    """Parse the repository's bounded literal heredoc grammar at ``index``.

    Bash here-strings (``<<<``) are a different redirection and return ``None``.
    Supported heredoc words are unquoted, wholly single/double quoted, or
    backslash quoted identifiers. Dynamic and partially quoted words are
    deliberately outside the structural harness contract.
    """
    if not source.startswith("<<", index) or source.startswith("<<<", index):
        return None
    cursor = index + 2
    strip_tabs = cursor < len(source) and source[cursor] == "-"
    if strip_tabs:
        cursor += 1
    while cursor < len(source) and source[cursor] in " \t":
        cursor += 1
    if cursor >= len(source) or source[cursor] in "\r\n":
        raise HarnessError("unsupported or malformed heredoc delimiter")
    quote = source[cursor] if source[cursor] in "'\"" else None
    escaped_word = source[cursor] == "\\"
    if quote is not None or escaped_word:
        cursor += 1
    match = HEREDOC_WORD.match(source, cursor)
    if match is None:
        raise HarnessError("unsupported or malformed heredoc delimiter")
    delimiter = match.group(0)
    cursor = match.end()
    if quote is not None:
        if cursor >= len(source) or source[cursor] != quote:
            raise HarnessError("unsupported or malformed heredoc delimiter")
        cursor += 1
    boundary = source[cursor:cursor + 1]
    if boundary and boundary not in " \t\r\n;|&()<>":
        raise HarnessError("unsupported or malformed heredoc delimiter")
    return cursor, delimiter, strip_tabs


def extract_function(source: str, name: str) -> str:
    """Return exact source from the declaration through its matched closing brace.

    A following newline or other separator belongs to the containing source,
    not to the function representation, and is never invented or consumed.
    """
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_:]*", name):
        raise HarnessError("invalid function name")
    starts = _function_starts(source, name)
    if len(starts) != 1:
        raise HarnessError(f"expected exactly one {name} declaration")
    start = starts[0].start()
    index = starts[0].end() - 1
    depth = 0
    quote: str | None = None
    comment = False
    escaped = False
    heredocs: list[tuple[str, bool]] = []
    line_start = False
    while index < len(source):
        if line_start and heredocs:
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            line = source[index:end]
            if line.endswith("\r"):
                line = line[:-1]
            delimiter, strip_tabs = heredocs[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                heredocs.pop(0)
            index = end
            line_start = False
            continue
        char = source[index]
        if char == "\n":
            comment = False
            line_start = bool(heredocs)
            index += 1
            continue
        if comment:
            index += 1
            continue
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\" and quote != "'":
            escaped = True
            index += 1
            continue
        if quote:
            if char == quote:
                quote = None
            index += 1
            continue
        if char in "'\"":
            quote = char
            index += 1
            continue
        if char == "#" and (index == 0 or source[index - 1].isspace() or source[index - 1] in ";({"):
            comment = True
            index += 1
            continue
        if source.startswith("<<<", index):
            index += 3
            continue
        if source.startswith("<<", index):
            parsed = _heredoc_at(source, index)
            if parsed is None:
                raise HarnessError("unsupported or malformed heredoc delimiter")
            index, delimiter, strip_tabs = parsed
            heredocs.append((delimiter, strip_tabs))
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
            if depth < 0:
                break
        index += 1
    raise HarnessError(f"unclosed {name} declaration")


def run(source: Path, name: str, prelude: Path, call: Path, timeout: float = TIMEOUT_SECONDS) -> dict[str, object]:
    function = extract_function(read_bounded(source), name)
    prelude_text = read_bounded(prelude)
    call_text = read_bounded(call)
    parent, parent_fd, parent_identity, parent_path_identity, directory, stage_fd, stage_identity = create_owned_stage()
    stage_name = directory.name
    primary: BaseException | None = None
    result: dict[str, object] | None = None
    script_read_fd: int | None = None
    try:
        script = directory / "run.sh"
        descriptor = os.open("run.sh", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600, dir_fd=stage_fd)
        payload = ("set -euo pipefail\n" + prelude_text + "\n" + function + "\n" + call_text + "\n").encode()
        try:
            with os.fdopen(descriptor, "wb", closefd=True) as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
                script_identity = os.fstat(stream.fileno())
        except BaseException:
            try:
                os.close(descriptor)
            except OSError:
                pass
            raise
        current_script = os.stat("run.sh", dir_fd=stage_fd, follow_symlinks=False)
        if not _regular_identity(current_script, script_identity):
            raise HarnessError("owned script identity or mode is invalid")
        script_read_fd = os.open("run.sh", os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=stage_fd)
        if not _regular_identity(os.fstat(script_read_fd), script_identity):
            raise HarnessError("owned script descriptor identity is invalid")
        os.fsync(stage_fd)
        script_descriptor_path = f"/dev/fd/{script_read_fd}"
        syntax = run_owned(
            ["/bin/bash", "-n", script_descriptor_path], timeout=timeout,
            pass_fds=(script_read_fd,),
        )
        if syntax.returncode:
            raise HarnessError(f"generated Bash syntax rejected: {syntax.stderr.strip()}")
        completed = run_owned(
            ["/bin/bash", script_descriptor_path],
            env={"HOME": str(directory), "LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
            timeout=timeout,
            pass_fds=(script_read_fd,),
        )
        result = {"returncode": completed.returncode, "stdout": completed.stdout, "stderr": completed.stderr}
    except BaseException as error:
        primary = error
    if script_read_fd is not None:
        try:
            os.close(script_read_fd)
        except OSError as error:
            if primary is None:
                primary = HarnessError(f"owned script descriptor close failed: {error}")
            else:
                primary.add_note(f"script descriptor close residual: {error}")
    cleanup_errors = cleanup_owned_stage(
        parent, parent_fd, parent_identity, parent_path_identity, stage_fd, stage_identity, stage_name,
        {"run.sh": script_identity} if "script_identity" in locals() else {},
    )
    if primary is not None:
        for cleanup_error in cleanup_errors:
            primary.add_note(f"cleanup residual: {cleanup_error}")
        raise primary
    if cleanup_errors:
        raise HarnessError("cleanup residual: " + "; ".join(cleanup_errors))
    assert result is not None
    return result


def create_owned_stage() -> tuple[Path, int, os.stat_result, os.stat_result, Path, int, os.stat_result]:
    parent = Path(tempfile.gettempdir())
    parent_path_identity = parent.lstat()
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    stage_name: str | None = None
    stage_fd: int | None = None
    stage_identity: os.stat_result | None = None
    try:
        parent_identity = os.fstat(parent_fd)
        if not _same_identity(parent_identity, parent_path_identity):
            raise HarnessError("temporary parent identity changed")
        for _ in range(32):
            stage_name = TEMP_PREFIX + secrets.token_hex(12)
            try:
                os.mkdir(stage_name, 0o700, dir_fd=parent_fd)
                break
            except FileExistsError:
                continue
        else:
            raise HarnessError("could not allocate a unique owned stage")
        directory = parent / stage_name
        stage_fd = os.open(stage_name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent_fd)
        stage_identity = os.fstat(stage_fd)
        current = os.stat(stage_name, dir_fd=parent_fd, follow_symlinks=False)
        if not _directory_identity(current, stage_identity):
            raise HarnessError("temporary stage identity changed during creation")
        if (
            stat.S_IMODE(stage_identity.st_mode) != 0o700
            or stage_identity.st_uid != os.geteuid()
            or stage_identity.st_gid != os.getegid()
        ):
            raise HarnessError("temporary stage ownership or mode is invalid")
        return parent, parent_fd, parent_identity, parent_path_identity, directory, stage_fd, stage_identity
    except BaseException as primary:
        if stage_name is not None and stage_fd is not None and stage_identity is not None:
            for error in cleanup_owned_stage(
                parent, parent_fd, parent_identity, parent_path_identity,
                stage_fd, stage_identity, stage_name, {},
            ):
                primary.add_note(f"creation cleanup residual: {error}")
        else:
            if stage_fd is not None:
                try:
                    os.close(stage_fd)
                except OSError as error:
                    primary.add_note(f"creation stage close residual: {error}")
            if stage_name is not None:
                primary.add_note("creation cleanup residual: TEMP_STAGE_IDENTITY_UNAVAILABLE")
            try:
                os.close(parent_fd)
            except OSError as error:
                primary.add_note(f"creation parent close residual: {error}")
        raise


def _same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def _directory_identity(
    current: os.stat_result, expected: os.stat_result, *, mode: int | None = None
) -> bool:
    return (
        stat.S_ISDIR(current.st_mode)
        and stat.S_ISDIR(expected.st_mode)
        and _same_identity(current, expected)
        and current.st_uid == expected.st_uid
        and current.st_gid == expected.st_gid
        and stat.S_IMODE(current.st_mode) == (mode if mode is not None else stat.S_IMODE(expected.st_mode))
    )


def _regular_identity(current: os.stat_result, expected: os.stat_result) -> bool:
    return (
        stat.S_ISREG(current.st_mode)
        and stat.S_ISREG(expected.st_mode)
        and _same_identity(current, expected)
        and current.st_uid == expected.st_uid
        and current.st_gid == expected.st_gid
        and stat.S_IMODE(current.st_mode) == stat.S_IMODE(expected.st_mode) == 0o600
        and current.st_nlink == expected.st_nlink == 1
        and current.st_size == expected.st_size
    )


def cleanup_owned_stage(
    parent_path: Path,
    parent_fd: int,
    parent_identity: os.stat_result,
    parent_path_identity: os.stat_result,
    stage_fd: int,
    stage_identity: os.stat_result,
    stage_name: str,
    entries: dict[str, os.stat_result],
) -> list[str]:
    errors: list[str] = []
    safe_to_remove_stage = True
    try:
        current_parent = parent_path.lstat()
        if not _directory_identity(current_parent, parent_path_identity):
            errors.append("TEMP_PARENT_PATH_REPLACED")
            safe_to_remove_stage = False
        if not _directory_identity(os.fstat(parent_fd), parent_identity):
            errors.append("TEMP_PARENT_REPLACED")
            safe_to_remove_stage = False
        current_stage = os.stat(stage_name, dir_fd=parent_fd, follow_symlinks=False)
        if not _directory_identity(current_stage, stage_identity, mode=0o700):
            errors.append("TEMP_STAGE_REPLACED")
            safe_to_remove_stage = False
        reopened = os.open(stage_name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            reopened_identity = os.fstat(reopened)
        finally:
            os.close(reopened)
        if not _directory_identity(reopened_identity, stage_identity, mode=0o700):
            errors.append("TEMP_STAGE_REOPEN_MISMATCH")
            safe_to_remove_stage = False
        if not _directory_identity(os.fstat(stage_fd), stage_identity, mode=0o700):
            errors.append("TEMP_STAGE_FD_CHANGED")
            safe_to_remove_stage = False
        observed = set(os.listdir(stage_fd))
        unexpected = observed - set(entries)
        if unexpected:
            errors.append("TEMP_UNEXPECTED_ENTRY:" + ",".join(sorted(unexpected)))
            safe_to_remove_stage = False
        validated_entries: list[str] = []
        for name, expected in entries.items():
            try:
                current = os.stat(name, dir_fd=stage_fd, follow_symlinks=False)
            except FileNotFoundError:
                errors.append(f"TEMP_ENTRY_MISSING:{name}")
                safe_to_remove_stage = False
                continue
            valid = _regular_identity(current, expected)
            if not valid:
                errors.append(f"TEMP_ENTRY_REPLACED:{name}")
                safe_to_remove_stage = False
                continue
            validated_entries.append(name)
        if safe_to_remove_stage:
            for name in validated_entries:
                try:
                    current = os.stat(name, dir_fd=stage_fd, follow_symlinks=False)
                    expected = entries[name]
                    if not _regular_identity(current, expected):
                        raise HarnessError(f"TEMP_ENTRY_FINAL_IDENTITY_UNPROVEN:{name}")
                    os.unlink(name, dir_fd=stage_fd)
                except OSError as error:
                    errors.append(f"TEMP_UNLINK_FAILED:{name}:{error}")
                    safe_to_remove_stage = False
                except HarnessError as error:
                    errors.append(str(error))
                    safe_to_remove_stage = False
        try:
            os.fsync(stage_fd)
        except OSError as error:
            errors.append(f"TEMP_STAGE_FSYNC_FAILED:{error}")
            safe_to_remove_stage = False
        if safe_to_remove_stage:
            if os.listdir(stage_fd):
                raise HarnessError("TEMP_STAGE_NOT_EMPTY_AFTER_UNLINK")
            current_parent_path = parent_path.lstat()
            current_parent_fd = os.fstat(parent_fd)
            current_stage = os.stat(stage_name, dir_fd=parent_fd, follow_symlinks=False)
            current_stage_fd = os.fstat(stage_fd)
            if not (
                _directory_identity(current_parent_path, parent_path_identity)
                and _directory_identity(current_parent_fd, parent_identity)
                and _directory_identity(current_stage, stage_identity, mode=0o700)
                and _directory_identity(current_stage_fd, stage_identity, mode=0o700)
            ):
                raise HarnessError("TEMP_FINAL_IDENTITY_UNPROVEN")
            try:
                os.rmdir(stage_name, dir_fd=parent_fd)
            except OSError as error:
                errors.append(f"TEMP_RMDIR_FAILED:{error}")
            else:
                try:
                    os.fsync(parent_fd)
                except OSError as error:
                    errors.append(f"TEMP_PARENT_FSYNC_FAILED:{error}")
    except (OSError, HarnessError) as error:
        errors.append(f"TEMP_CLEANUP_FAILED:{error}")
    finally:
        try:
            os.close(stage_fd)
        except OSError as error:
            errors.append(f"TEMP_STAGE_CLOSE_FAILED:{error}")
        try:
            os.close(parent_fd)
        except OSError as error:
            errors.append(f"TEMP_PARENT_CLOSE_FAILED:{error}")
    return errors


class OwnedResult:
    def __init__(self, returncode: int, stdout: str, stderr: str) -> None:
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def run_owned(
    argv: list[str], *, env: dict[str, str] | None = None,
    timeout: float = TIMEOUT_SECONDS, pass_fds: tuple[int, ...] = (),
) -> OwnedResult:
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
            start_new_session=True, close_fds=True, pass_fds=pass_fds,
        )
    except BaseException:
        # Popen owns and closes any pipes it created when construction fails.
        raise
    selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    streams = {process.stdout: "stdout", process.stderr: "stderr"}
    assert process.stdout is not None and process.stderr is not None
    for stream in streams:
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    failure: str | None = None
    term_sent_at: float | None = None
    leader_exit_at: float | None = None
    try:
        while selector.get_map() or process.poll() is None:
            now = time.monotonic()
            if failure is None and now >= deadline:
                failure = "target timed out"
            if process.poll() is not None and selector.get_map() and failure is None:
                leader_exit_at = leader_exit_at or now
                if now - leader_exit_at >= 0.2:
                    failure = "descendant retained output pipe after leader exit"
            if failure is not None and term_sent_at is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                term_sent_at = now
            if term_sent_at is not None and now - term_sent_at >= 0.5:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            events = selector.select(0.05)
            for key, _ in events:
                stream = key.fileobj
                try:
                    chunk = os.read(stream.fileno(), 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                    continue
                target = buffers[streams[stream]]
                if sum(map(len, buffers.values())) + len(chunk) > MAX_OUTPUT:
                    failure = f"{streams[stream]} exceeds bounded limit"
                else:
                    target.extend(chunk)
            if failure is not None and term_sent_at is not None and now - term_sent_at > 1.0 and process.poll() is not None:
                for key in list(selector.get_map().values()):
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
        returncode = process.wait(timeout=1)
    except BaseException as primary:
        cleanup_errors: list[str] = []
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as error:
            cleanup_errors.append(f"group kill: {error}")
        try:
            process.wait(timeout=1)
        except BaseException as error:
            cleanup_errors.append(f"reap: {error}")
        for error in cleanup_errors:
            primary.add_note(f"cleanup residual: {error}")
        raise
    finally:
        for key in list(selector.get_map().values()):
            selector.unregister(key.fileobj)
            key.fileobj.close()
        selector.close()
    if failure is not None:
        raise HarnessError(failure)
    try:
        stdout = bytes(buffers["stdout"]).decode("utf-8")
        stderr = bytes(buffers["stderr"]).decode("utf-8")
    except UnicodeDecodeError as error:
        raise HarnessError("target output is not complete UTF-8") from error
    return OwnedResult(returncode, stdout, stderr)


def inventory(source_path: Path, tools: list[str]) -> dict[str, list[str]]:
    source = read_bounded(source_path)
    result = {tool: [] for tool in tools}
    for name in function_names(source):
        body = extract_function(source, name)
        for tool in tools:
            reference = re.compile(rf"(?<![A-Za-z0-9_./-]){re.escape(tool)}(?=[ \t;|&<>)])")
            if reference.search(body):
                result[tool].append(name)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="operation", required=True)
    execute = commands.add_parser("run")
    execute.add_argument("--source", required=True, type=Path)
    execute.add_argument("--function", required=True)
    execute.add_argument("--prelude", required=True, type=Path)
    execute.add_argument("--call", required=True, type=Path)
    execute.add_argument("--timeout", type=float, default=TIMEOUT_SECONDS)
    inspect = commands.add_parser("inventory")
    inspect.add_argument("--source", required=True, type=Path)
    inspect.add_argument("--tool", required=True, action="append")
    try:
        args = parser.parse_args(argv)
        if args.operation == "run":
            if not 0.1 <= args.timeout <= TIMEOUT_SECONDS:
                raise HarnessError("timeout is outside the bounded range")
            result = run(args.source, args.function, args.prelude, args.call, args.timeout)
        else:
            result = inventory(args.source, args.tool)
        print(json.dumps({"schema": SCHEMA, "result": result}, sort_keys=True, separators=(",", ":")))
        return 0
    except (HarnessError, OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        notes = "".join(f"; {note}" for note in getattr(error, "__notes__", ()))
        print(f"shell-function-harness: {error}{notes}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
