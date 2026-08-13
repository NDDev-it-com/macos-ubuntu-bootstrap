#!/usr/bin/env python3
"""Resolve the contract-owned validation tools into a minimal trusted PATH."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import stat
import subprocess
from pathlib import Path


class ResolutionError(ValueError):
    pass


def _identity(path: Path) -> tuple[int, int, int, int, int]:
    value = path.stat()
    return (value.st_dev, value.st_ino, value.st_uid, value.st_gid, value.st_mode)


def _lidentity(path: Path) -> tuple[int, int, int, int, int]:
    value = path.lstat()
    return (value.st_dev, value.st_ino, value.st_uid, value.st_gid, value.st_mode)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(131072), b""):
            digest.update(block)
    return digest.hexdigest()


def _strict_resolve(path: Path, category: str) -> Path:
    try:
        return path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ResolutionError(f"{category} is missing, dangling, or has an invalid symlink chain") from error


def _system_trusted(path: Path) -> Path:
    resolved = _strict_resolve(path, "system executable")
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ResolutionError(f"required tool is not a regular executable: {path}")
    for candidate in (path.parent, *path.parent.parents, *resolved.parents, resolved):
        value = candidate.stat()
        if value.st_uid != 0 or stat.S_IMODE(value.st_mode) & 0o022:
            raise ResolutionError(f"required tool ancestry is untrusted: {path}")
    return resolved


def _bounded_relative(value: object, field: str) -> Path:
    if not isinstance(value, str):
        raise ResolutionError(f"managed-package {field} is invalid")
    path = Path(value)
    if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
        raise ResolutionError(f"managed-package {field} escapes its anchor")
    return path


def _run_version(executable: Path, argument: str) -> str:
    result = subprocess.run(
        [str(executable), argument], env={"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=10, check=False,
    )
    if result.returncode or len(result.stdout.encode()) > 16384:
        raise ResolutionError("managed-package executable version probe failed")
    return result.stdout


def _homebrew_trusted(path: Path, anchor: dict[str, object]) -> Path:
    prefix = Path(str(anchor["prefix"]))
    package = str(anchor["package"])
    version = str(anchor["version"])
    if path != prefix / "bin" / str(anchor["command"]):
        raise ResolutionError("Homebrew candidate does not use its declared alias")
    keg = prefix / "Cellar" / package / version
    receipt = keg / "INSTALL_RECEIPT.json"
    if not stat.S_ISDIR(keg.lstat().st_mode):
        raise ResolutionError("Homebrew versioned keg is not a directory")
    try:
        receipt_data = json.loads(receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ResolutionError("Homebrew receipt is unavailable or malformed") from error
    if not stat.S_ISREG(receipt.lstat().st_mode):
        raise ResolutionError("Homebrew receipt is not a regular file")
    source = receipt_data.get("source", {})
    if (not receipt_data.get("poured_from_bottle") or source.get("tap") != "homebrew/core"
            or source.get("versions", {}).get("stable") != version
            or receipt_data.get("arch") != anchor["architecture"]):
        raise ResolutionError("Homebrew receipt identity/version mismatch")
    expected = keg / _bounded_relative(anchor["executable"], "executable")
    try:
        alias_target = os.readlink(path)
    except OSError as error:
        raise ResolutionError("Homebrew command alias is not a symlink") from error
    declared_target = os.path.relpath(expected, path.parent)
    if alias_target != declared_target:
        raise ResolutionError("Homebrew alias target does not match the declared keg")
    resolved = _strict_resolve(path, "Homebrew alias target")
    if (resolved != expected or not stat.S_ISREG(expected.lstat().st_mode)
            or not os.access(resolved, os.X_OK)):
        raise ResolutionError("Homebrew alias escaped or executable is invalid")
    variants = anchor["provenance_variants"]
    accepted_hashes = {item["executable_sha256"] for item in variants}  # type: ignore[union-attr,index]
    if _sha256(expected) not in accepted_hashes:
        raise ResolutionError("Homebrew executable hash mismatch")
    # The global namespace may be package-manager writable. Inside the selected
    # keg, mixed ownership and group/world-writable content are forbidden.
    owner = keg.stat().st_uid
    current = keg
    identities: list[tuple[Path, tuple[int, int, int, int, int]]] = []
    for part in expected.relative_to(keg).parts:
        identities.append((current, _identity(current)))
        current = current / part
    identities.extend(((receipt, _identity(receipt)), (expected, _identity(expected))))
    for component, identity in identities:
        value = component.stat()
        if value.st_uid != owner or stat.S_IMODE(value.st_mode) & 0o022:
            raise ResolutionError("Homebrew versioned keg is writable or has mixed ownership")
        if _identity(component) != identity:
            raise ResolutionError("Homebrew identity changed during validation")
    receipt_identity = _identity(receipt)
    alias_identity = _lidentity(path)
    output = _run_version(expected, str(anchor["version_argument"]))
    if str(anchor["version_pattern"]) not in output:
        raise ResolutionError("Homebrew executable version mismatch")
    if receipt_identity != _identity(receipt) or alias_identity != _lidentity(path):
        raise ResolutionError("Homebrew alias or receipt changed during validation")
    for component, identity in identities:
        if _identity(component) != identity:
            raise ResolutionError("Homebrew identity changed during validation")
    return resolved


def _bundle_trusted(path: Path, anchor: dict[str, object]) -> Path:
    root_text = str(anchor["root"])
    if not root_text.startswith("$HOME/"):
        raise ResolutionError("bundle root is not anchored to HOME")
    root = Path.home() / root_text.removeprefix("$HOME/")
    receipt = root / _bounded_relative(anchor["receipt"], "receipt")
    expected = root / _bounded_relative(anchor["executable"], "executable")
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise ResolutionError("bundle root is not a directory")
    if path != expected or _strict_resolve(path, "bundle executable") != expected:
        raise ResolutionError("bundle executable escaped its declared root")
    if not stat.S_ISREG(receipt.lstat().st_mode) or not stat.S_ISREG(expected.lstat().st_mode):
        raise ResolutionError("bundle receipt or executable type is invalid")
    if _sha256(receipt) != anchor["receipt_sha256"] or _sha256(expected) != anchor["executable_sha256"]:
        raise ResolutionError("bundle receipt or executable hash mismatch")
    data = json.loads(receipt.read_text(encoding="utf-8"))
    if data.get("name") != anchor["package"] or data.get("version") != anchor["version"]:
        raise ResolutionError("bundle package identity/version mismatch")
    if not expected.is_file() or not os.access(expected, os.X_OK):
        raise ResolutionError("bundle executable is invalid")
    owner = root.stat().st_uid
    identities: list[tuple[Path, tuple[int, int, int, int, int]]] = []
    current = root
    for part in expected.relative_to(root).parts:
        identities.append((current, _identity(current)))
        current = current / part
    identities.extend(((receipt, _identity(receipt)), (expected, _identity(expected))))
    for component, identity in identities:
        value = component.stat()
        if value.st_uid != owner or stat.S_IMODE(value.st_mode) & 0o022:
            raise ResolutionError("bundle subtree is writable or has mixed ownership")
        if _identity(component) != identity:
            raise ResolutionError("bundle identity changed during validation")
    before = (_identity(receipt), _identity(expected))
    if str(anchor["version_pattern"]) not in _run_version(expected, str(anchor["version_argument"])):
        raise ResolutionError("bundle executable version mismatch")
    if before != (_identity(receipt), _identity(expected)):
        raise ResolutionError("bundle identity changed during validation")
    return expected


def _candidate(
    command: str, directories: list[Path], *, anchors: tuple[dict[str, object], ...] = (),
    ignored_shadows: tuple[Path, ...] = (),
) -> Path:
    matches: list[Path] = []
    for directory in directories:
        candidate = directory / command
        if candidate.exists() and os.access(candidate, os.X_OK):
            matches.append(candidate)
    if not matches:
        raise ResolutionError(f"missing required command: {command}")
    def validate(candidate: Path) -> Path:
        errors: list[str] = []
        try:
            return _system_trusted(candidate)
        except (OSError, ResolutionError) as error:
            errors.append(str(error))
        for anchor in anchors:
            try:
                if anchor["provider"] == "homebrew":
                    return _homebrew_trusted(candidate, anchor)
                if anchor["provider"] == "codex-bundle":
                    return _bundle_trusted(candidate, anchor)
            except (OSError, KeyError, TypeError, subprocess.SubprocessError, ResolutionError) as error:
                errors.append(str(error))
        raise ResolutionError(f"untrusted required command {command}: {'; '.join(errors)}")

    selected = validate(matches[0])
    for shadow in matches[1:]:
        if shadow.parent in ignored_shadows:
            continue
        try:
            shadow_resolved = _strict_resolve(shadow, "required-command shadow")
        except ResolutionError as error:
            raise ResolutionError(f"broken or looping shadow for required command: {command}") from error
        if shadow_resolved != selected:
            raise ResolutionError(f"duplicate or shadowed required command: {command}")
    return matches[0]


def _anchor_candidate(anchor: dict[str, object]) -> Path:
    provider = anchor.get("provider")
    if provider == "homebrew":
        return Path(str(anchor["prefix"])) / "bin" / str(anchor["command"])
    if provider == "codex-bundle":
        root = str(anchor["root"])
        if not root.startswith("$HOME/"):
            raise ResolutionError("bundle root is not anchored to HOME")
        return Path.home() / root.removeprefix("$HOME/") / _bounded_relative(
            anchor["executable"], "executable")
    raise ResolutionError("managed-package provider is unsupported")


def _managed_candidate(
    command: str, directories: list[Path], anchors: tuple[dict[str, object], ...],
) -> Path:
    if not anchors:
        raise ResolutionError(f"no managed-package provider declared for: {command}")
    declared_paths = [_anchor_candidate(anchor) for anchor in anchors]
    available = [(anchor, path) for anchor, path in zip(anchors, declared_paths)
                 if path.exists() or path.is_symlink()]
    if not available:
        raise ResolutionError(f"missing required command: {command}")
    anchor, selected = available[0]
    ambient_matches = [directory / command for directory in directories
                       if (directory / command).exists() or (directory / command).is_symlink()]
    if not ambient_matches or ambient_matches[0] != selected:
        raise ResolutionError(f"untrusted higher-precedence shadow for required command: {command}")
    allowed_declared = set(declared_paths)
    for shadow in ambient_matches[1:]:
        if shadow not in allowed_declared:
            raise ResolutionError(f"duplicate or shadowed required command: {command}")
    provider = anchor["provider"]
    if provider == "homebrew":
        _homebrew_trusted(selected, anchor)
    elif provider == "codex-bundle":
        _bundle_trusted(selected, anchor)
    else:
        raise ResolutionError("managed-package provider is unsupported")
    return selected


def _managed_anchors(data: dict[str, object], host_platform: str, host_arch: str) -> list[dict[str, object]]:
    raw = data["ci_validation"].get("managed_package_anchors", [])  # type: ignore[index]
    if not isinstance(raw, list):
        raise ResolutionError("managed-package anchor inventory is malformed")
    common = {"command", "provider", "platform", "architecture", "package", "version",
              "executable", "version_argument", "version_pattern"}
    provider_fields = {
        "homebrew": {"prefix", "provenance_variants"},
        "codex-bundle": {"root", "receipt", "receipt_sha256", "executable_sha256"},
    }
    seen: set[tuple[object, ...]] = set()
    result: list[dict[str, object]] = []
    for item in raw:
        if not isinstance(item, dict) or item.get("provider") not in provider_fields:
            raise ResolutionError("managed-package anchor is malformed")
        if set(item) != common | provider_fields[str(item["provider"])]:
            raise ResolutionError("managed-package anchor fields are malformed")
        identity = (item["command"], item["provider"], item["platform"], item["architecture"])
        if identity in seen:
            raise ResolutionError("managed-package anchor is duplicated")
        seen.add(identity)
        for field in ("command", "package", "version", "version_pattern"):
            if not isinstance(item[field], str) or not item[field]:
                raise ResolutionError(f"managed-package {field} is invalid")
        if item["version_argument"] != "--version":
            raise ResolutionError("managed-package version probe is not allowlisted")
        for field in ("receipt_sha256", "executable_sha256"):
            if field in item and (not isinstance(item[field], str) or len(item[field]) != 64
                                  or any(char not in "0123456789abcdef" for char in item[field])):
                raise ResolutionError(f"managed-package {field} is invalid")
        if item["provider"] == "homebrew":
            variants = item["provenance_variants"]
            required = {"formula_revision", "bottle_tag", "bottle_rebuild", "bottle_sha256", "executable_sha256"}
            if not isinstance(variants, list) or not variants:
                raise ResolutionError("managed-package provenance variants are invalid")
            variant_ids: set[tuple[object, ...]] = set()
            for variant in variants:
                if not isinstance(variant, dict) or set(variant) != required:
                    raise ResolutionError("managed-package provenance variant is malformed")
                if (not isinstance(variant["formula_revision"], str)
                        or len(variant["formula_revision"]) != 40
                        or any(char not in "0123456789abcdef" for char in variant["formula_revision"])):
                    raise ResolutionError("managed-package formula revision is invalid")
                if (not isinstance(variant["bottle_tag"], str) or not variant["bottle_tag"]
                        or not isinstance(variant["bottle_rebuild"], int)
                        or variant["bottle_rebuild"] < 0):
                    raise ResolutionError("managed-package bottle identity is invalid")
                for field in ("bottle_sha256", "executable_sha256"):
                    value = variant[field]
                    if (not isinstance(value, str) or len(value) != 64
                            or any(char not in "0123456789abcdef" for char in value)):
                        raise ResolutionError(f"managed-package {field} is invalid")
                variant_id = (variant["formula_revision"], variant["bottle_tag"], variant["bottle_rebuild"])
                if variant_id in variant_ids:
                    raise ResolutionError("managed-package provenance variant is duplicated")
                variant_ids.add(variant_id)
        _bounded_relative(item["executable"], "executable")
        if item["provider"] == "codex-bundle":
            _bounded_relative(item["receipt"], "receipt")
        if item["platform"] == host_platform and item["architecture"] == host_arch:
            result.append(item)
    return result


def resolve(contract: Path, ambient_path: str) -> str:
    data = json.loads(contract.read_text(encoding="utf-8"))
    entries = data["ci_validation"]["required_commands"]
    if not isinstance(entries, list) or not entries:
        raise ResolutionError("validation tool inventory is missing")
    ambient = [Path(value) for value in ambient_path.split(os.pathsep) if value]
    system = [Path("/usr/bin"), Path("/bin"), Path("/usr/sbin"), Path("/sbin")]
    selected: list[Path] = []
    names: set[str] = set()
    baseline = set(data["ubuntu_apt_packages"]["baseline"])
    host_platform = platform.system().lower()
    host_arch = {"aarch64": "arm64"}.get(platform.machine().lower(), platform.machine().lower())
    declared = _managed_anchors(data, host_platform, host_arch)
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"command", "source"}:
            raise ResolutionError("validation tool entry is malformed")
        command, source = entry["command"], entry["source"]
        if not isinstance(command, str) or command in names:
            raise ResolutionError("validation command is invalid or duplicated")
        names.add(command)
        if source == "os-base":
            path = _candidate(command, system)
        else:
            package = source.rsplit(":", 1)[-1] if ":" in source else command
            if package not in baseline:
                raise ResolutionError(f"validation package source is undeclared: {source}")
            if command == "python3":
                path = _candidate(command, [*system, *ambient], ignored_shadows=tuple(ambient))
            else:
                anchors = tuple(anchor for anchor in declared if anchor.get("command") == command
                                and anchor.get("platform") == host_platform
                                and anchor.get("architecture") == host_arch)
                path = (_managed_candidate(command, ambient, anchors)
                        if anchors else _candidate(command, ambient))
        if path.parent not in selected:
            selected.append(path.parent)
    return os.pathsep.join(str(path) for path in selected)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--ambient-path", required=True)
    args = parser.parse_args()
    try:
        print(resolve(args.contract, args.ambient_path))
    except (OSError, KeyError, json.JSONDecodeError, ResolutionError) as error:
        print(f"validation-path: {error}", file=__import__("sys").stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
