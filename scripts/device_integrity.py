#!/usr/bin/env python3
"""Build and verify the installed device runtime receipt against the contract.

A canonical-JSON receipt is built from a proven installed state, persisted
atomically, and verified by re-collecting the state and comparing exactly. It
extends the pattern to the *whole device* — not just the browser stack — by
also comparing every declared runtime version and pinned source tool against
``config/rldyour-contract.json``, closing the gap between the contract and the
hardcoded literals the bash installer writes.

Contract sources of truth:

- ``config/rldyour-contract.json`` — pinned versions + SHA-256 for node/uv/bun/
  go/rust/dart/gopls, pinned source tools, user tools (herdr), desktop entries,
  and the apt package manifest.
- per-runtime receipts under ``~/.local/share/rldyour/<runtime>/...`` written by
  ``ubuntu/install.sh`` (format ``ubuntu-runtime-v1``).

The receipt binds a device to its home directory and to the contract the
bootstrap was authored against. Any drift — a tampered binary, an unmanaged
symlink, a contract version that no longer matches what is installed — fails
closed with ``status: NOT_PROVEN``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, NoReturn

ROOT = Path(__file__).resolve().parents[1]
OWNER = "macos-ubuntu-bootstrap"
SCHEMA = "rldyour-device-receipt-v1"
BOOTSTRAP_VERSION = "1.0.0"
CONTRACT_PATH = ROOT / "config/rldyour-contract.json"
DEFAULT_RECEIPT = Path.home() / ".local/share/rldyour/device-receipt.json"

# Runtime hosts declared in the contract under runtime_support, mapped to the
# command that reports their version and the contract field that pins it. Each
# entry drives one version comparison during verify.
#
# The contract fields are named `ubuntu_*` because only Ubuntu installs these
# from an exact tracked artifact. macOS installs them through Homebrew, which
# resolves current metadata and preserves an already installed formula, so a
# macOS host legitimately carries a different patch version. Comparing a macOS
# device against `ubuntu_uv` reports drift that is not drift, so the version
# comparison is Linux-only and macOS records the observation without asserting
# it. Whether macOS should pin exactly is a contract decision, tracked in #63;
# until it is made, this tool must not invent an answer.
RUNTIME_HOSTS: dict[str, tuple[str, str]] = {
    # name: (version_flag, contract_field under runtime_support)
    "node": ("--version", "ubuntu_node_lts"),
    "uv": ("--version", "ubuntu_uv"),
    "bun": ("--version", "ubuntu_bun"),
    "go": ("version", "ubuntu_go"),
    "gopls": ("version", "ubuntu_gopls"),
    "rustc": ("--version", "ubuntu_rust"),
    "dart": ("--version", "ubuntu_dart"),
}

# The contract pins exact artifacts for these platforms only. On any other
# platform the runtime versions and pinned source tools are observed and
# recorded, never asserted.
EXACT_VERSION_PLATFORMS = ("linux",)

# Pinned source tools (contract: runtime_support.ubuntu_pinned_source_tools).
# Each is installed as a managed binary under ~/.local/bin/<name>.
PINNED_SOURCE_TOOLS_CONTRACT = "ubuntu_pinned_source_tools"

# The device profiles the receipt understands. These mirror the contract's
# targets block and scripts/bootstrap.sh.
VALID_PROFILES = ("desktop", "desktop-builds", "server")

class IntegrityError(RuntimeError):
    """A device runtime invariant was not proven."""


# ----------------------------- hashing primitives -----------------------------


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_bytes(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def fail(message: str) -> NoReturn:
    raise IntegrityError(message)


def _current_os() -> str:
    """Return the normalized OS label matching the contract's ``os`` arrays."""
    system = os.uname().sysname
    if system == "Darwin":
        return "macos"
    if system == "Linux":
        return "linux"
    return system.lower()


def _applies_to_current_os(spec: dict[str, Any]) -> bool:
    """Check whether a contract entry's ``os`` array includes this platform.

    Entries without an ``os`` field apply to all platforms (backward
    compatibility). Entries with ``os: ["linux"]`` are skipped on macOS, so a
    Linux-only tool does not cause a NOT_PROVEN where it is never installed.
    """
    declared_oses = spec.get("os")
    if not declared_oses:
        return True
    # Normalize: "ubuntu" in the contract means Linux (the bootstrap's only
    # Linux target); "linux" is the uname label.
    current = _current_os()
    normalized = {current, "linux" if current == "linux" else current}
    for entry_os in declared_oses:
        if entry_os in normalized or (entry_os == "ubuntu" and current == "linux"):
            return True
    return False


def _resolve_build_profile(explicit: str | None) -> str:
    """Resolve the device profile a ``build`` records into the receipt.

    Precedence: an explicit ``--profile``, then ``RLDYOUR_PROFILE``, then the
    execution policy the installer exports (``RLDYOUR_LOCAL_EXECUTION_POLICY``).
    When none is set we fall back to ``desktop`` — the strict superset that
    verifies every runtime host and tool. That default is fail-closed: a server
    receipt built without a profile is over-verified into a loud NOT_PROVEN, not
    silently under-verified into a false PROVEN. There is currently no automated
    caller; every invocation should pass ``--profile`` explicitly.
    """
    if explicit:
        if explicit not in VALID_PROFILES:
            fail(f"unknown profile {explicit!r}; expected one of {', '.join(VALID_PROFILES)}")
        return explicit
    env_profile = os.environ.get("RLDYOUR_PROFILE", "").strip()
    if env_profile in VALID_PROFILES:
        return env_profile
    policy_map = {
        "source-lsp-only": "desktop",
        "local-dev-with-builds": "desktop-builds",
        "container-execution-only": "server",
    }
    policy = os.environ.get("RLDYOUR_LOCAL_EXECUTION_POLICY", "").strip()
    return policy_map.get(policy, "desktop")


# ----------------------------- safety primitives -----------------------------


def regular_owned(
    path: Path,
    *,
    executable: bool = False,
    enforce_private_mode: bool = True,
    enforce_owner: bool = True,
) -> os.stat_result:
    """Assert a path is a regular, non-symlink, owner-held file.

    ``enforce_private_mode`` additionally refuses a group- or world-writable
    file. That is genuine tamper resistance for a file the installer created
    and owns. It is meaningless for a Git-tracked repository source (Git records
    only the executable bit), so callers reading repository sources pass False.

    ``enforce_owner`` is likewise about device files rather than repository
    sources. For a file the installer wrote under ``$HOME``, current-UID
    ownership is a real property: anyone else owning it means something outside
    this repository wrote it. For a repository *source* it is neither necessary
    nor sufficient. Not necessary, because staging the repository read-only as
    root and applying it as an unprivileged user is a legitimate shape -- it is
    what the hosted native evidence lanes do, and it is safer than the
    alternative. Not sufficient, because the first path checked is
    ``device_integrity.py`` itself: anyone who owns that file controls the check,
    so the check cannot defend against them. What actually pins a repository
    source into the receipt is its content hash, which is recorded either way.
    """
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"required path is missing: {path}")
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        fail(f"path must be a regular non-symlink file: {path}")
    if enforce_owner and metadata.st_uid != os.getuid():
        fail(f"path is not owned by the current UID: {path}")
    if enforce_private_mode and metadata.st_mode & 0o022:
        fail(f"path is group/world-writable: {path}")
    if executable and not metadata.st_mode & stat.S_IXUSR:
        fail(f"path is not owner-executable: {path}")
    return metadata


def safe_directory(path: Path, *, enforce_private_mode: bool = True) -> None:
    """Assert a path is a non-symlink directory owned by the current UID.

    ``enforce_private_mode`` additionally refuses a group- or world-writable
    directory. Container directories under ``~/.local/share/rldyour`` are
    routinely ``775`` because the device's umask is ``0002``; the managed
    managed runtime trees inside them are ``700``. We refuse a
    symlink or foreign-owned directory unconditionally, but follow the same
    private-mode opt-out the Git-source hashes use for containers.
    """
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"required directory is missing: {path}")
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        fail(f"path must be a non-symlink directory: {path}")
    if metadata.st_uid != os.getuid():
        fail(f"directory is not owned by the current UID: {path}")
    if enforce_private_mode and metadata.st_mode & 0o022:
        fail(f"directory is group/world-writable: {path}")


def ensure_under(path: Path, root: Path, label: str) -> None:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (FileNotFoundError, ValueError):
        fail(f"{label} escaped its managed namespace: {path}")


# ----------------------------- contract access -----------------------------


def load_contract() -> dict[str, Any]:
    # The contract is a repository source, so neither the private-mode nor the
    # owner check applies: see regular_owned's docstring. Its content is pinned
    # into the receipt by policy_hashes.
    regular_owned(CONTRACT_PATH, enforce_private_mode=False, enforce_owner=False)
    try:
        return json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError("device contract is unreadable") from exc


def policy_hashes() -> dict[str, str]:
    """Hash every policy/contract/source file that should pin the receipt.

    Changing any of these — the contract, the integrity script itself, the
    installer library, or the desktop template — invalidates the receipt so a
    stale receipt cannot vouch for a newer contract.
    """
    paths = {
        "integrity_policy": Path(__file__).resolve(),
        "installer_policy": ROOT / "scripts/lib/common.sh",
        "ubuntu_installer": ROOT / "scripts/ubuntu/install.sh",
        "contract": CONTRACT_PATH,
    }
    desktop_dir = ROOT / "templates/desktop"
    if desktop_dir.is_dir():
        for entry in sorted(desktop_dir.iterdir()):
            if entry.is_file() and entry.suffix == ".desktop":
                paths[f"desktop_{entry.stem}"] = entry
    for path in paths.values():
        # Repository sources, not device files: see regular_owned's docstring for
        # why neither the private-mode nor the owner check applies here. The
        # content hash below is what pins them into the receipt.
        regular_owned(path, enforce_private_mode=False, enforce_owner=False)
    return {name: sha256_file(path) for name, path in paths.items()}


# ----------------------------- state collection -----------------------------


def _run_version(binary: Path, flag: str) -> str:
    """Run ``<binary> <flag>`` in a scrubbed environment and return stdout.

    Strips PYTHONPATH/PYTHONHOME, captures output, applies a timeout, and
    chain-raises on failure.
    """
    if not binary.exists():
        return "absent"
    env = os.environ.copy()
    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    try:
        result = subprocess.run(
            [str(binary), flag],
            check=False,
            capture_output=True,
            text=True,
            env=env,
            timeout=15,
        )
    except subprocess.TimeoutExpired:
        return f"error:version probe timed out for {binary.name}"
    except OSError as exc:
        raise IntegrityError(f"version probe failed for {binary.name}") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        return f"error:{detail or 'no detail'}"
    # Some runtimes print their version to stderr (notably `dart --version`
    # on all platforms, and `go version` on some setups). Merge both streams
    # so the version token is captured regardless of which stream the tool
    # chose — mirroring the `2>&1` pattern the bash installer uses.
    return (result.stdout + result.stderr).strip()


def _normalize_version(raw: str, name: str) -> str:
    """Reduce a version string to the comparable token.

    Each runtime emits its version differently (``v24.19.0``, ``uv 0.12.4``,
    ``go version go1.26.6 linux/amd64``, ``rustc 1.97.1 (...)``). Pull the first
    ``X.Y.Z`` token so the comparison is against the contract's bare semver.
    """
    match = re.search(r"\d+\.\d+\.\d+", raw)
    if not match:
        return raw
    return match.group(0)


def _runtime_versions(bin_dir: Path) -> dict[str, dict[str, str]]:
    """Collect installed versions of every declared runtime host."""
    versions: dict[str, dict[str, str]] = {}
    for name, (flag, _contract_field) in RUNTIME_HOSTS.items():
        binary = shutil.which(name) or str(bin_dir / name)
        raw = _run_version(Path(binary), flag)
        versions[name] = {
            "raw": raw,
            "normalized": _normalize_version(raw, name),
            "path": binary,
        }
    return versions


def _pinned_source_tool_versions(bin_dir: Path) -> dict[str, str]:
    """Collect installed versions of pinned source tools via ``<name> --version``."""
    contract = load_contract()
    declared = contract.get("runtime_support", {}).get(PINNED_SOURCE_TOOLS_CONTRACT, {})
    versions: dict[str, str] = {}
    for name in declared:
        binary = shutil.which(name) or str(bin_dir / name)
        raw = _run_version(Path(binary), "--version")
        versions[name] = _normalize_version(raw, name)
    return versions


def _expand_home_path(value: str, home: Path) -> Path:
    """Expand the contract's explicit ``${HOME}`` placeholder."""
    return Path(value.replace("${HOME}", str(home), 1))


def _user_tool_state(bin_dir: Path, home: Path) -> dict[str, dict[str, Any]]:
    """Collect installed user tools (herdr, telegram) declared in the contract."""
    contract = load_contract()
    declared = contract.get("user_tools", {})
    state: dict[str, dict[str, Any]] = {}
    for name, spec in declared.items():
        if not _applies_to_current_os(spec):
            continue
        # Resolve the on-disk binary name: the contract's bin_target basename
        # is authoritative (e.g. "telegram" user_tool publishes "telegram-desktop").
        bin_target = spec.get("bin_target", "")
        bin_name = Path(bin_target).name if bin_target else name
        binary = shutil.which(bin_name) or str(bin_dir / bin_name)
        path = Path(binary)
        # GUI programs such as Telegram do not implement --version: invoking it
        # starts the full Qt application, can hang without a compatible display,
        # and mutates desktop-session state. The contract must opt those tools
        # into a non-executing presence probe; their version/provenance is
        # already bound by the install receipt and archive SHA-256.
        if spec.get("version_probe") == "presence-only":
            raw = "presence-only" if path.exists() or path.is_symlink() else "absent"
        else:
            raw = _run_version(path, "--version")
        if (
            spec.get("version_probe") == "presence-only"
            or not raw
            or raw.startswith("error:")
            or raw == "absent"
        ):
            if path.exists() or path.is_symlink():
                normalized = spec.get("version", "unknown")
            else:
                normalized = "absent"
        else:
            normalized = _normalize_version(raw, name)
        entry: dict[str, Any] = {
            "declared_version": spec.get("version", "unknown"),
            "installed_version": normalized,
            "raw": raw,
            "path": binary,
        }
        path = Path(binary)
        if path.exists() or path.is_symlink():
            try:
                resolved = path.resolve(strict=True)
            except (FileNotFoundError, RuntimeError):
                resolved = path
            if resolved.is_file() and not resolved.is_symlink():
                entry["resolved"] = str(resolved)
                entry["sha256"] = sha256_file(resolved)

        policy_target = spec.get("external_updater_policy_target")
        policy_marker = spec.get("external_updater_policy_marker")
        if isinstance(policy_target, str) and isinstance(policy_marker, str):
            policy = _expand_home_path(policy_target, home)
            launcher = _expand_home_path(spec["bin_target"], home)
            resolved = launcher.resolve(strict=False)
            expected_lines = [policy_marker, str(launcher), str(resolved)]
            regular = policy.is_file() and not policy.is_symlink()
            lines: list[str] = []
            if regular:
                try:
                    lines = policy.read_text(encoding="utf-8").splitlines()
                    entry["external_updater_policy_sha256"] = sha256_file(policy)
                except OSError:
                    regular = False
            entry["external_updater_policy_path"] = str(policy)
            entry["external_updater_policy_valid"] = regular and lines == expected_lines
        state[name] = entry
    return state


def _owned_prefix(spec: dict[str, Any], home: Path) -> Path | None:
    """Resolve the directory a harness's declared owner publishes into."""
    default = spec.get("owned_prefix_default")
    if not isinstance(default, str):
        return None
    override = os.environ.get(spec.get("owned_prefix_env", ""), "").strip()
    raw = override or default
    return _expand_home_path(raw, home).resolve(strict=False)


def _harness_state(home: Path) -> dict[str, dict[str, Any]]:
    """Record where each catalogued harness resolves on this device.

    ``one-owner-per-harness`` was prose only. Nothing on a device could say
    whether ``codex`` resolved to the target its own installer publishes or to a
    second copy from a package-manager global. This records the observed facts;
    the contract, not the receipt, decides what they mean.

    ``harnesses.detection`` in the contract drives this. Each entry names the
    command, the prefix its owner publishes into, and whether that prefix is
    enforced. Only harnesses this repository installs itself carry
    ``enforcement: owned-prefix``; the two whose vendor installer picks its own
    target are observed and recorded, never failed on.
    """
    contract = load_contract()
    detection = contract.get("harnesses", {}).get("detection", {})
    state: dict[str, dict[str, Any]] = {}
    for name, spec in detection.items():
        if name.startswith("_") or not isinstance(spec, dict):
            continue
        command = spec.get("command", name)
        found = shutil.which(command)
        entry: dict[str, Any] = {"present": str(bool(found))}
        if found:
            resolved = Path(found).resolve(strict=False)
            entry["path"] = found
            entry["resolved"] = str(resolved)
            prefix = _owned_prefix(spec, home)
            if prefix is not None:
                entry["owned_prefix"] = str(prefix)
                entry["inside_owned_prefix"] = str(
                    resolved == prefix or prefix in resolved.parents
                )
        state[name] = entry
    return state


def _verify_harness_ownership(state: dict[str, Any]) -> list[str]:
    """Return one drift line per harness that resolves outside its owner."""
    contract = load_contract()
    detection = contract.get("harnesses", {}).get("detection", {})
    observed = state.get("harnesses", {})
    drifts: list[str] = []
    for name, spec in detection.items():
        if name.startswith("_") or not isinstance(spec, dict):
            continue
        if spec.get("enforcement") != "owned-prefix":
            # observe-only: a delegated on-pause harness is recorded, never
            # acted on. Presence is evidence, not a failure.
            continue
        entry = observed.get(name, {})
        if entry.get("present") != "True":
            continue
        if entry.get("inside_owned_prefix") != "True":
            drifts.append(
                f"{name}: resolves to {entry.get('resolved')} outside its owner's "
                f"target {entry.get('owned_prefix')}"
            )
    return drifts


def _desktop_entry_state(home: Path) -> dict[str, dict[str, Any]]:
    """Collect each declared desktop entry and its pinned icon assets."""
    contract = load_contract()
    declared = contract.get("desktop_entries", {})
    state: dict[str, dict[str, Any]] = {}
    for name, spec in declared.items():
        if not _applies_to_current_os(spec):
            continue
        target = _expand_home_path(spec["target"], home)
        entry: dict[str, Any] = {
            "path": str(target),
            "present": str(target.exists() and not target.is_symlink()),
        }
        if target.exists() and target.is_file() and not target.is_symlink():
            entry["sha256"] = sha256_file(target)
        assets: dict[str, dict[str, str]] = {}
        for asset_spec in spec.get("icon_assets", []):
            asset = _expand_home_path(asset_spec["target"], home)
            asset_entry = {
                "present": str(asset.exists() and not asset.is_symlink())
            }
            if asset.exists() and asset.is_file() and not asset.is_symlink():
                asset_entry["sha256"] = sha256_file(asset)
            assets[str(asset)] = asset_entry
        if assets:
            entry["icon_assets"] = assets
        state[name] = entry
    return state


def collect_state(*, home: Path, profile: str) -> dict[str, Any]:
    """Build the full device state dict from the live machine.

    ``profile`` is recorded so verify requires exactly the tool set the profile
    provisions. Collection itself is profile-independent — a host absent by
    design still reads as ``absent`` symmetrically at build and verify time — so
    only the contract-version gate consults the profile.
    """
    if profile not in VALID_PROFILES:
        fail(f"device profile is invalid: {profile!r}")
    bin_dir = home / ".local/bin"
    share_rldyour = home / ".local/share/rldyour"
    applications_dir = home / ".local/share/applications"

    # On a fresh machine before bootstrap, ~/.local/bin may not exist yet.
    # safe_directory would treat that as a missing required path and fail;
    # tolerate absence so build can snapshot an all-absent device.
    if bin_dir.exists():
        safe_directory(bin_dir, enforce_private_mode=False)
    if share_rldyour.exists():
        safe_directory(share_rldyour, enforce_private_mode=False)
    if applications_dir.exists():
        safe_directory(applications_dir, enforce_private_mode=False)

    return {
        "schema": SCHEMA,
        "owner": OWNER,
        "bootstrap_version": BOOTSTRAP_VERSION,
        "profile": profile,
        "home": str(home),
        "platform": f"{os.uname().sysname}-{os.uname().machine}",
        "policy_hashes": policy_hashes(),
        "runtime_hosts": _runtime_versions(bin_dir),
        "pinned_source_tools": _pinned_source_tool_versions(bin_dir),
        "user_tools": _user_tool_state(bin_dir, home),
        "desktop_entries": _desktop_entry_state(home),
        "harnesses": _harness_state(home),
    }


# ----------------------------- receipt integrity -----------------------------


def payload_with_integrity(state: dict[str, Any]) -> dict[str, Any]:
    result = dict(state)
    result["payload_sha256"] = sha256_bytes(canonical_bytes(state))
    return result


def write_file_atomically(path: Path, payload: bytes, *, mode: int = 0o600) -> None:
    """Publish bytes so the destination is never absent, partial, or stale.

    A temporary file in the same directory is written, flushed and fsynced,
    then renamed over the destination; the parent directory is fsynced so the
    rename survives a crash. Any failure before the rename leaves the previous
    destination byte-for-byte intact — which is the property a backup-first
    replacement cannot offer, because it vacates the active path first.
    """
    parent = path.parent
    descriptor, temporary_name = tempfile.mkstemp(
        dir=parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    directory = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def retain_rejected_receipt(path: Path) -> Path:
    """Copy an unverifiable receipt aside without vacating the active path.

    Mirrors how the browser layer keeps a rejected managed tree outside the
    active namespace: a receipt that fails self-integrity is evidence, so it is
    preserved under its own name rather than deleted or silently overwritten.
    """
    data = path.read_bytes()
    for index in range(1, 100):
        candidate = path.with_name(f"{path.name}.rejected.{index}")
        if not candidate.exists():
            write_file_atomically(candidate, data)
            return candidate
    fail(f"too many retained rejected receipts beside {path}; clean them up first")


def load_receipt(path: Path, *, metadata_only: bool = False) -> dict[str, Any]:
    regular_owned(path)
    try:
        raw = path.read_bytes()
        data = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError(f"device receipt is invalid JSON: {path}") from exc
    if not isinstance(data, dict):
        fail("device receipt root must be an object")
    if raw != canonical_bytes(data):
        fail("device receipt is not canonical JSON")
    digest = data.get("payload_sha256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("device receipt integrity field is malformed")
    state = dict(data)
    state.pop("payload_sha256", None)
    if sha256_bytes(canonical_bytes(state)) != digest:
        fail("device receipt payload digest changed")
    if data.get("schema") != SCHEMA or data.get("owner") != OWNER:
        fail("device receipt ownership/schema is wrong")
    if metadata_only:
        return data
    return data


def verify_receipt(path: Path) -> dict[str, Any]:
    """Verify the receipt matches the live device exactly.

    Two checks: (1) re-collect state and compare structurally to the stored
    receipt (a binary changed, a file vanished, a path moved); (2) compare
    every declared runtime/tool version against the contract (the installer and
    the contract must agree). Either failing is ``NOT_PROVEN``.
    """
    data = load_receipt(path)
    if data.get("bootstrap_version") != BOOTSTRAP_VERSION:
        fail("device receipt belongs to a different bootstrap version")
    profile = data.get("profile")
    if profile not in VALID_PROFILES:
        fail("device receipt is missing a valid profile; rebuild the receipt")
    expected_home = Path.home()
    if data.get("home") != str(expected_home):
        fail("device receipt belongs to a different home directory")
    actual = collect_state(home=expected_home, profile=profile)
    expected = dict(data)
    expected.pop("payload_sha256", None)
    if actual != expected:
        fail("installed device runtime differs from its exact receipt")
    _verify_contract_versions(actual, profile=profile)
    return data


def _verify_contract_versions(state: dict[str, Any], *, profile: str = "desktop") -> None:
    """Assert every installed runtime/tool version matches the contract.

    This closes the gap that ``ubuntu/verify.sh`` leaves open: that script
    compares against literals hardcoded in bash, which can drift from the
    contract. Here the contract is the single source of truth.

    ``profile`` scopes profile-specific user tools. Runtime hosts and pinned
    source tools are required on every Ubuntu profile by contract 3.0.1.

    The ``ubuntu_*`` contract fields pin exact artifacts, which only Ubuntu
    installs. macOS resolves the same tools through Homebrew, which preserves
    an already installed formula, so asserting those fields on a macOS device
    reports drift that is not drift. Version equality is therefore checked only
    on the platforms the contract pins exactly; elsewhere the versions are
    still collected into the receipt, they are simply not asserted.
    """
    contract = load_contract()
    runtime_support = contract.get("runtime_support", {})
    drifts: list[str] = []
    exact = _current_os() in EXACT_VERSION_PLATFORMS

    for name, _flag, field in [
        (n, RUNTIME_HOSTS[n][0], RUNTIME_HOSTS[n][1]) for n in RUNTIME_HOSTS
    ]:
        declared = runtime_support.get(field)
        if declared is None or not exact:
            continue
        installed = state.get("runtime_hosts", {}).get(name, {}).get("normalized")
        # Strip a leading 'v' from the declared value: the contract stores
        # "v0.23.0" for gopls (matching the Go module tag), but the installed
        # binary reports "0.23.0" (semver without the Go-module prefix).
        declared_norm = declared.lstrip("v") if declared else declared
        if installed is None or installed == "absent":
            drifts.append(f"{name}: absent (contract declares {declared})")
        elif installed != declared_norm:
            drifts.append(f"{name}: installed {installed} != contract {declared}")

    declared_tools = runtime_support.get(PINNED_SOURCE_TOOLS_CONTRACT, {}) if exact else {}
    installed_tools = state.get("pinned_source_tools", {})
    for name, spec in declared_tools.items():
        declared = spec.get("version")
        installed = installed_tools.get(name)
        if installed is None:
            drifts.append(f"{name}: absent (contract declares {declared})")
        elif installed != declared:
            drifts.append(f"{name}: installed {installed} != contract {declared}")

    declared_user_tools = contract.get("user_tools", {})
    installed_user_tools = state.get("user_tools", {})
    for name, spec in declared_user_tools.items():
        if not _applies_to_current_os(spec):
            continue
        if profile not in spec.get("profiles", VALID_PROFILES):
            continue
        # The receipt schema has no GUI dimension. GUI-only tools are proven by
        # the strict platform verifier, not guessed from a profile name.
        if spec.get("gui_required"):
            continue
        declared = spec.get("version")
        installed = installed_user_tools.get(name, {}).get("installed_version")
        if installed is None or installed == "absent":
            drifts.append(f"{name}: absent (contract declares {declared})")
        elif installed != declared:
            drifts.append(f"{name}: installed {installed} != contract {declared}")
        source = spec.get("source", {})
        assets = source.get("assets", {}) if isinstance(source, dict) else {}
        if assets:
            system = _current_os()
            machine = os.uname().machine
            normalized_machine = {
                "arm64": "aarch64",
                "aarch64": "aarch64",
                "x86_64": "x86_64",
                "amd64": "x86_64",
            }.get(machine, machine)
            asset_key = f"macos-{normalized_machine}" if system == "macos" else f"linux-{normalized_machine}"
            expected_asset = assets.get(asset_key)
            observed_sha = installed_user_tools.get(name, {}).get("sha256")
            if not isinstance(expected_asset, dict):
                drifts.append(f"{name}: contract has no asset for {asset_key}")
            elif observed_sha != expected_asset.get("sha256"):
                drifts.append(
                    f"{name}: installed SHA-256 {observed_sha or 'absent'} != "
                    f"contract {expected_asset.get('sha256')}"
                )

    # Harness ownership is profile-independent.
    drifts.extend(_verify_harness_ownership(state))

    if drifts:
        fail("device drifts from contract:\n  " + "\n  ".join(drifts))


# ----------------------------- CLI -----------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser(
        "build", help="build a receipt from the current device state"
    )
    build.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_RECEIPT,
        help=f"receipt path (default: {DEFAULT_RECEIPT})",
    )
    build.add_argument(
        "--profile",
        choices=list(VALID_PROFILES),
        default=None,
        help=(
            "device profile this receipt records; falls back to RLDYOUR_PROFILE, "
            "then RLDYOUR_LOCAL_EXECUTION_POLICY, then desktop"
        ),
    )
    build.add_argument(
        "--replace-invalid",
        action="store_true",
        help=(
            "replace a receipt that fails self-integrity, retaining the "
            "unverifiable copy beside it as <name>.rejected.N"
        ),
    )

    verify = subparsers.add_parser(
        "verify", help="verify the device matches its receipt and the contract"
    )
    verify.add_argument("--receipt", type=Path)
    verify.add_argument("--json", action="store_true")

    metadata = subparsers.add_parser(
        "metadata-only",
        help="validate receipt ownership/canonical self-integrity before replacement",
    )
    metadata.add_argument("--receipt", type=Path, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "build":
            profile = _resolve_build_profile(getattr(args, "profile", None))
            output: Path = args.output
            output.parent.mkdir(parents=True, exist_ok=True)
            superseded: bytes | None = None
            if output.exists() or output.is_symlink():
                # A symlink at the receipt path is an attack shape rather than
                # corruption, so it is refused outright and --replace-invalid
                # does not apply to it.
                if output.is_symlink():
                    fail(f"refusing to overwrite a symlinked receipt: {output}")
                # Validate the full self-integrity of the receipt being
                # replaced, not merely its schema and owner: a receipt whose
                # canonical form or payload digest no longer matches is
                # evidence of tampering, and quietly replacing it destroys
                # exactly the evidence this tool exists to preserve.
                try:
                    load_receipt(output, metadata_only=True)
                except IntegrityError:
                    if not args.replace_invalid:
                        raise
                    rejected = retain_rejected_receipt(output)
                    print(f"retained rejected receipt: {rejected}", file=sys.stderr)
                else:
                    superseded = output.read_bytes()
            # Collect before publishing. The previous order renamed the active
            # receipt out of the way first, so any failure in collection or in
            # the write left the device with no active receipt at all and no
            # rollback.
            state = collect_state(home=Path.home(), profile=profile)
            write_file_atomically(output, canonical_bytes(payload_with_integrity(state)))
            # The backup is written only once a valid replacement is in place,
            # so the active path is never the thing that goes missing.
            if superseded is not None:
                write_file_atomically(output.with_suffix(".json.bak"), superseded)
            print(output)
            return 0

        if args.command == "metadata-only":
            load_receipt(args.receipt, metadata_only=True)
            print("device-receipt-metadata-ok")
            return 0

        receipt = args.receipt or DEFAULT_RECEIPT
        data = verify_receipt(receipt)
        result = {
            "status": "PROVEN",
            "receipt": str(receipt),
            "payload_sha256": data["payload_sha256"],
            "platform": data.get("platform", "unknown"),
        }
        if args.json:
            print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        else:
            print("device-integrity: PROVEN")
            print(f"receipt: {receipt}")
            print(f"platform: {data.get('platform', 'unknown')}")
        return 0
    except IntegrityError as exc:
        result = {"status": "NOT_PROVEN", "error": str(exc)}
        if getattr(args, "json", False):
            print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        else:
            print(f"device-integrity: NOT_PROVEN: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
