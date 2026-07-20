import hashlib
import json
import os
import re
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run_shell(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "scripts/bootstrap.sh", *args],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def file(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def parse_array(body: str, name: str) -> set[str]:
    match = re.search(
        rf"^\s*{re.escape(name)}=\((.*?)\)", body, re.MULTILINE | re.DOTALL
    )
    assert match is not None, f"{name} array not found"
    values: list[str] = []
    for quoted_double, quoted_single, bare in re.findall(
        r'"([^"]+)"|\'([^\']+)\'|([^\s#]+)', match.group(1)
    ):
        value = quoted_double or quoted_single or bare
        if value:
            values.append(value)
    return set(values)


def test_help_documents_composed_profiles() -> None:
    result = run_shell("--help")
    assert result.returncode == 0
    assert "--gui|--no-gui" in result.stdout
    assert "--docker-mode none|rootful|rootless" in result.stdout
    assert "source editing" in result.stdout
    assert "CloakBrowser" in result.stdout


def test_plan_matrix_is_non_destructive() -> None:
    common = ("--plan", "--skip-system", "--skip-ai", "--skip-lsps", "--skip-checks")
    matrix = (
        ("--platform", "macos", "--profile", "desktop", "--gui"),
        ("--platform", "macos", "--profile", "desktop", "--no-gui"),
        ("--platform", "ubuntu", "--profile", "desktop", "--gui"),
        ("--platform", "ubuntu", "--profile", "desktop", "--no-gui"),
        ("--platform", "ubuntu", "--profile", "server", "--docker-mode", "rootful"),
        ("--platform", "ubuntu", "--profile", "server", "--docker-mode", "rootless"),
    )
    for profile in matrix:
        result = run_shell(*profile, *common)
        assert result.returncode == 0, result.stderr + result.stdout
        assert "dry-run" in result.stdout
        assert "CloakBrowser" in result.stdout
        if "server" in profile:
            assert "Ubuntu server module" not in result.stdout


def test_skip_system_covers_ubuntu_server_layer() -> None:
    ubuntu = file("scripts/ubuntu/install.sh")
    match = re.search(
        r"^run_server_layer\(\) \{(.*?)(?=^\w[^\n]*\(\) \{)",
        ubuntu,
        re.MULTILINE | re.DOTALL,
    )
    assert match is not None
    body = match.group(1)
    guard = 'if [ "$SKIP_SYSTEM" -eq 1 ]; then'
    assert guard in body
    assert body.index(guard) < body.index("is_supported_ubuntu")


def test_managed_scripts_avoid_ambiguous_and_or_control_flow() -> None:
    ambiguous = re.compile(r"\]\s*&&\s*\[[^\n]*\]\s*\|\|\s*\{")
    for path in sorted((ROOT / "scripts").rglob("*.sh")):
        body = path.read_text(encoding="utf-8")
        assert not ambiguous.search(body), f"ambiguous A && B || fallback in {path}"


def test_invalid_profile_combinations_fail_closed() -> None:
    invalid = (
        ("--platform", "ubuntu"),
        ("--platform", "macos", "--profile", "server"),
        ("--platform", "ubuntu", "--profile", "server", "--gui"),
        ("--platform", "ubuntu", "--profile", "desktop", "--docker-mode", "rootful"),
        ("--platform", "ubuntu", "--skip-browser"),
    )
    for args in invalid:
        result = run_shell(*args, "--plan")
        assert result.returncode != 0


def test_contract_version_and_profile_matrix() -> None:
    contract = json.loads(file("config/rldyour-contract.json"))
    assert contract["schema_version"] == 2
    version = file("VERSION").strip()
    assert contract["adapter"]["version"] == version
    assert (
        json.loads(file("templates/browser/provider/package.json"))["version"]
        == version
    )
    assert f'version = "{version}"' in file(
        "templates/browser/cloakbrowser-pyproject.toml"
    )
    assert f'version = "{version}"' in file("templates/browser/cloakbrowser-uv.lock")
    for path in (
        "README.md",
        "AGENTS.md",
        ".claude/CLAUDE.md",
        "docs/install.md",
        "SECURITY.md",
    ):
        assert version in file(path), f"{path} missing adapter version {version}"
    assert contract["targets"]["macos"]["architectures"] == ["arm64"]
    assert contract["targets"]["ubuntu"]["releases"] == ["24.04", "26.04"]
    assert (
        contract["targets"]["ubuntu"]["profiles"]["server"]["default_docker_mode"]
        == "rootful"
    )
    assert contract["targets"]["ubuntu"]["profiles"]["desktop"]["docker_modes"] == [
        "none"
    ]
    assert {"chatgpt", "codex-app"}.issubset(contract["gui"]["macos"])
    assert contract["runtime_support"]["ubuntu_node_lts"] == "24.18.0"
    assert set(contract["runtime_support"]["ubuntu_node_sha256"]) == {"x64", "arm64"}
    assert contract["runtime_support"]["ubuntu_uv"] == "0.11.29"
    assert contract["runtime_support"]["ubuntu_bun"] == "1.3.14"
    assert contract["safety"]["ubuntu_profile_selection"] == "explicit"


def test_active_harness_set_is_only_codex_and_zcode() -> None:
    # RVR-P1-004: one owner per harness. Claude Code, OpenCode, MiMoCode, and
    # Antigravity are fully removed; codex and zcode are delegated to their
    # authoritative NDDev modules.
    contract = json.loads(file("config/rldyour-contract.json"))
    assert "ai_cli" not in contract
    harnesses = contract["harnesses"]
    assert harnesses["policy"] == "one-owner-per-harness"
    assert harnesses["active"] == ["codex", "zcode"]
    assert harnesses["codex"]["module_path_env"] == "RLDYOUR_CODEX_MODULE"
    assert harnesses["zcode"]["module_path_env"] == "RLDYOUR_ZCODE_MODULE"

    installers = (file("scripts/macos/install.sh"), file("scripts/ubuntu/install.sh"))
    removed_constants = (
        "CLAUDE_CODE_VERSION",
        "OPENCODE_VERSION",
        "MIMOCODE_VERSION",
        "ANTIGRAVITY_VERSION",
        "ZCODE_VERSION",
    )
    for body in installers:
        for name in removed_constants:
            assert f"{name}=" not in body, f"stale harness constant {name}"
        assert "rldyour::install_selected_harnesses" in body

    # No harness is installed through a bun/npm global path.
    for body in installers:
        for package in (
            "@anthropic-ai/claude-code",
            "opencode-ai",
            "@mimo-ai/cli",
            "@openai/codex",
        ):
            assert f'bun add -g "{package}' not in body
            assert f"bun add -g {package}" not in body
            assert f"npm install -g {package}" not in body


def test_harness_delegation_wires_exact_module_commands() -> None:
    common = file("scripts/lib/common.sh")
    # Removed inline installers are gone.
    assert "install_ai_cli_bundle" not in common
    assert "install_antigravity_artifact" not in common
    assert "ai-cli-runtime-v1" not in common
    # Delegation helpers with the exact module commands are present.
    assert "rldyour::install_selected_harnesses" in common
    assert 'python3 "$module/$entry" install-cli --target "$target"' in common
    assert 'python3 "$module/$entry" apply --setup "$setup" --target "$target"' in common
    assert 'python3 "$module/$entry" install-builder --target "$target"' in common
    assert 'bash "$module/$entry" bootstrap "$flag"' in common
    assert 'bash "$module/$entry" install --setup nddev-builder "$flag"' in common
    # Codex module entrypoint and safe-by-default setup.
    assert 'entry="cli-tools/nddev_codex.py"' in common
    assert 'setup="safe"' in common
    assert "RLDYOUR_CODEX_FULL_AUTO" in common
    # ZCode module entrypoint and plan/apply lifecycle.
    assert 'entry="cli-tools/scripts/install.sh"' in common
    assert 'flag="--plan"' in common and 'flag="--apply"' in common
    # Unset module path is a skip, not an error.
    assert "skipping bootstrap-side delegation" in common


def test_desktop_manifests_exclude_project_runtime_and_docker() -> None:
    macos = parse_array(file("scripts/macos/install.sh"), "BREW_SOURCE_PACKAGES")
    gui_casks = parse_array(file("scripts/macos/install.sh"), "GUI_CASKS")
    ubuntu = parse_array(file("scripts/ubuntu/install.sh"), "APT_SOURCE_PACKAGES")
    forbidden_macos = {
        "docker",
        "docker-desktop",
        "go",
        "rustup",
        "dart",
        "cmake",
        "openjdk",
        "mise",
        "deno",
        "cargo-nextest",
    }
    forbidden_ubuntu = {
        "docker.io",
        "docker-ce",
        "build-essential",
        "golang-go",
        "rustc",
        "cargo",
        "dart",
        "cmake",
        "default-jdk",
        "r-base",
    }
    assert macos.isdisjoint(forbidden_macos)
    assert ubuntu.isdisjoint(forbidden_ubuntu)
    assert "llvm" in macos  # Homebrew's supported clangd distribution only.
    assert "docker-language-server" in macos
    assert {"chatgpt", "codex-app"}.issubset(gui_casks)
    assert "dockerfile-language-server-nodejs" in parse_array(
        file("scripts/ubuntu/install.sh"), "BUN_LSP_PACKAGES"
    )
    cloak_runtime = parse_array(
        file("scripts/ubuntu/install.sh"), "APT_CLOAK_RUNTIME_PACKAGES"
    )
    for dependency in ("libnss3", "libgbm1", "libgtk-3-0t64", "fonts-liberation"):
        assert dependency in cloak_runtime


def test_server_module_owns_docker_and_safe_hardening() -> None:
    server = file("scripts/ubuntu/server.sh")
    for package in (
        "docker-ce",
        "docker-ce-cli",
        "containerd.io",
        "docker-buildx-plugin",
        "docker-compose-plugin",
    ):
        assert package in server
    assert "24.04" in server and "26.04" in server
    assert "docker group is intentionally unchanged" in server
    assert "sshd -t" in server
    assert "--enable-ufw" in server and "--harden-ssh" in server
    assert "sysctl -w" not in server
    assert "/etc/sysctl.d" not in server
    assert "/etc/security/limits" not in server
    assert "docker_rootless_preflight" in server
    assert "existing rootful Docker/containerd state will be preserved" in server
    assert "rm -f /var/run/docker.sock" not in server
    assert "/etc/apt/keyrings/rldyour-docker.asc" in server
    assert "/etc/apt/sources.list.d/rldyour-docker.sources" in server
    assert "exact ownership is recorded in a sidecar" in server
    assert "RLDYOUR_SERVER_DOCKER_GPG_FINGERPRINT" not in server
    assert "rollback_ufw" in server
    assert 'chown root:root -- "$destination"' in server


def test_browser_stack_is_mandatory_and_fixed_to_cloak() -> None:
    common = file("scripts/lib/common.sh")
    bootstrap = file("scripts/bootstrap.sh")
    contract = json.loads(file("config/rldyour-contract.json"))["browser_automation"]
    assert contract == {
        "required": True,
        "provider": "cloakbrowser",
        "cloakbrowser": "0.4.10",
        "cdp_endpoint": "http://127.0.0.1:9222",
        "fallback_allowed": False,
        "chrome_devtools_mcp": "1.5.0",
        "playwright_cli": "0.1.17",
        "active_providers": ["playwright-cli", "chrome-devtools-mcp"],
        "webwright_status": "retired-fail-closed",
        "webwright_enabled": False,
        "disabled_wrapper": "webwright",
    }
    assert "RLDYOUR_BROWSER_REQUIRED=1" in bootstrap
    assert "--skip-browser is unsupported" in bootstrap
    assert 'local pin="0.4.10"' in common
    assert "127.0.0.1:9222" in common
    assert "alternate CDP endpoint rejected" in common
    provider_manifest = json.loads(file("templates/browser/provider/package.json"))
    assert provider_manifest["dependencies"] == {
        "@playwright/cli": "0.1.17",
        "chrome-devtools-mcp": "1.5.0",
    }
    assert '"cdpEndpoint": "http://127.0.0.1:9222"' in file(
        "templates/browser/playwright-cli.json"
    )
    assert "microsoft/Webwright" not in common
    assert "webwright-uv.lock" not in common
    assert not (ROOT / "templates/browser/webwright-uv.lock").exists()
    assert not (ROOT / "templates/browser/webwright-local-cdp.yaml").exists()
    assert "--frozen-lockfile" in common
    provider_lock = file("templates/browser/provider/bun.lock")
    assert '"chrome-devtools-mcp": ["chrome-devtools-mcp@1.5.0"' in provider_lock
    assert '"@playwright/cli": ["@playwright/cli@0.1.17"' in provider_lock
    cloak_lock = file("templates/browser/cloakbrowser-uv.lock")
    assert 'name = "cloakbrowser"' in cloak_lock
    assert 'version = "0.4.10"' in cloak_lock
    assert (
        "36342e97f02f82af43beda972ee785df69b9a17db374019109dd2b70b7c124d6" in cloak_lock
    )


def test_browser_fail_closed_regressions_are_guarded() -> None:
    common = file("scripts/lib/common.sh")
    for forbidden in (
        "CLOAKBROWSER_BINARY_PATH",
        "CLOAKBROWSER_DOWNLOAD_URL",
        "CLOAKBROWSER_SKIP_CHECKSUM",
        "CLOAKBROWSER_VERSION",
        "CLOAKBROWSER_WIDEVINE_CDM",
    ):
        assert forbidden in common
    assert "install|install-browser|attach)" in common
    assert "run-code|--filename|--filename=*)" in common
    assert "'--' cannot bypass the mandatory CDP and privacy flags" in common
    assert "'--' cannot bypass the mandatory CDP configuration" in common
    assert "--endpoint|--endpoint=*" in common
    assert "--no-usage-statistics --no-performance-crux" in common
    assert "CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1" in common
    assert "NO_UPDATE_NOTIFIER=1" in common
    assert "PWTEST_DAEMON_SESSION_DIR" in common
    assert "webwright.run.cli" not in common
    assert "retired by the fail-closed browser policy" in common
    assert "exit 78" in common
    assert "MainPID" in common
    assert "fixed CDP listener is not owned by the managed service PID" in common
    assert "service executable is not the verified CloakBrowser binary" in common
    assert "browser provider executable smoke check failed" in common
    assert "_playwright_config_owner_valid" in common
    assert 'chmod "$mode" "$dest"' in common


def test_browser_trust_override_propagates_to_public_entrypoint() -> None:
    result = subprocess.run(
        [
            "bash",
            "scripts/bootstrap.sh",
            "--platform",
            "ubuntu",
            "--profile",
            "desktop",
            "--no-gui",
            "--plan",
            "--skip-system",
            "--skip-ai",
            "--skip-lsps",
            "--skip-checks",
        ],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
        env={**os.environ, "CLOAKBROWSER_BINARY_PATH": "/tmp/unmanaged-browser"},
    )
    assert result.returncode != 0
    assert "forbidden by the signed CloakBrowser trust policy" in result.stdout


def test_browser_managed_file_repairs_mode_and_rejects_marker_substrings(
    tmp_path: Path,
) -> None:
    common_path = ROOT / "scripts/lib/common.sh"
    marker = "# Managed by macos-ubuntu-bootstrap: browser-stack-v1"
    managed = tmp_path / "managed"
    managed_content = f"{marker}\npayload\n"
    managed.write_text(managed_content, encoding="utf-8")
    managed.chmod(0o600)
    script = r"""
source "$1"
export RLDYOUR_DRY_RUN=0
printf '%s' "$CONTENT" | rldyour::_install_managed_browser_file "$2" "$3" 0755
"""
    result = subprocess.run(
        ["bash", "-c", script, "_", str(common_path), str(managed), marker],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "CONTENT": managed_content},
    )
    assert result.returncode == 0, result.stderr
    assert managed.stat().st_mode & 0o777 == 0o755

    unmanaged = tmp_path / "unmanaged"
    original = f"prefix {marker} suffix\nowner data\n"
    unmanaged.write_text(original, encoding="utf-8")
    result = subprocess.run(
        ["bash", "-c", script, "_", str(common_path), str(unmanaged), marker],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "CONTENT": managed_content},
    )
    assert result.returncode != 0
    assert unmanaged.read_text(encoding="utf-8") == original


def test_rtk_artifact_install_is_pinned_and_tamper_evident(tmp_path: Path) -> None:
    payload = tmp_path / "rtk"
    payload.write_text(
        "#!/usr/bin/env bash\nprintf 'rtk 0.43.0\\n'\n", encoding="utf-8"
    )
    payload.chmod(0o755)
    archive = tmp_path / "rtk.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(payload, arcname="rtk")
    sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    fake_curl = fake_bin / "curl"
    fake_curl.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
destination=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) destination=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp "$FAKE_ARCHIVE" "$destination"
""",
        encoding="utf-8",
    )
    fake_curl.chmod(0o755)
    fake_uname = fake_bin / "uname"
    fake_uname.write_text(
        "#!/usr/bin/env bash\n"
        'case "${1:-}" in -s) echo Linux ;; -m) echo x86_64 ;; *) exec /usr/bin/uname "$@" ;; esac\n',
        encoding="utf-8",
    )
    fake_uname.chmod(0o755)

    home = tmp_path / "home"
    home.mkdir()
    interrupted = home / ".local/share/rldyour/rtk/0.43.0"
    interrupted.mkdir(parents=True)
    (interrupted / "rtk.sha256").write_text(
        "# Managed by macos-ubuntu-bootstrap: rtk-v1\n"
        "version=0.43.0\n"
        f"sha256={hashlib.sha256(payload.read_bytes()).hexdigest()}\n",
        encoding="utf-8",
    )
    common_path = ROOT / "scripts/lib/common.sh"
    script = r"""
source "$1"
export RLDYOUR_DRY_RUN=0
rldyour::install_rtk
"""
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "FAKE_ARCHIVE": str(archive),
    }
    # Replace the production hash only inside the sourced test copy so the
    # installer path and receipt behavior are exercised without network access.
    test_common = tmp_path / "common.sh"
    test_common.write_text(
        common_path.read_text(encoding="utf-8").replace(
            "ff8a1e7766496e175291a85aeca1dc97c9ff6df33e51e5893d1fbc78fea2a609",
            sha256,
        ),
        encoding="utf-8",
    )
    result = subprocess.run(
        ["bash", "-c", script, "_", str(test_common)],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0, result.stderr + result.stdout
    launcher = home / ".local/bin/rtk"
    assert (
        subprocess.check_output([launcher, "--version"], text=True).strip()
        == "rtk 0.43.0"
    )

    managed_binary = home / ".local/share/rldyour/rtk/0.43.0/rtk"
    managed_binary.write_bytes(managed_binary.read_bytes() + b"\n# tampered\n")
    result = subprocess.run(
        ["bash", "-c", script, "_", str(test_common)],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode != 0
    assert "binary identity changed" in result.stdout


def test_browser_commands_are_required_in_verifiers() -> None:
    for platform in ("macos", "ubuntu"):
        verify = file(f"scripts/{platform}/verify.sh")
        required = parse_array(verify, "required_cmds")
        for command in (
            "cloak-chromium",
            "cloakbrowser-cdp-health",
            "chrome-devtools-mcp",
            "playwright-cli",
        ):
            assert command in required
        assert "webwright" not in required
        assert "verify-browser-runtime.sh" in verify
    ubuntu_verify = file("scripts/ubuntu/verify.sh")
    assert "tool_host_provenance" in ubuntu_verify
    assert "ubuntu-runtime-v1" in ubuntu_verify
    assert "managed_link" in ubuntu_verify


def test_remote_code_is_never_piped_directly_to_shell() -> None:
    for path in (ROOT / "scripts").rglob("*.sh"):
        body = path.read_text(encoding="utf-8")
        assert not re.search(r"curl[^\n|]*\|\s*(?:ba)?sh", body), path


def test_remote_installers_have_tracked_integrity_roots() -> None:
    macos = file("scripts/macos/install.sh")
    ubuntu = file("scripts/ubuntu/install.sh")
    common = file("scripts/lib/common.sh")
    assert "HOMEBREW_PKG_VERSION=" in macos
    assert "HOMEBREW_PKG_SHA256=" in macos
    assert "pkgutil --check-signature" in macos
    assert "spctl --assess --type install" in macos
    for body in (macos, ubuntu):
        # Removed harness installers stay gone; the streamed Antigravity installer
        # was always forbidden.
        assert "install_antigravity_artifact" not in body
        assert "antigravity.google/cli/install.sh" not in body
    # AGY_CLI_DISABLE_AUTO_UPDATE related to Antigravity and is fully removed;
    # DISABLE_AUTOUPDATER/DISABLE_UPDATES stay to keep the codex harness locked.
    assert "AGY_CLI_DISABLE_AUTO_UPDATE" not in common
    assert "AGY_CLI_DISABLE_AUTO_UPDATE" not in file("templates/terminal/zshenv")
    assert "DISABLE_AUTOUPDATER=1" in file("templates/terminal/zshenv")
    assert "DISABLE_UPDATES=1" in file("templates/terminal/zshenv")
    assert "download_verified_file" in common
    assert "astral.sh/uv/install.sh" not in ubuntu
    assert "bun.sh/install" not in ubuntu
    supply = json.loads(file("config/rldyour-contract.json"))["supply_chain"]
    assert "ai_cli_lock" not in supply
    assert not any("antigravity" in key for key in supply)
    for value in supply.values():
        if isinstance(value, bool):
            continue
        assert str(value) in macos + ubuntu + common or str(value).startswith(
            "templates/"
        )


def test_existing_homebrew_packages_are_never_implicitly_upgraded() -> None:
    macos = file("scripts/macos/install.sh")
    assert "brew upgrade" not in macos
    assert "brew outdated" not in macos
    assert "preserving installed Homebrew formula" in macos
    assert "preserving installed Homebrew cask" in macos
    assert "cask_app_path" in macos
    assert "preserving signed and notarized unmanaged cask destination" in macos
    assert 'codesign --verify --deep --strict "$app_path"' in macos
    assert 'spctl --assess --type execute "$app_path"' in macos
    ensure_cask = re.search(
        r"^ensure_cask\(\) \{(.*?)(?=^\w[^\n]*\(\) \{)",
        macos,
        re.MULTILINE | re.DOTALL,
    )
    assert ensure_cask is not None
    body = ensure_cask.group(1)
    assert body.index('brew list --cask "$cask"') < body.index(
        'brew install --cask "$cask"'
    )
    assert body.index('verify_existing_cask_app "$cask" "$app_path"') < body.index(
        'brew install --cask "$cask"'
    )


def test_versioned_native_artifacts_publish_on_the_destination_filesystem() -> None:
    common = file("scripts/lib/common.sh")
    ubuntu = file("scripts/ubuntu/install.sh")
    assert ".rtk.tmp.XXXXXX" in common
    assert ".node-${NODE_VERSION}.tmp.XXXXXX" in ubuntu
    assert ".uv-${UV_VERSION}.tmp.XXXXXX" in ubuntu
    assert ".bun-${BUN_VERSION}.tmp.XXXXXX" in ubuntu
    assert 'mv "$stage" "$destination"' in ubuntu
    assert "ubuntu-runtime-v1" in ubuntu
    assert "validate_runtime_receipt" in ubuntu
    assert "preflight_managed_link" in ubuntu
    for function_name in ("ensure_node", "ensure_uv", "ensure_bun"):
        match = re.search(
            rf"^{function_name}\(\) \{{(.*?)(?=^\w[^\n]*\(\) \{{)",
            ubuntu,
            re.MULTILINE | re.DOTALL,
        )
        assert match is not None
        assert "command -v" not in match.group(
            1
        ), f"{function_name} must not trust an external PATH version"


def test_auth_handoff_contains_all_manual_boundaries() -> None:
    handoff = file("scripts/auth-handoff.sh")
    for marker in (
        "gh auth login",
        "codex login --device-auth",
        "open ChatGPT.app",
        "open Codex.app",
        "zcode.z.ai",
        "cloakbrowser-cdp-health",
        "Settings → Secrets and variables → Actions",
    ):
        assert marker in handoff
    # Removed harnesses must not linger in the handoff steps.
    for absent in ("claude auth login", "opencode auth login", "agy"):
        assert absent not in handoff
    assert "never reads" in handoff


def test_shell_dropins_preserve_user_files_and_are_idempotent(tmp_path: Path) -> None:
    home = tmp_path / "home"
    home.mkdir()
    zshenv = home / ".zshenv"
    zprofile = home / ".zprofile"
    zshenv.write_text("# owner zshenv\nexport OWNER_VALUE=kept\n", encoding="utf-8")
    zprofile.write_text("# owner zprofile\n", encoding="utf-8")
    zshenv.chmod(0o600)
    script = r"""
source "$1"
export RLDYOUR_DRY_RUN=0
rldyour::install_terminal_configs "$2"
rldyour::install_terminal_configs "$2"
"""
    result = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "_",
            str(ROOT / "scripts/lib/common.sh"),
            str(ROOT / "templates/terminal"),
        ],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "HOME": str(home)},
    )
    assert result.returncode == 0, result.stderr + result.stdout
    assert zshenv.stat().st_mode & 0o777 == 0o600
    assert zshenv.read_text(encoding="utf-8").startswith(
        "# owner zshenv\nexport OWNER_VALUE=kept\n"
    )
    assert (
        zshenv.read_text(encoding="utf-8").count(
            'source "$HOME/.config/rldyour/zshenv"'
        )
        == 1
    )
    assert (
        zprofile.read_text(encoding="utf-8").count(
            'source "$HOME/.config/rldyour/zprofile"'
        )
        == 1
    )
    managed = home / ".config/rldyour/zshenv"
    assert managed.read_text(encoding="utf-8").startswith(
        "# Managed by macos-ubuntu-bootstrap: terminal-zshenv-v1"
    )
    backups = list((home / ".local/share/rldyour/backups/shell").rglob(".zshenv"))
    assert len(backups) == 1
    assert backups[0].read_text(encoding="utf-8") == (
        "# owner zshenv\nexport OWNER_VALUE=kept\n"
    )


def test_ssh_activation_and_reload_preserve_existing_provider(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    log = tmp_path / "systemctl.log"
    systemctl = fake_bin / "systemctl"
    systemctl.write_text(
        r"""#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  is-active)
    [ "${ACTIVE_PROVIDER:-}" = "$3" ] ||
      { [ -f "$SYSTEMCTL_STATE" ] && grep -Fxq "$3" "$SYSTEMCTL_STATE"; }
    ;;
  is-enabled) [ "${ENABLED_PROVIDER:-}" = "$3" ] ;;
  list-unit-files)
    case "${AVAILABLE_PROVIDER:-ssh.service}" in
      ssh.service) printf 'ssh.service enabled\n' ;;
      ssh.socket) printf 'ssh.socket enabled\n' ;;
    esac
    ;;
  enable)
    printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
    printf '%s\n' "${@: -1}" > "$SYSTEMCTL_STATE"
    ;;
  reload) printf '%s\n' "$*" >> "$SYSTEMCTL_LOG" ;;
  *) exit 2 ;;
esac
""",
        encoding="utf-8",
    )
    systemctl.chmod(0o755)
    script = r"""
source "$1"
export RLDYOUR_DRY_RUN=0
rldyour::ubuntu_server::as_root() { "$@"; }
rldyour::ubuntu_server::ensure_ssh_activation
rldyour::ubuntu_server::reload_ssh_authentication
"""
    base_env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "SYSTEMCTL_LOG": str(log),
        "SYSTEMCTL_STATE": str(tmp_path / "systemctl.state"),
    }
    for provider in ("ssh.service", "ssh.socket"):
        log.write_text("", encoding="utf-8")
        result = subprocess.run(
            ["bash", "-c", script, "_", str(ROOT / "scripts/ubuntu/server.sh")],
            check=False,
            capture_output=True,
            text=True,
            env={**base_env, "ACTIVE_PROVIDER": provider},
        )
        assert result.returncode == 0, result.stderr + result.stdout
        calls = log.read_text(encoding="utf-8")
        if provider == "ssh.service":
            assert calls == "reload ssh.service\n"
        else:
            assert calls == ""

    log.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", "-c", script, "_", str(ROOT / "scripts/ubuntu/server.sh")],
        check=False,
        capture_output=True,
        text=True,
        env={**base_env, "ENABLED_PROVIDER": "ssh.socket"},
    )
    assert result.returncode == 0, result.stderr + result.stdout
    assert log.read_text(encoding="utf-8") == "enable --now ssh.socket\n"


def test_ssh_port_detection_uses_privileged_read_only_probe() -> None:
    script = r"""
source "$1"
systemctl() { return 1; }
sshd() { return 0; }
rldyour::ubuntu_server::probe_as_root() {
  [ "$1 $2" = "sshd -T" ] || exit 9
  printf 'port 2202\n'
}
rldyour::ubuntu_server::detect_ssh_port
"""
    result = subprocess.run(
        ["bash", "-c", script, "_", str(ROOT / "scripts/ubuntu/server.sh")],
        check=False,
        capture_output=True,
        text=True,
        env=os.environ,
    )
    assert result.returncode == 0, result.stderr + result.stdout
    assert result.stdout.strip() == "2202"


def test_browser_owned_templates_and_files_are_preserved_fail_closed() -> None:
    common = file("scripts/lib/common.sh")
    assert "unmanaged browser file differs; preserved" in common
    assert "browser provider home exists without a management marker" in common
    assert "stock Chromium" in common


def test_no_gui_mode_is_distinct_from_server_role() -> None:
    bootstrap = file("scripts/bootstrap.sh")
    macos = file("scripts/macos/install.sh")
    assert "export RLDYOUR_GUI_ENABLED=1" in bootstrap
    assert "export RLDYOUR_GUI_ENABLED=0" in bootstrap
    assert 'RLDYOUR_LOCAL_EXECUTION_POLICY="source-lsp-only"' in bootstrap
    assert 'RLDYOUR_LOCAL_EXECUTION_POLICY="container-execution-only"' in bootstrap
    install_gui = re.search(
        r"^install_gui_apps\(\) \{(.*?)(?=^\w[^\n]*\(\) \{)",
        macos,
        re.MULTILINE | re.DOTALL,
    )
    assert install_gui is not None
    body = install_gui.group(1)
    assert body.index('if [ "$GUI_ENABLED" -ne 1 ]; then') < body.index(
        'for cask in "${GUI_CASKS[@]}"'
    )
    assert "codex-app" in parse_array(macos, "GUI_CASKS")
    assert "for app in Ghostty cmux ChatGPT Codex Claude" in file(
        "scripts/macos/verify.sh"
    )
    assert 'for agent in codex; do' in macos
    assert 'cmux hooks "$agent" install --yes' in macos
    assert "cmux hooks setup" not in macos
    assert "opencode" not in macos
    assert "antigravity" not in macos


def test_reusable_ci_is_pinned_to_current_ci_workflows_release() -> None:
    expected = "ac4d1f469f5974741c7449305ffcbd5f05a5a47f"
    found = 0
    for workflow in (ROOT / ".github" / "workflows").glob("*.yml"):
        body = workflow.read_text(encoding="utf-8")
        for sha in re.findall(
            r"NDDev-it-com/nddev-ci-workflows/[^@\s]+@([0-9a-f]{40})", body
        ):
            found += 1
            assert sha == expected, f"{workflow.name} has stale central CI pin {sha}"
    assert found >= 8


def test_hosted_workflows_provision_local_validator_prerequisites() -> None:
    for workflow in (
        ".github/workflows/ci.yml",
        ".github/workflows/validate.yml",
        ".github/workflows/release.yml",
    ):
        body = file(workflow)
        assert "ripgrep" in body, f"{workflow} must provision rg explicitly"
    for workflow in (".github/workflows/pytest.yml", ".github/workflows/release.yml"):
        body = file(workflow)
        assert (
            "zsh" in body
        ), f"{workflow} must provision zsh for terminal portability tests"


def test_raven_actionlint_uses_no_unsupported_args_input() -> None:
    found = 0
    for workflow in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        lines = workflow.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if "uses: raven-actions/actionlint@" not in line:
                continue
            found += 1
            use_indent = len(line) - len(line.lstrip())
            nested_lines = []
            for nested in lines[index + 1 :]:
                if nested.strip() and len(nested) - len(nested.lstrip()) < use_indent:
                    break
                nested_lines.append(nested)
            assert not any(
                re.match(r"^\s*args\s*:", nested) for nested in nested_lines
            ), f"{workflow.name} passes unsupported args to raven actionlint"
    assert found > 0


def test_dependency_check_enforces_one_owner_per_harness_delegation() -> None:
    workflow = file(".github/workflows/dependency-check.yml")
    assert "one-owner-per-harness delegation" in workflow
    assert "rldyour::install_selected_harnesses" in workflow
    assert "RLDYOUR_CODEX_MODULE" in workflow
    assert "RLDYOUR_ZCODE_MODULE" in workflow
    assert "the frozen AI-CLI bundle template must be removed" in workflow
    assert "streamed installer is forbidden" in workflow


def test_release_keeps_numeric_tag_push_path() -> None:
    release = file(".github/workflows/release.yml")
    assert 'tags:\n      - "[0-9]+.[0-9]+.[0-9]+"' in release
    assert "RELEASE_REF_NAME: ${{ github.ref_name }}" in release
    assert "RELEASE_REF_TYPE: ${{ github.ref_type }}" in release
    assert '[ "$RELEASE_REF_TYPE" = "tag" ]' in release


def test_release_manual_dispatch_requires_existing_safe_exact_tag() -> None:
    release = file(".github/workflows/release.yml")
    assert "workflow_dispatch:" in release
    assert "inputs:\n      version:" in release
    assert "RELEASE_INPUT_VERSION: ${{ inputs.version }}" in release
    input_lines = [
        line.strip() for line in release.splitlines() if "${{ inputs.version }}" in line
    ]
    assert input_lines == ["RELEASE_INPUT_VERSION: ${{ inputs.version }}"]
    assert (
        "group: release-${{ github.workflow }}-${{ inputs.version || github.ref_name }}"
        in release
    )
    assert "without leading zeros" in release
    assert "manual release must dispatch the exact origin/main commit" in release
    assert "check_name=bootstrap-gate&status=completed" in release
    assert "verify-tag:\n    name: Verify exact manual release tag" in release
    assert "checks: read\n      contents: read" in release
    assert "persist-credentials: false" in release
    assert "persist-credentials: true" not in release
    assert "Require existing exact release tag" in release
    assert "root automation creates tags" in release
    assert 'git tag "$RELEASE_VERSION"' not in release
    assert "git push origin" not in release
    assert 'git rev-parse --verify "${tag_ref}^{commit}"' in release
    assert "existing tag '$RELEASE_VERSION' points to a different commit" in release
    assert "needs: [resolve, verify-tag]" in release
    assert "needs.verify-tag.result == 'skipped'" in release
    assert "--force" not in release
    assert "gh release create" in release
    assert "--verify-tag" in release
