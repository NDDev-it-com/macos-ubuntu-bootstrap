"""Bounded static Bash contract parsers used by repository verification.

These parsers never execute the inspected shell.  They intentionally accept a
small declarative grammar and fail closed when shell evaluation could influence
the value observed by CI.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


class ShellContractError(ValueError):
    """The source is outside the supported static contract grammar."""


SCHEMA = "rldyour.shell-contract/v1"
MAX_INPUT_BYTES = 1024 * 1024
MAX_RESULT_ITEMS = 256
MAX_SOURCE_FILES = 128


@dataclass(frozen=True)
class SourceLocation:
    line: int
    column: int


def _logical_source(source: str) -> tuple[str, list[SourceLocation]]:
    """Join physical continuations before layout/token processing.

    Bash removes an unquoted or double-quoted backslash-newline pair before
    token recognition. Single quotes preserve every character. CRLF is one
    physical line ending; a bare CR is outside the supported grammar.
    """
    logical: list[str] = []
    locations: list[SourceLocation] = []
    index = 0
    line = column = 1
    quote: str | None = None
    comment = False
    while index < len(source):
        char = source[index]
        if char == "\r":
            if index + 1 >= len(source) or source[index + 1] != "\n":
                raise ShellContractError(f"bare CR at {line}:{column}")
            newline_width = 2
        elif char == "\n":
            newline_width = 1
        else:
            newline_width = 0
        if char == "\\" and quote != "'":
            if source.startswith("\\\r\n", index) or source.startswith("\\\n", index):
                width = 3 if source.startswith("\\\r\n", index) else 2
                index += width
                line += 1
                column = 1
                continue
        if newline_width:
            logical.append("\n")
            locations.append(SourceLocation(line, column))
            index += newline_width
            line += 1
            column = 1
            comment = False
            continue
        logical.append(char)
        locations.append(SourceLocation(line, column))
        if quote is None and not comment and char == "#" and (
            len(logical) == 1 or logical[-2].isspace() or logical[-2] in "(;)"
        ):
            comment = True
        elif not comment and char in "'\"":
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
        if char == "\\" and quote != "'" and index + 1 < len(source):
            index += 1
            column += 1
            logical.append(source[index])
            locations.append(SourceLocation(line, column))
        index += 1
        column += 1
    return "".join(logical), locations


_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_ASSIGNMENT = re.compile(
    r"^[ \t]*(?:(?:declare|typeset)[ \t]+(?:-[A-Za-z]+[ \t]+)*|readonly[ \t]+(?:-a[ \t]+)?)?"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?P<operator>\+?=)",
    re.MULTILINE,
)
_FORBIDDEN_EVALUATION = frozenset("$`")
_FORBIDDEN_OPERATORS = frozenset(";|&<>[]")


def _skip_layout(source: str, index: int) -> int:
    while index < len(source):
        if source.startswith("\\\n", index):
            index += 2
        elif source[index].isspace():
            index += 1
        elif source[index] == "#":
            newline = source.find("\n", index)
            index = len(source) if newline < 0 else newline + 1
        else:
            break
    return index


def _where(locations: list[SourceLocation], index: int) -> str:
    location = locations[min(index, len(locations) - 1)] if locations else SourceLocation(1, 1)
    return f"{location.line}:{location.column}"


def _quoted(
    source: str, index: int, quote: str, locations: list[SourceLocation]
) -> tuple[str, int]:
    value: list[str] = []
    index += 1
    while index < len(source):
        char = source[index]
        if char == quote:
            return "".join(value), index + 1
        if quote == '"' and char in _FORBIDDEN_EVALUATION:
            raise ShellContractError(f"dynamic expansion is forbidden at {_where(locations, index)}")
        if quote == '"' and char == "\\":
            if index + 1 >= len(source):
                raise ShellContractError(f"unterminated escape at {_where(locations, index)}")
            escaped = source[index + 1]
            if escaped == "\n":
                index += 2
                continue
            if escaped not in {'"', "\\"}:
                raise ShellContractError(f"ambiguous double-quoted escape at {_where(locations, index)}")
            value.append(escaped)
            index += 2
            continue
        value.append(char)
        index += 1
    raise ShellContractError(f"unclosed quoted array element at {_where(locations, index - 1)}")


def _array_body(
    source: str, index: int, locations: list[SourceLocation]
) -> tuple[list[str], int]:
    values: list[str] = []
    while True:
        index = _skip_layout(source, index)
        if index >= len(source):
            raise ShellContractError(f"unclosed array declaration at {_where(locations, index - 1)}")
        if source[index] == ")":
            return values, index + 1

        pieces: list[str] = []
        while index < len(source):
            char = source[index]
            if char.isspace() or source.startswith("\\\n", index) or char == ")":
                break
            if char in _FORBIDDEN_EVALUATION:
                raise ShellContractError(f"dynamic expansion is forbidden at {_where(locations, index)}")
            if char in _FORBIDDEN_OPERATORS or char == "(":
                raise ShellContractError(f"shell operator is forbidden at {_where(locations, index)}")
            if char in "'\"":
                piece, index = _quoted(source, index, char, locations)
                pieces.append(piece)
                continue
            if char == "\\":
                if index + 1 >= len(source):
                    raise ShellContractError(f"unterminated escape at {_where(locations, index)}")
                escaped = source[index + 1]
                if escaped == "\n":
                    index += 2
                    continue
                pieces.append(escaped)
                index += 2
                continue
            pieces.append(char)
            index += 1
        if not pieces:
            raise ShellContractError(f"empty or ambiguous token at {_where(locations, index)}")
        values.append("".join(pieces))


def parse_static_array(source: str, name: str) -> list[str]:
    """Return one literal Bash array or reject non-declarative semantics.

    Supported declarations are ``NAME=(...)`` at the beginning of a logical
    source line. Elements may be bare, single quoted, or narrowly double quoted;
    comments, whitespace, and backslash-newline continuations are accepted.
    Any second assignment, append, expansion, operator, or malformed construct
    is rejected.
    """
    if not _NAME.fullmatch(name):
        raise ShellContractError("invalid requested array name")
    source, locations = _logical_source(source)
    writes = list(re.finditer(
        rf"^[ \t]*(?:(?:declare|typeset)[ \t]+(?:-[A-Za-z]+[ \t]+)*|readonly[ \t]+(?:-a[ \t]+)?)?"
        rf"{re.escape(name)}(?P<suffix>[ \t]*(?:\[[^\n]*\])?[ \t]*\+?=)",
        source,
        re.MULTILINE,
    ))
    if len(writes) != 1:
        raise ShellContractError(f"expected exactly one declaration of {name}")
    write = writes[0]
    if write.group("suffix").strip() != "=":
        raise ShellContractError(
            f"indexed or append assignment is forbidden at {_where(locations, write.start())}"
        )
    assignments = [match for match in _ASSIGNMENT.finditer(source) if match.group("name") == name]
    if len(assignments) != 1:
        raise ShellContractError(f"malformed declaration at {_where(locations, write.start())}")
    match = assignments[0]
    index = match.end()
    while index < len(source) and source[index] in " \t":
        index += 1
    if index >= len(source) or source[index] != "(":
        raise ShellContractError(f"{name} must be a static indexed array at {_where(locations, index)}")
    values, index = _array_body(source, index + 1, locations)
    line_end = source.find("\n", index)
    tail = source[index:] if line_end < 0 else source[index:line_end]
    if tail.strip() and not tail.lstrip().startswith("#"):
        raise ShellContractError(f"tokens after array declaration at {_where(locations, index)}")
    return values


# `<<` followed by an optional `-`, then the delimiter in one of three
# spellings. The quoted forms are captured separately from the bare one because
# the difference is the whole point: Bash expands the body of a heredoc whose
# delimiter is unquoted, and leaves it verbatim when it is quoted.
_HEREDOC_RE = re.compile(
    r"""<<(?P<dash>-?)[ \t]*(?:'(?P<single>[^']*)'|"(?P<double>[^"]*)"|(?P<bare>[A-Za-z_][A-Za-z0-9_]*))"""
)


def _heredoc_spec(logical: str) -> tuple[str, bool, bool] | None:
    """Return (delimiter, strip_tabs, expands) for the first heredoc, or None.

    Read from the raw logical line rather than from `_shell_tokens`, because
    `shlex(posix=True)` strips quotes: `<<'PY'` and `<<PY` both tokenize to
    `PY`, so the inventory could not tell a literal body from one Bash expands
    before Python ever sees it. That is exactly the distinction a privileged
    surface has to be judged on.
    """
    match = _HEREDOC_RE.search(logical)
    if match is None:
        return None
    delimiter = match.group("single")
    if delimiter is None:
        delimiter = match.group("double")
    expands = delimiter is None
    if delimiter is None:
        delimiter = match.group("bare")
    return delimiter, bool(match.group("dash")), expands


def _shell_tokens(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars="();<>|&")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    return list(lexer)


def python_surfaces(path: Path, root: Path) -> list[dict[str, str]]:
    """Inventory marked isolated system-Python commands without running shell."""
    lines = path.read_text(encoding="utf-8").splitlines()
    relative_path = str(path.relative_to(root)) if path.is_relative_to(root) else path.name
    surfaces: list[dict[str, str]] = []
    marker: str | None = None
    index = 0
    while index < len(lines):
        marker_match = re.fullmatch(r"\s*# python-surface: ([a-z0-9-]+)\s*", lines[index])
        if marker_match:
            if marker is not None:
                raise ShellContractError(f"nested Python surface marker in {path}")
            marker = marker_match.group(1)
            index += 1
            continue
        start = index
        logical_parts = [lines[index]]
        while logical_parts[-1].rstrip().endswith("\\"):
            logical_parts[-1] = logical_parts[-1].rstrip()[:-1]
            index += 1
            if index >= len(lines):
                raise ShellContractError(f"unterminated continuation in {path}")
            logical_parts.append(lines[index])
        logical = " ".join(logical_parts)
        index += 1
        if "-I" not in logical:
            if marker is not None and logical.strip() and not logical.lstrip().startswith("#"):
                raise ShellContractError(f"Python surface marker is not adjacent in {path}:{start + 1}")
            continue
        tokens = _shell_tokens(logical)
        if "-I" not in tokens:
            continue
        isolated = tokens.index("-I")
        if not any(token in {"python3", "/usr/bin/python3", "$python"} for token in tokens[:isolated]):
            raise ShellContractError(f"isolated non-system Python in {path}:{start + 1}")
        if marker is None:
            raise ShellContractError(f"unmarked isolated Python in {path}:{start + 1}")
        kind = "script"
        body = ""
        if "<<" in tokens:
            spec = _heredoc_spec(logical)
            if spec is None:
                raise ShellContractError(f"missing heredoc delimiter in {path}:{start + 1}")
            delimiter, strip_tabs, expands = spec
            if not delimiter:
                raise ShellContractError(f"empty heredoc delimiter in {path}:{start + 1}")
            if expands:
                # Bash expands the body before Python receives it, so `$(...)`,
                # backticks and `${...}` inside what reads as a Python literal
                # are shell code running at this surface's privilege. Every
                # production surface is quoted today; this makes that a rule
                # rather than a habit.
                raise ShellContractError(
                    f"unquoted heredoc delimiter <<{delimiter} on a system-Python surface in "
                    f"{path}:{start + 1}; quote it as <<'{delimiter}' so Bash does not expand "
                    "the body"
                )
            body_lines: list[str] = []
            while index < len(lines):
                candidate = lines[index].lstrip("\t") if strip_tabs else lines[index]
                if candidate == delimiter:
                    break
                body_lines.append(candidate)
                index += 1
            if index >= len(lines):
                raise ShellContractError(f"unterminated heredoc {delimiter} in {path}:{start + 1}")
            index += 1
            kind = "heredoc"
            body = "\n".join(body_lines) + "\n"
        surfaces.append({"id": marker, "path": relative_path, "kind": kind, "body": body})
        marker = None
    if marker is not None:
        raise ShellContractError(f"orphan Python surface marker in {path}")
    return surfaces


def _read_bounded(path: Path) -> str:
    with path.open("rb") as stream:
        payload = stream.read(MAX_INPUT_BYTES + 1)
    if len(payload) > MAX_INPUT_BYTES:
        raise ShellContractError("input exceeds bounded parser limit")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ShellContractError("input is not UTF-8") from error


def require_root_owned_contract(path: Path) -> None:
    if not path.is_absolute() or ".." in path.parts:
        raise ShellContractError("root-owned contract path must be absolute and normalized")
    current = Path(path.anchor)
    for index, part in enumerate(path.parts[1:]):
        current /= part
        value = current.lstat()
        final = index == len(path.parts[1:]) - 1
        if value.st_uid != 0 or value.st_gid != 0 or stat.S_IMODE(value.st_mode) & 0o022:
            raise ShellContractError("root-owned contract ancestry is writable or unowned")
        if final:
            if not stat.S_ISREG(value.st_mode) or stat.S_IMODE(value.st_mode) != 0o644:
                raise ShellContractError("root-owned contract leaf identity is invalid")
        elif not stat.S_ISDIR(value.st_mode):
            raise ShellContractError("root-owned contract ancestry is not a directory")


def ubuntu_package_sequence(contract: dict[str, object], consumer: str) -> list[str]:
    """Derive one named concrete package sequence from the JSON authority."""
    packages = contract["ubuntu_apt_packages"]
    if not isinstance(packages, dict):
        raise ShellContractError("ubuntu_apt_packages must be an object")
    baseline = packages.get("baseline")
    desktop_build = packages.get("desktop_build")
    apps = packages.get("desktop_apps")
    if not isinstance(baseline, list) or not isinstance(desktop_build, list) or not isinstance(apps, list):
        raise ShellContractError("Ubuntu package groups must be arrays")
    if any(not isinstance(value, str) or not value for value in [*baseline, *desktop_build]):
        raise ShellContractError("Ubuntu package names must be non-empty strings")
    if len(set(baseline)) != len(baseline) or len(set(desktop_build)) != len(desktop_build):
        raise ShellContractError("Ubuntu package groups contain duplicates")
    chrome = [item.get("name") for item in apps if isinstance(item, dict) and item.get("name") == "google-chrome-stable"]
    if chrome != ["google-chrome-stable"]:
        raise ShellContractError("Chrome package identity is missing or duplicated")
    transformations = {
        "ubuntu-install-source-baseline": list(baseline),
        "ubuntu-desktop-build": list(desktop_build),
        "ubuntu-desktop-system": [*baseline, *desktop_build],
        "ubuntu-desktop-gui-addon": ["fonts-jetbrains-mono", chrome[0]],
    }
    try:
        result = transformations[consumer]
    except KeyError as error:
        raise ShellContractError("unknown Ubuntu package consumer") from error
    if len(set(result)) != len(result):
        raise ShellContractError("derived Ubuntu consumer sequence contains duplicates")
    return result


def _chrome_source_contract(contract: dict[str, object]) -> tuple[dict[str, object], set[tuple[str, str, str]]]:
    packages = contract.get("ubuntu_apt_packages")
    if not isinstance(packages, dict) or not isinstance(packages.get("desktop_apps"), list):
        raise ShellContractError("Ubuntu desktop application contract is malformed")
    matches = [
        item for item in packages["desktop_apps"]
        if isinstance(item, dict) and item.get("name") == "google-chrome-stable"
    ]
    if len(matches) != 1 or not isinstance(matches[0].get("apt_source"), dict):
        raise ShellContractError("Chrome apt source authority is missing or duplicated")
    source = matches[0]["apt_source"]
    identities = source.get("accepted_source_identities")
    if not isinstance(identities, list) or not identities:
        raise ShellContractError("Chrome accepted source identities are missing")
    normalized: set[tuple[str, str, str]] = set()
    for identity in identities:
        if not isinstance(identity, dict) or set(identity) != {"scheme", "host", "path"}:
            raise ShellContractError("Chrome source identity shape is invalid")
        scheme, host, path = identity["scheme"], identity["host"], identity["path"]
        if (
            scheme != "https" or host != "dl.google.com" or not isinstance(path, str)
            or not path.startswith("/") or path.endswith("/") or "//" in path
        ):
            raise ShellContractError("Chrome source identity is not normalized")
        value = (scheme, host, path)
        if value in normalized:
            raise ShellContractError("Chrome source identity is duplicated")
        normalized.add(value)
    canonical = urlsplit(source.get("uri", ""))
    if (
        canonical.username is not None or canonical.password is not None or canonical.port is not None
        or canonical.query or canonical.fragment
        or (canonical.scheme, canonical.hostname, canonical.path.rstrip("/")) not in normalized
    ):
        raise ShellContractError("Chrome canonical URI is outside accepted identities")
    fingerprint = re.sub(r"[^0-9A-Fa-f]", "", str(source.get("key_fingerprint", ""))).upper()
    if not re.fullmatch(r"[0-9A-F]{40}", fingerprint):
        raise ShellContractError("Chrome signing fingerprint is malformed")
    for field in ("suites", "components", "architectures", "managed_keyring"):
        if not isinstance(source.get(field), str) or not source[field]:
            raise ShellContractError(f"Chrome {field} authority is malformed")
    return source, normalized


def _normalized_uri(value: str) -> tuple[str, str, str] | None:
    parsed = urlsplit(value)
    if (
        parsed.username is not None or parsed.password is not None or parsed.port is not None
        or parsed.query or parsed.fragment or parsed.scheme != parsed.scheme.lower()
        or parsed.hostname is None or parsed.netloc != parsed.hostname
    ):
        return None
    path = parsed.path.rstrip("/")
    if not path or "//" in path or "/./" in path or "/../" in path:
        return None
    return parsed.scheme, parsed.hostname, path


def _one_line_sources(text: str) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for number, line in enumerate(text.splitlines(), 1):
        try:
            tokens = shlex.split(line, comments=True, posix=True)
        except ValueError as error:
            raise ShellContractError(f"malformed apt source line {number}") from error
        if not tokens or tokens[0] not in {"deb", "deb-src"}:
            continue
        source_type = tokens.pop(0)
        options: dict[str, str] = {}
        if tokens and tokens[0].startswith("["):
            option_tokens: list[str] = []
            while tokens:
                token = tokens.pop(0)
                option_tokens.append(token)
                if token.endswith("]"):
                    break
            if not option_tokens[-1].endswith("]"):
                raise ShellContractError(f"unclosed apt options at line {number}")
            option_text = " ".join(option_tokens)[1:-1].strip()
            for option in option_text.split():
                if "=" not in option:
                    raise ShellContractError(f"malformed apt option at line {number}")
                key, value = option.split("=", 1)
                if key in options or not key or not value:
                    raise ShellContractError(f"duplicate or empty apt option at line {number}")
                options[key.lower()] = value
        if len(tokens) < 3:
            raise ShellContractError(f"incomplete apt source at line {number}")
        result.append({
            "type": source_type, "uri": tokens[0], "suites": [tokens[1]],
            "components": tokens[2:], "architectures": options.get("arch", "").split(","),
            "signed_by": options.get("signed-by", ""),
        })
    return result


def _deb822_sources(text: str) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for paragraph in re.split(r"\n[ \t]*\n", text):
        fields: dict[str, str] = {}
        current: str | None = None
        for line in paragraph.splitlines():
            if not line or line.lstrip().startswith("#"):
                continue
            if line[:1].isspace():
                if current is None:
                    raise ShellContractError("orphan deb822 continuation")
                fields[current] += " " + line.strip()
                continue
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            key = key.strip().lower()
            if key in fields or not key or not value.strip():
                raise ShellContractError("duplicate or empty deb822 field")
            fields[key] = value.strip()
            current = key
        if "uris" not in fields:
            continue
        for uri in fields["uris"].split():
            result.append({
                "type": "deb" if "deb" in fields.get("types", "").split() else "other",
                "uri": uri, "suites": fields.get("suites", "").split(),
                "components": fields.get("components", "").split(),
                "architectures": fields.get("architectures", "").split(),
                "signed_by": fields.get("signed-by", ""),
            })
    return result


def chrome_runtime_contract(contract: dict[str, object], paths: list[Path]) -> dict[str, object]:
    source, identities = _chrome_source_contract(contract)
    files: list[Path] = []
    for path in paths:
        if path.is_symlink():
            raise ShellContractError("apt source input must not be a symlink")
        if path.is_dir():
            entries = sorted(path.iterdir())
            if len(entries) > MAX_SOURCE_FILES:
                raise ShellContractError("apt source directory exceeds bounded file count")
            if any(entry.is_symlink() for entry in entries):
                raise ShellContractError("apt source directory contains a symlink")
            files.extend(entry for entry in entries if entry.is_file())
        elif path.is_file():
            files.append(path)
    if len(files) > MAX_SOURCE_FILES:
        raise ShellContractError("apt source inputs exceed bounded file count")
    matches: set[tuple[str, str, str]] = set()
    suspicious = False
    for path in files:
        text = _read_bounded(path)
        records = _one_line_sources(text) + _deb822_sources(text)
        for record in records:
            raw_uri = str(record["uri"])
            identity = _normalized_uri(raw_uri)
            parsed = urlsplit(raw_uri)
            chrome_like = "chrome" in (parsed.hostname or "").lower() or "chrome" in parsed.path.lower()
            if identity not in identities:
                suspicious = suspicious or chrome_like
                continue
            valid = (
                record["type"] == "deb"
                and source["suites"] in record["suites"]
                and source["components"] in record["components"]
                and source["architectures"] in record["architectures"]
                and record["signed_by"] == source["managed_keyring"]
            )
            if not valid:
                suspicious = True
                continue
            matches.add(identity)
    if suspicious or not matches:
        raise ShellContractError("Chrome apt source identity or binding is invalid")
    fingerprint = re.sub(r"[^0-9A-Fa-f]", "", str(source["key_fingerprint"])).upper()
    return {"fingerprint": fingerprint, "matched_identities": [list(value) for value in sorted(matches)]}


def _emit(operation: str, result: object) -> None:
    if isinstance(result, list) and len(result) > MAX_RESULT_ITEMS:
        raise ShellContractError("result exceeds bounded item limit")
    print(json.dumps(
        {"schema": SCHEMA, "operation": operation, "result": result},
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="shell_contract.py")
    commands = parser.add_subparsers(dest="operation", required=True)
    array = commands.add_parser("array")
    array.add_argument("--path", required=True, type=Path)
    array.add_argument("--name", required=True)
    surfaces = commands.add_parser("python-surfaces")
    surfaces.add_argument("--root", required=True, type=Path)
    surfaces.add_argument("--path", required=True, action="append", type=Path)
    packages = commands.add_parser("ubuntu-packages")
    packages.add_argument("--contract", required=True, type=Path)
    packages.add_argument("--consumer", required=True)
    chrome = commands.add_parser("chrome-runtime")
    chrome.add_argument("--contract", required=True, type=Path)
    chrome.add_argument("--source", required=True, action="append", type=Path)
    chrome.add_argument("--require-root-owned-contract", action="store_true")
    try:
        args = parser.parse_args(argv)
        if args.operation == "array":
            result = parse_static_array(_read_bounded(args.path), args.name)
        elif args.operation == "python-surfaces":
            root = args.root.resolve(strict=True)
            result = []
            for path in args.path:
                resolved = path.resolve(strict=True)
                _read_bounded(resolved)
                result.extend(python_surfaces(resolved, root))
        elif args.operation == "ubuntu-packages":
            contract = json.loads(_read_bounded(args.contract))
            if not isinstance(contract, dict):
                raise ShellContractError("contract root must be an object")
            result = ubuntu_package_sequence(contract, args.consumer)
        else:
            if args.require_root_owned_contract:
                require_root_owned_contract(args.contract)
            contract = json.loads(_read_bounded(args.contract))
            if not isinstance(contract, dict):
                raise ShellContractError("contract root must be an object")
            result = chrome_runtime_contract(contract, args.source)
        _emit(args.operation, result)
        return 0
    except (OSError, ShellContractError, ValueError) as error:
        print(f"shell-contract: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
