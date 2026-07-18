#!/usr/bin/env python3
"""Build and verify the installed fail-closed browser runtime receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, NoReturn

ROOT = Path(__file__).resolve().parents[1]
OWNER = "macos-ubuntu-bootstrap"
SCHEMA = "rldyour-browser-runtime-receipt-v1"
BOOTSTRAP_VERSION = "0.3.10"
MARKER = "# Managed by macos-ubuntu-bootstrap: browser-stack-v1"
ENDPOINT = "http://127.0.0.1:9222"
CHROME_VERSION = "1.5.0"
PLAYWRIGHT_VERSION = "0.1.17"
CLOAK_VERSION = "0.4.10"
WEBWRIGHT_STATUS = "retired-fail-closed"
ACTIVE_PROVIDERS = ["playwright-cli", "chrome-devtools-mcp"]
WRAPPER_NAMES = (
    "cloak-chromium",
    "cloakbrowser-cdp-health",
    "chrome-devtools-mcp",
    "playwright-cli",
    "webwright",
)
DISABLED_WEBWRIGHT = (
    "#!/usr/bin/env bash\n"
    f"{MARKER}\n"
    "set -euo pipefail\n"
    'echo "webwright: retired by the fail-closed browser policy; arbitrary Python/browser objects are NOT_PROVEN" >&2\n'
    "exit 78\n"
).encode()


class IntegrityError(RuntimeError):
    """A browser runtime invariant was not proven."""


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


def regular_owned(path: Path, *, executable: bool = False) -> os.stat_result:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"required path is missing: {path}")
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        fail(f"path must be a regular non-symlink file: {path}")
    if metadata.st_uid != os.getuid():
        fail(f"path is not owned by the current UID: {path}")
    if metadata.st_mode & 0o022:
        fail(f"path is group/world-writable: {path}")
    if executable and not metadata.st_mode & stat.S_IXUSR:
        fail(f"path is not owner-executable: {path}")
    return metadata


def safe_directory(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"required directory is missing: {path}")
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        fail(f"path must be a non-symlink directory: {path}")
    if metadata.st_uid != os.getuid():
        fail(f"directory is not owned by the current UID: {path}")
    if metadata.st_mode & 0o022:
        fail(f"directory is group/world-writable: {path}")


def ensure_under(path: Path, root: Path, label: str) -> None:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (FileNotFoundError, ValueError):
        fail(f"{label} escaped its managed namespace: {path}")


def exact_lines(path: Path) -> list[str]:
    regular_owned(path)
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        fail(f"managed text file is not UTF-8: {path}")


def require_marker(lines: list[str], marker: str, path: Path) -> None:
    if lines.count(marker) != 1:
        fail(f"managed marker cardinality is not exactly one: {path}")


def parse_exact_kv_marker(
    path: Path,
    *,
    marker: str,
    expected_keys: set[str],
) -> dict[str, str]:
    lines = exact_lines(path)
    require_marker(lines, marker, path)
    result: dict[str, str] = {}
    for line in lines:
        if line == marker:
            continue
        if "=" not in line:
            fail(f"unexpected runtime marker line: {path}")
        key, value = line.split("=", 1)
        if key in result:
            fail(f"duplicate runtime marker key {key}: {path}")
        result[key] = value
    if set(result) != expected_keys:
        fail(f"runtime marker has an unexpected key set: {path}")
    return result


def content_id(label: str, inputs: list[Path]) -> str:
    digest = hashlib.sha256()
    digest.update(b"label\0")
    digest.update(label.encode())
    digest.update(b"\0")
    for path in inputs:
        regular_owned(path)
        digest.update(b"file\0")
        digest.update(path.name.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def cloak_runtime_identity(platform_label: str) -> str:
    """Return the installer's ID for repository-named Cloak runtime inputs."""
    return content_id(
        f"cloakbrowser|version={CLOAK_VERSION}|platform={platform_label}",
        [
            ROOT / "templates/browser/cloakbrowser-pyproject.toml",
            ROOT / "templates/browser/cloakbrowser-uv.lock",
        ],
    )


def package_version(path: Path) -> str:
    regular_owned(path)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))["version"]
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise IntegrityError(f"package metadata is invalid: {path}") from exc
    if not isinstance(value, str):
        fail(f"package version is not a string: {path}")
    return value


def wrapper_record(path: Path) -> dict[str, Any]:
    regular_owned(path, executable=True)
    lines = exact_lines(path)
    require_marker(lines, MARKER, path)
    return {
        "path": str(path),
        "sha256": sha256_file(path),
    }


def require_exact_wrapper_contract(
    wrappers: dict[str, dict[str, Any]],
    *,
    cloak_binary: Path,
    chrome_provider: Path,
    playwright_provider: Path,
    config_runtime: Path,
) -> None:
    bin_dir = Path(wrappers["cloak-chromium"]["path"]).parent
    health_path = bin_dir / "cloakbrowser-cdp-health"

    cloak_lines = exact_lines(Path(wrappers["cloak-chromium"]["path"]))
    if (
        cloak_lines.count(
            f'if [ "$actual_sha256" != "{sha256_file(cloak_binary)}" ]; then'
        )
        != 1
    ):
        fail("cloak-chromium is not bound to the verified binary digest")
    if sum(line.startswith("bin=") for line in cloak_lines) != 1:
        fail("cloak-chromium has an ambiguous binary target")

    health_lines = exact_lines(health_path)
    for required in (
        'endpoint="http://127.0.0.1:9222"',
        'service_pid=""',
        'json="$(curl --noproxy \'*\' --fail --silent --show-error --max-time 2 "$endpoint/json/version")" || {',
    ):
        if health_lines.count(required) != 1:
            fail("Cloak health wrapper does not match the rigorous managed contract")
    if not any(
        "fixed CDP listener is not owned by the managed service PID" in line
        for line in health_lines
    ):
        fail("Cloak health wrapper lacks listener ownership enforcement")

    chrome_lines = exact_lines(Path(wrappers["chrome-devtools-mcp"]["path"]))
    for required in (
        f'endpoint="{ENDPOINT}"',
        f'health="{health_path}"',
        f'provider="{chrome_provider}"',
        'exec "$provider" "--browser-url=$endpoint" "${args[@]}" --no-usage-statistics --no-performance-crux',
    ):
        if chrome_lines.count(required) != 1:
            fail("Chrome DevTools MCP wrapper escaped its exact managed contract")

    playwright_lines = exact_lines(Path(wrappers["playwright-cli"]["path"]))
    for required in (
        f'endpoint="{ENDPOINT}"',
        f'health="{health_path}"',
        f'provider="{playwright_provider}"',
        f'config="{config_runtime / "playwright-cli.json"}"',
        "    run-code|--filename|--filename=*)",
        'exec "$provider" "--config=$config" "${args[@]}"',
    ):
        if playwright_lines.count(required) != 1:
            fail("Playwright CLI wrapper escaped its exact managed contract")

    webwright = Path(wrappers["webwright"]["path"])
    if webwright.read_bytes() != DISABLED_WEBWRIGHT:
        fail("Webwright is not the exact retired fail-closed wrapper")


def policy_hashes() -> dict[str, str]:
    paths = {
        "integrity_policy": Path(__file__).resolve(),
        "installer_policy": ROOT / "scripts/lib/common.sh",
        "contract": ROOT / "config/rldyour-contract.json",
        "cloak_project": ROOT / "templates/browser/cloakbrowser-pyproject.toml",
        "cloak_lock": ROOT / "templates/browser/cloakbrowser-uv.lock",
        "provider_manifest": ROOT / "templates/browser/provider/package.json",
        "provider_lock": ROOT / "templates/browser/provider/bun.lock",
        "playwright_config": ROOT / "templates/browser/playwright-cli.json",
    }
    for path in paths.values():
        regular_owned(path)
    return {name: sha256_file(path) for name, path in paths.items()}


def validate_contract() -> None:
    try:
        contract = json.loads(
            (ROOT / "config/rldyour-contract.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError("repository browser contract is unreadable") from exc
    browser = contract.get("browser_automation", {})
    expected = {
        "required": True,
        "provider": "cloakbrowser",
        "cloakbrowser": CLOAK_VERSION,
        "cdp_endpoint": ENDPOINT,
        "fallback_allowed": False,
        "chrome_devtools_mcp": CHROME_VERSION,
        "playwright_cli": PLAYWRIGHT_VERSION,
        "active_providers": ACTIVE_PROVIDERS,
        "webwright_status": WEBWRIGHT_STATUS,
        "webwright_enabled": False,
        "disabled_wrapper": "webwright",
    }
    for key, value in expected.items():
        if browser.get(key) != value:
            fail(f"repository browser contract mismatch for {key}")


def validate_binary_receipt(cloak_home: Path, expected_binary: Path) -> dict[str, str]:
    receipt = cloak_home / ".verified-binary"
    values = parse_exact_kv_marker(
        receipt,
        marker=MARKER,
        expected_keys={"package", "path", "sha256"},
    )
    if values["package"] != f"cloakbrowser@{CLOAK_VERSION}":
        fail("CloakBrowser binary receipt package pin is wrong")
    if Path(values["path"]) != expected_binary:
        fail("CloakBrowser binary receipt path changed")
    if not re.fullmatch(r"[0-9a-f]{64}", values["sha256"]):
        fail("CloakBrowser binary receipt digest is malformed")
    regular_owned(expected_binary, executable=True)
    ensure_under(expected_binary, cloak_home / "cache", "CloakBrowser binary")
    if sha256_file(expected_binary) != values["sha256"]:
        fail("CloakBrowser binary differs from its signed-download receipt")
    return values


def collect_state(
    *,
    home: Path,
    cloak_runtime: Path,
    cloak_binary: Path,
    node_runtime: Path,
    config_runtime: Path,
    run_health: bool,
) -> dict[str, Any]:
    validate_contract()
    bin_dir = home / ".local/bin"
    browser_home = home / ".local/share/rldyour/browser-stack"
    cloak_home = home / ".local/share/rldyour/cloakbrowser"
    safe_directory(bin_dir)
    safe_directory(browser_home)
    safe_directory(cloak_home)

    platform_label = f"{platform.system()}-{platform.machine()}"
    for runtime in (cloak_runtime, node_runtime, config_runtime):
        safe_directory(runtime)

    ensure_under(cloak_runtime, cloak_home / "runtimes", "CloakBrowser runtime")
    cloak_project = cloak_runtime / "pyproject.toml"
    cloak_lock = cloak_runtime / "uv.lock"
    cloak_marker = cloak_runtime / ".rldyour-runtime"
    cloak_project_source = ROOT / "templates/browser/cloakbrowser-pyproject.toml"
    cloak_lock_source = ROOT / "templates/browser/cloakbrowser-uv.lock"
    # The installer derives the content ID from the repository-owned source
    # inputs before publishing them under their conventional runtime names.
    # Preserve those logical source names here; hashing the renamed installed
    # copies would produce a different identity even when every byte matches.
    cloak_identity = cloak_runtime_identity(platform_label)
    if cloak_runtime.name != f"cloak-{CLOAK_VERSION}-{cloak_identity}":
        fail("CloakBrowser content-addressed runtime path is wrong")
    cloak_values = parse_exact_kv_marker(
        cloak_marker,
        marker="# Managed by macos-ubuntu-bootstrap: cloakbrowser-runtime-v2",
        expected_keys={"identity", "cloakbrowser"},
    )
    if cloak_values != {"identity": cloak_identity, "cloakbrowser": CLOAK_VERSION}:
        fail("CloakBrowser runtime marker identity is wrong")
    if cloak_project.read_bytes() != cloak_project_source.read_bytes():
        fail("installed CloakBrowser project differs from the release template")
    if cloak_lock.read_bytes() != cloak_lock_source.read_bytes():
        fail("installed CloakBrowser lock differs from the release template")

    binary_receipt = validate_binary_receipt(cloak_home, cloak_binary)

    ensure_under(node_runtime, browser_home / "node-runtimes", "browser Node runtime")
    provider_manifest = node_runtime / "package.json"
    provider_lock = node_runtime / "bun.lock"
    node_marker = node_runtime / ".rldyour-runtime"
    node_identity = content_id(
        f"browser-node|chrome={CHROME_VERSION}|playwright={PLAYWRIGHT_VERSION}|platform={platform_label}",
        [provider_manifest, provider_lock],
    )
    if (
        node_runtime.name
        != f"node-{CHROME_VERSION}-{PLAYWRIGHT_VERSION}-{node_identity}"
    ):
        fail("browser Node content-addressed runtime path is wrong")
    node_values = parse_exact_kv_marker(
        node_marker,
        marker="# Managed by macos-ubuntu-bootstrap: browser-node-runtime-v2",
        expected_keys={"identity", "chrome_devtools_mcp", "playwright_cli"},
    )
    expected_node_values = {
        "identity": node_identity,
        "chrome_devtools_mcp": CHROME_VERSION,
        "playwright_cli": PLAYWRIGHT_VERSION,
    }
    if node_values != expected_node_values:
        fail("browser Node runtime marker identity is wrong")
    if (
        provider_manifest.read_bytes()
        != (ROOT / "templates/browser/provider/package.json").read_bytes()
    ):
        fail("installed browser provider manifest differs from the release template")
    if (
        provider_lock.read_bytes()
        != (ROOT / "templates/browser/provider/bun.lock").read_bytes()
    ):
        fail("installed browser provider lock differs from the release template")

    chrome_provider = node_runtime / "node_modules/.bin/chrome-devtools-mcp"
    playwright_provider = node_runtime / "node_modules/.bin/playwright-cli"
    chrome_real = chrome_provider.resolve(strict=True)
    playwright_real = playwright_provider.resolve(strict=True)
    ensure_under(chrome_real, node_runtime, "Chrome DevTools MCP provider")
    ensure_under(playwright_real, node_runtime, "Playwright CLI provider")
    regular_owned(chrome_real, executable=True)
    regular_owned(playwright_real, executable=True)
    if (
        package_version(node_runtime / "node_modules/chrome-devtools-mcp/package.json")
        != CHROME_VERSION
    ):
        fail("Chrome DevTools MCP package version is wrong")
    if (
        package_version(node_runtime / "node_modules/@playwright/cli/package.json")
        != PLAYWRIGHT_VERSION
    ):
        fail("Playwright CLI package version is wrong")

    ensure_under(
        config_runtime, browser_home / "config-runtimes", "browser config runtime"
    )
    playwright_config = config_runtime / "playwright-cli.json"
    config_marker = config_runtime / ".rldyour-runtime"
    config_identity = content_id("browser-config|schema=3", [playwright_config])
    if config_runtime.name != f"config-{config_identity}":
        fail("browser config content-addressed runtime path is wrong")
    config_values = parse_exact_kv_marker(
        config_marker,
        marker="# Managed by macos-ubuntu-bootstrap: browser-config-runtime-v3",
        expected_keys={"identity"},
    )
    if config_values != {"identity": config_identity}:
        fail("browser config runtime marker identity is wrong")
    if (
        playwright_config.read_bytes()
        != (ROOT / "templates/browser/playwright-cli.json").read_bytes()
    ):
        fail("installed Playwright config differs from the release template")
    expected_playwright = {
        "browser": {
            "browserName": "chromium",
            "isolated": False,
            "remoteEndpoint": None,
            "cdpEndpoint": ENDPOINT,
            "cdpTimeout": 5000,
        }
    }
    if json.loads(playwright_config.read_text(encoding="utf-8")) != expected_playwright:
        fail("Playwright config escaped the fixed CDP contract")

    wrappers = {name: wrapper_record(bin_dir / name) for name in WRAPPER_NAMES}
    require_exact_wrapper_contract(
        wrappers,
        cloak_binary=cloak_binary,
        chrome_provider=chrome_provider,
        playwright_provider=playwright_provider,
        config_runtime=config_runtime,
    )

    if platform.system() == "Darwin":
        service_file = home / "Library/LaunchAgents/com.rldyour.cloakbrowser.plist"
    else:
        service_file = home / ".config/systemd/user/rldyour-cloakbrowser.service"
    regular_owned(service_file)
    service_lines = exact_lines(service_file)
    service_marker = (
        "<!-- Managed by macos-ubuntu-bootstrap: browser-stack-v1 -->"
        if platform.system() == "Darwin"
        else MARKER
    )
    require_marker(service_lines, service_marker, service_file)

    if run_health:
        env = os.environ.copy()
        env.pop("PYTHONPATH", None)
        env.pop("PYTHONHOME", None)
        try:
            health = subprocess.run(
                [str(bin_dir / "cloakbrowser-cdp-health")],
                check=False,
                capture_output=True,
                text=True,
                env=env,
                timeout=15,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise IntegrityError(
                "rigorous CloakBrowser health probe could not complete"
            ) from exc
        if health.returncode != 0:
            detail = (health.stderr or health.stdout).strip()
            fail(f"rigorous CloakBrowser health probe failed: {detail or 'no detail'}")

    return {
        "schema": SCHEMA,
        "owner": OWNER,
        "bootstrap_version": BOOTSTRAP_VERSION,
        "endpoint": ENDPOINT,
        "active_providers": ACTIVE_PROVIDERS,
        "webwright_status": WEBWRIGHT_STATUS,
        "home": str(home),
        "policy_hashes": policy_hashes(),
        "cloak_binary": {
            "path": str(cloak_binary),
            "sha256": binary_receipt["sha256"],
            "package": binary_receipt["package"],
        },
        "runtimes": {
            "cloakbrowser": {
                "path": str(cloak_runtime),
                "identity": cloak_identity,
                "marker_sha256": sha256_file(cloak_marker),
                "project_sha256": sha256_file(cloak_project),
                "lock_sha256": sha256_file(cloak_lock),
            },
            "node_providers": {
                "path": str(node_runtime),
                "identity": node_identity,
                "marker_sha256": sha256_file(node_marker),
                "manifest_sha256": sha256_file(provider_manifest),
                "lock_sha256": sha256_file(provider_lock),
            },
            "config": {
                "path": str(config_runtime),
                "identity": config_identity,
                "marker_sha256": sha256_file(config_marker),
                "playwright_sha256": sha256_file(playwright_config),
            },
        },
        "providers": {
            "chrome-devtools-mcp": {
                "version": CHROME_VERSION,
                "path": str(chrome_provider),
                "realpath": str(chrome_real),
                "sha256": sha256_file(chrome_real),
            },
            "playwright-cli": {
                "version": PLAYWRIGHT_VERSION,
                "path": str(playwright_provider),
                "realpath": str(playwright_real),
                "sha256": sha256_file(playwright_real),
            },
            "webwright": {
                "enabled": False,
                "status": WEBWRIGHT_STATUS,
                "runtime_execution": False,
            },
        },
        "wrappers": wrappers,
        "service": {
            "path": str(service_file),
            "sha256": sha256_file(service_file),
        },
        "health": "proven",
    }


def payload_with_integrity(state: dict[str, Any]) -> dict[str, Any]:
    result = dict(state)
    result["payload_sha256"] = sha256_bytes(canonical_bytes(state))
    return result


def load_receipt(path: Path, *, metadata_only: bool = False) -> dict[str, Any]:
    regular_owned(path)
    try:
        raw = path.read_bytes()
        data = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError(
            f"browser runtime receipt is invalid JSON: {path}"
        ) from exc
    if not isinstance(data, dict):
        fail("browser runtime receipt root must be an object")
    if raw != canonical_bytes(data):
        fail("browser runtime receipt is not canonical JSON")
    digest = data.get("payload_sha256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("browser runtime receipt integrity field is malformed")
    state = dict(data)
    state.pop("payload_sha256", None)
    if sha256_bytes(canonical_bytes(state)) != digest:
        fail("browser runtime receipt payload digest changed")
    if data.get("schema") != SCHEMA or data.get("owner") != OWNER:
        fail("browser runtime receipt ownership/schema is wrong")
    if metadata_only:
        return data
    return data


def verify_receipt(path: Path, *, run_health: bool = True) -> dict[str, Any]:
    data = load_receipt(path)
    if data.get("bootstrap_version") != BOOTSTRAP_VERSION:
        fail("browser runtime receipt belongs to a different bootstrap version")
    expected_home = Path.home()
    if data.get("home") != str(expected_home):
        fail("browser runtime receipt belongs to a different home directory")
    try:
        cloak_runtime = Path(data["runtimes"]["cloakbrowser"]["path"])
        node_runtime = Path(data["runtimes"]["node_providers"]["path"])
        config_runtime = Path(data["runtimes"]["config"]["path"])
        cloak_binary = Path(data["cloak_binary"]["path"])
    except (KeyError, TypeError) as exc:
        raise IntegrityError("browser runtime receipt inventory is incomplete") from exc
    actual = collect_state(
        home=expected_home,
        cloak_runtime=cloak_runtime,
        cloak_binary=cloak_binary,
        node_runtime=node_runtime,
        config_runtime=config_runtime,
        run_health=run_health,
    )
    expected = dict(data)
    expected.pop("payload_sha256", None)
    if actual != expected:
        fail("installed browser runtime differs from its exact receipt")
    return data


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser(
        "build", help="build a receipt from a proven installed runtime"
    )
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--cloak-runtime", type=Path, required=True)
    build.add_argument("--cloak-binary", type=Path, required=True)
    build.add_argument("--node-runtime", type=Path, required=True)
    build.add_argument("--config-runtime", type=Path, required=True)

    verify = subparsers.add_parser("verify", help="verify the exact installed runtime")
    verify.add_argument("--receipt", type=Path)
    verify.add_argument("--json", action="store_true")

    metadata = subparsers.add_parser(
        "metadata-only",
        help="validate receipt ownership/canonical self-integrity before atomic replacement",
    )
    metadata.add_argument("--receipt", type=Path, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "build":
            output: Path = args.output
            if output.exists() or output.is_symlink():
                fail(f"receipt staging path already exists: {output}")
            state = collect_state(
                home=Path.home(),
                cloak_runtime=args.cloak_runtime,
                cloak_binary=args.cloak_binary,
                node_runtime=args.node_runtime,
                config_runtime=args.config_runtime,
                run_health=True,
            )
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            descriptor = os.open(output, flags, 0o600)
            try:
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(canonical_bytes(payload_with_integrity(state)))
                    handle.flush()
                    os.fsync(handle.fileno())
            except BaseException:
                output.unlink(missing_ok=True)
                raise
            print(output)
            return 0
        if args.command == "metadata-only":
            load_receipt(args.receipt, metadata_only=True)
            print("browser-runtime-receipt-metadata-ok")
            return 0

        receipt = args.receipt or (
            Path.home()
            / ".local/share/rldyour/browser-stack/browser-runtime-receipt.json"
        )
        data = verify_receipt(receipt)
        result = {
            "status": "PROVEN",
            "receipt": str(receipt),
            "payload_sha256": data["payload_sha256"],
            "active_providers": ACTIVE_PROVIDERS,
            "webwright": WEBWRIGHT_STATUS,
            "cloak_health": "proven",
        }
        if args.json:
            print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        else:
            print("browser-runtime-integrity: PROVEN")
            print(f"receipt: {receipt}")
            print(f"active providers: {', '.join(ACTIVE_PROVIDERS)}")
            print(f"webwright: {WEBWRIGHT_STATUS}")
        return 0
    except IntegrityError as exc:
        result = {"status": "NOT_PROVEN", "error": str(exc)}
        if getattr(args, "json", False):
            print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        else:
            print(f"browser-runtime-integrity: NOT_PROVEN: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
