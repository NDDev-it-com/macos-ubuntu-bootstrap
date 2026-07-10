import hashlib
import json
import os
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
AI_VERSIONS = ("2.1.206", "0.144.1", "1.17.18", "0.1.5")


def write_executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def runtime_fixture(tmp_path: Path) -> Path:
    fixture = tmp_path / "fixture"
    (fixture / "scripts/lib").mkdir(parents=True)
    shutil.copy2(ROOT / "scripts/lib/common.sh", fixture / "scripts/lib/common.sh")
    shutil.copytree(ROOT / "templates/ai-cli", fixture / "templates/ai-cli")
    shutil.copytree(ROOT / "templates/browser", fixture / "templates/browser")
    return fixture


def run_bash(
    fixture: Path,
    home: Path,
    fake_bin: Path,
    body: str,
    *,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "FIXTURE": str(fixture),
            "HOME": str(home),
            "PATH": f"{fake_bin}:{env['PATH']}",
            "REAL_PYTHON": sys.executable,
            "RLDYOUR_DRY_RUN": "0",
        }
    )
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", "-c", f'source "$FIXTURE/scripts/lib/common.sh"\n{body}'],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def install_fake_bun(fake_bin: Path) -> None:
    write_executable(
        fake_bin / "bun",
        r"""
        #!/usr/bin/env bash
        set -euo pipefail
        cwd=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--cwd" ]; then
            cwd=$2
            shift 2
          else
            shift
          fi
        done
        [ -n "$cwd" ] || exit 64
        printf '%s\n' "$cwd" >>"${FAKE_BUN_LOG:?}"
        [ "${FAKE_BUN_FAIL:-0}" -eq 0 ] || exit 71

        mkdir -p \
          "$cwd/node_modules/.bin" \
          "$cwd/node_modules/opencode-darwin-arm64/bin" \
          "$cwd/node_modules/opencode-linux-arm64/bin" \
          "$cwd/node_modules/opencode-linux-x64/bin" \
          "$cwd/node_modules/opencode-linux-x64-baseline/bin" \
          "$cwd/node_modules/chrome-devtools-mcp" \
          "$cwd/node_modules/@playwright/cli"

        make_version_provider() {
          provider=$1
          version=$2
          printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$version" >"$provider"
          chmod 0755 "$provider"
        }
        make_version_provider "$cwd/node_modules/.bin/claude" '2.1.206 (Claude Code)'
        make_version_provider "$cwd/node_modules/.bin/codex" 'codex-cli 0.144.1'
        make_version_provider "$cwd/node_modules/.bin/mimo" '0.1.5'
        for provider in \
          "$cwd/node_modules/opencode-darwin-arm64/bin/opencode" \
          "$cwd/node_modules/opencode-linux-arm64/bin/opencode" \
          "$cwd/node_modules/opencode-linux-x64/bin/opencode" \
          "$cwd/node_modules/opencode-linux-x64-baseline/bin/opencode"; do
          make_version_provider "$provider" '1.17.18'
        done

        cat >"$cwd/node_modules/chrome-devtools-mcp/package.json" <<'JSON'
        {"version":"1.5.0"}
        JSON
        cat >"$cwd/node_modules/@playwright/cli/package.json" <<'JSON'
        {"version":"0.1.17"}
        JSON
        cat >"$cwd/node_modules/.bin/chrome-devtools-mcp" <<'PROVIDER'
        #!/usr/bin/env bash
        printf 'chrome usage=%s updates=%s args=' "${CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS:-}" "${CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS:-}" >>"${FAKE_PROVIDER_LOG:?}"
        printf '<%s>' "$@" >>"$FAKE_PROVIDER_LOG"
        printf '\n' >>"$FAKE_PROVIDER_LOG"
        PROVIDER
        cat >"$cwd/node_modules/.bin/playwright-cli" <<'PROVIDER'
        #!/usr/bin/env bash
        printf 'playwright notifier=%s args=' "${NO_UPDATE_NOTIFIER:-}" >>"${FAKE_PROVIDER_LOG:?}"
        printf '<%s>' "$@" >>"$FAKE_PROVIDER_LOG"
        printf '\n' >>"$FAKE_PROVIDER_LOG"
        PROVIDER
        chmod 0755 "$cwd/node_modules/.bin/chrome-devtools-mcp" "$cwd/node_modules/.bin/playwright-cli"
        """,
    )


def install_fake_uv(fake_bin: Path) -> None:
    write_executable(
        fake_bin / "uv",
        r"""
        #!/usr/bin/env bash
        set -euo pipefail
        printf 'PYTHONPATH=%s PYTHONHOME=%s args=' "${PYTHONPATH-unset}" "${PYTHONHOME-unset}" >>"${FAKE_UV_LOG:?}"
        printf '<%s>' "$@" >>"$FAKE_UV_LOG"
        printf '\n' >>"$FAKE_UV_LOG"
        [ "${FAKE_UV_FAIL:-0}" -eq 0 ] || exit 72
        venv=${UV_PROJECT_ENVIRONMENT:?}
        mkdir -p "$venv/bin"
        cat >"$venv/bin/python" <<'PYTHON'
        #!/usr/bin/env bash
        set -euo pipefail
        printf 'PYTHONPATH=%s PYTHONHOME=%s args=' "${PYTHONPATH-unset}" "${PYTHONHOME-unset}" >>"${FAKE_PYTHON_LOG:?}"
        printf '<%s>' "$@" >>"$FAKE_PYTHON_LOG"
        printf '\n' >>"$FAKE_PYTHON_LOG"
        case "$*" in
          *'from importlib.metadata import version; import cloakbrowser;'*)
            printf '%s\n' '0.4.10'
            exit 0
            ;;
        esac
        if [ "${1:-}" = -I ] && [ "${2:-}" = - ]; then
          shift 2
          code=$(cat)
          case "$code" in
            *'from cloakbrowser import ensure_binary'*)
              printf '%s\n' "${FAKE_CLOAK_BINARY:?}"
              exit 0
              ;;
          esac
          exec "${REAL_PYTHON:?}" -I -c "$code" "$@"
        fi
        exec "${REAL_PYTHON:?}" "$@"
        PYTHON
        chmod 0755 "$venv/bin/python"
        """,
    )


def install_fake_git(fake_bin: Path) -> None:
    write_executable(
        fake_bin / "git",
        r"""
        #!/usr/bin/env bash
        set -euo pipefail
        printf '<%s>' "$@" >>"${FAKE_GIT_LOG:?}"
        printf '\n' >>"$FAKE_GIT_LOG"
        if [ "${1:-}" = clone ]; then
          [ "${FAKE_GIT_FAIL:-0}" -eq 0 ] || exit 73
          previous=""
          current=""
          for argument in "$@"; do
            previous=$current
            current=$argument
          done
          repo=$previous
          checkout=$current
          mkdir -p "$checkout/.git" "$checkout/src/webwright/environments" "$checkout/src/webwright/config" "$checkout/src/webwright/run"
          printf '%s\n' "$repo" >"$checkout/.git/origin"
          : >"$checkout/src/webwright/__init__.py"
          : >"$checkout/src/webwright/run/__init__.py"
          : >"$checkout/src/webwright/run/cli.py"
          printf '%s\n' 'local_cdp_auto_start = False' >"$checkout/src/webwright/environments/local_browser.py"
          for config in base.yaml local_browser.yaml model_openai.yaml; do
            printf '%s\n' 'managed: true' >"$checkout/src/webwright/config/$config"
          done
          exit 0
        fi
        [ "${1:-}" = -C ] || exit 64
        checkout=$2
        shift 2
        command_name=$1
        shift
        case "$command_name" in
          remote)
            cat "$checkout/.git/origin"
            ;;
          fetch)
            [ "${FAKE_GIT_FAIL:-0}" -eq 0 ] || exit 73
            ;;
          checkout)
            pin=""
            for argument in "$@"; do pin=$argument; done
            printf '%s\n' "$pin" >"$checkout/.git/head"
            ;;
          rev-parse)
            cat "$checkout/.git/head"
            ;;
          symbolic-ref)
            exit 1
            ;;
          status)
            ;;
          *)
            exit 64
            ;;
        esac
        """,
    )


def visible_runtimes(path: Path) -> list[Path]:
    return sorted(item for item in path.iterdir() if not item.name.startswith("."))


def install_verified_cloak_receipt(home: Path) -> Path:
    cloak_home = home / ".local/share/rldyour/cloakbrowser"
    binary = cloak_home / "cache/chromium-test/chrome"
    write_executable(binary, "#!/usr/bin/env bash\nexit 0\n")
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt = cloak_home / ".verified-binary"
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(
        "# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1\n"
        "package=cloakbrowser@0.4.10\n"
        f"path={binary}\n"
        f"sha256={digest}\n",
        encoding="utf-8",
    )
    return binary


def test_wrapper_set_publish_rolls_back_after_mid_set_rename_failure(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    destination = home / ".local/bin"
    stage = destination / ".wrapper-stage"
    stage.mkdir(parents=True)
    marker = "# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1"
    names = ("chrome-devtools-mcp", "playwright-cli", "webwright")
    for name in names:
        write_executable(destination / name, f"#!/usr/bin/env bash\n{marker}\nprintf '%s\\n' old-{name}\n")
        write_executable(stage / name, f"#!/usr/bin/env bash\n{marker}\nprintf '%s\\n' new-{name}\n")
    before = {name: (destination / name).read_bytes() for name in names}

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "mv",
        r"""
        #!/usr/bin/env bash
        set -euo pipefail
        count=0
        [ ! -f "${FAKE_MV_COUNT:?}" ] || count=$(cat "$FAKE_MV_COUNT")
        count=$((count + 1))
        printf '%s\n' "$count" >"$FAKE_MV_COUNT"
        [ "$count" -ne 2 ] || exit 74
        exec /bin/mv "$@"
        """,
    )
    result = run_bash(
        fixture,
        home,
        fake_bin,
        r'''
          if rldyour::_publish_managed_wrapper_set \
            "$HOME/.local/bin/.wrapper-stage" "$HOME/.local/bin" \
            '# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1' \
            chrome-devtools-mcp playwright-cli webwright; then
            exit 99
          fi
        ''',
        extra_env={"FAKE_MV_COUNT": str(tmp_path / "mv.count")},
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert before == {name: (destination / name).read_bytes() for name in names}
    assert not stage.exists()


@pytest.mark.parametrize("tool", ("antigravity", "rtk"))
@pytest.mark.parametrize("unsafe_state", ("namespace-symlink", "dangling-destination"))
def test_native_artifact_installers_reject_unsafe_managed_paths_before_download(
    tmp_path: Path, tool: str, unsafe_state: str
) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    download_log = tmp_path / "download.log"
    write_executable(
        fake_bin / "curl",
        """
        #!/usr/bin/env bash
        printf '%s\\n' called >"$DOWNLOAD_LOG"
        exit 77
        """,
    )
    namespace = home / f".local/share/rldyour/{tool}"
    version = "1.1.0" if tool == "antigravity" else "0.43.0"
    binary_name = "agy" if tool == "antigravity" else "rtk"
    if unsafe_state == "namespace-symlink":
        namespace.parent.mkdir(parents=True)
        external = tmp_path / "external-owner-data"
        external.mkdir()
        namespace.symlink_to(external, target_is_directory=True)
    else:
        version_dir = namespace / version
        version_dir.mkdir(parents=True)
        (version_dir / binary_name).symlink_to(tmp_path / "missing-unmanaged-target")
    command = (
        "rldyour::install_antigravity_artifact 1.1.0 https://example.invalid/agy.tgz "
        + "0" * 128
        if tool == "antigravity"
        else "rldyour::install_rtk"
    )
    result = run_bash(
        fixture,
        home,
        fake_bin,
        command,
        extra_env={"DOWNLOAD_LOG": str(download_log)},
    )
    assert result.returncode != 0
    assert not download_log.exists()


def test_ai_bundle_is_idempotent_and_bun_failure_preserves_runtime_and_wrappers(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    install_fake_bun(fake_bin)
    bun_log = tmp_path / "bun.log"
    provider_log = tmp_path / "provider.log"
    env = {"FAKE_BUN_LOG": str(bun_log), "FAKE_PROVIDER_LOG": str(provider_log)}
    command = 'rldyour::install_ai_cli_bundle "2.1.206" "0.144.1" "1.17.18" "0.1.5"'

    first = run_bash(fixture, home, fake_bin, command, extra_env=env)
    assert first.returncode == 0, first.stdout + first.stderr
    wrappers = home / ".local/bin"
    before = {name: (wrappers / name).read_bytes() for name in ("claude", "codex", "opencode", "mimo")}
    runtimes = home / ".local/share/rldyour/ai-cli/runtimes"
    first_runtime = visible_runtimes(runtimes)
    assert len(first_runtime) == 1
    assert len(bun_log.read_text(encoding="utf-8").splitlines()) == 1

    second = run_bash(
        fixture,
        home,
        fake_bin,
        command,
        extra_env={**env, "FAKE_BUN_FAIL": "1"},
    )
    assert second.returncode == 0, second.stdout + second.stderr
    assert len(bun_log.read_text(encoding="utf-8").splitlines()) == 1
    assert before == {name: (wrappers / name).read_bytes() for name in before}

    lock = fixture / "templates/ai-cli/bun.lock"
    lock.write_text(lock.read_text(encoding="utf-8") + "\n# fault-injection\n", encoding="utf-8")
    failed_upgrade = run_bash(
        fixture,
        home,
        fake_bin,
        command,
        extra_env={**env, "FAKE_BUN_FAIL": "1"},
    )
    assert failed_upgrade.returncode != 0
    assert before == {name: (wrappers / name).read_bytes() for name in before}
    assert visible_runtimes(runtimes) == first_runtime
    assert not list(runtimes.glob(".*.staging.*"))


def test_ai_bundle_rejects_unmanaged_namespace_without_running_bun(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    unmanaged = home / ".local/share/rldyour/ai-cli"
    unmanaged.mkdir(parents=True)
    sentinel = unmanaged / "owner-data"
    sentinel.write_text("preserve\n", encoding="utf-8")
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    install_fake_bun(fake_bin)
    result = run_bash(
        fixture,
        home,
        fake_bin,
        'rldyour::install_ai_cli_bundle "2.1.206" "0.144.1" "1.17.18" "0.1.5"',
        extra_env={
            "FAKE_BUN_LOG": str(tmp_path / "bun.log"),
            "FAKE_PROVIDER_LOG": str(tmp_path / "provider.log"),
        },
    )
    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "preserve\n"
    assert not (tmp_path / "bun.log").exists()


def test_policy_python_ignores_poisoned_pythonpath_for_legacy_ownership(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    poison = tmp_path / "poison"
    poison.mkdir()
    poison_log = tmp_path / "poison-imported"
    (poison / "plistlib.py").write_text(
        "import os\n"
        "open(os.environ['POISON_LOG'], 'w').write('imported')\n"
        "class AnyValue:\n"
        "    def __eq__(self, other): return True\n"
        "def loads(data): return AnyValue()\n",
        encoding="utf-8",
    )
    unmanaged = tmp_path / "owner-unmanaged-do-not-touch.plist"
    unmanaged.write_text("arbitrary owner data\n", encoding="utf-8")
    result = run_bash(
        fixture,
        home,
        fake_bin,
        r'''
          if rldyour::_is_legacy_cloak_service_file launchd \
            "$UNMANAGED" "$HOME/.local/bin" "$HOME/cloak" "$HOME/profile" macos 9222; then
            exit 99
          fi
        ''',
        extra_env={
            "POISON_LOG": str(poison_log),
            "PYTHONHOME": str(poison),
            "PYTHONPATH": str(poison),
            "UNMANAGED": str(unmanaged),
        },
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert unmanaged.read_text(encoding="utf-8") == "arbitrary owner data\n"
    assert not poison_log.exists()


def test_browser_node_bundle_is_transactional_and_disables_detached_checks(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    install_fake_bun(fake_bin)
    bun_log = tmp_path / "bun.log"
    provider_log = tmp_path / "provider.log"
    env = {"FAKE_BUN_LOG": str(bun_log), "FAKE_PROVIDER_LOG": str(provider_log)}
    command = r'''
      rldyour::_install_browser_node_bundle \
        1.5.0 0.1.17 "$HOME/browser" \
        "$FIXTURE/templates/browser/provider/package.json" \
        "$FIXTURE/templates/browser/provider/bun.lock" chrome_result playwright_result || exit
      printf '%s\n%s\n' "$chrome_result" "$playwright_result"
    '''

    first = run_bash(fixture, home, fake_bin, command, extra_env=env)
    assert first.returncode == 0, first.stdout + first.stderr
    runtime_paths = first.stdout.strip().splitlines()[-2:]
    assert all(Path(path).is_file() for path in runtime_paths)
    assert "chrome usage=1 updates=1" in provider_log.read_text(encoding="utf-8")
    runtimes = home / "browser/node-runtimes"
    first_runtime = visible_runtimes(runtimes)

    second = run_bash(
        fixture,
        home,
        fake_bin,
        command,
        extra_env={**env, "FAKE_BUN_FAIL": "1"},
    )
    assert second.returncode == 0, second.stdout + second.stderr
    assert len(bun_log.read_text(encoding="utf-8").splitlines()) == 1

    lock = fixture / "templates/browser/provider/bun.lock"
    lock.write_text(lock.read_text(encoding="utf-8") + "\n# fault-injection\n", encoding="utf-8")
    failed_upgrade = run_bash(
        fixture,
        home,
        fake_bin,
        command,
        extra_env={**env, "FAKE_BUN_FAIL": "1"},
    )
    assert failed_upgrade.returncode != 0
    assert visible_runtimes(runtimes) == first_runtime
    assert all(Path(path).is_file() for path in runtime_paths)
    assert not list(runtimes.glob(".*.staging.*"))


def test_cloak_runtime_isolated_uv_failure_preserves_previous_runtime(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    install_fake_uv(fake_bin)
    uv_log = tmp_path / "uv.log"
    python_log = tmp_path / "python.log"
    env = {
        "FAKE_UV_LOG": str(uv_log),
        "FAKE_PYTHON_LOG": str(python_log),
        "PYTHONPATH": "poisoned-pythonpath",
        "PYTHONHOME": "poisoned-pythonhome",
    }
    command = r'''
      rldyour::_install_cloak_runtime 0.4.10 "$HOME/cloak" \
        "$FIXTURE/templates/browser" runtime_result || exit
      printf '%s\n' "$runtime_result"
    '''

    first = run_bash(fixture, home, fake_bin, command, extra_env=env)
    assert first.returncode == 0, first.stdout + first.stderr
    published = Path(first.stdout.strip().splitlines()[-1])
    assert published.is_dir()
    assert "PYTHONPATH=unset PYTHONHOME=unset" in uv_log.read_text(encoding="utf-8")
    python_probes = python_log.read_text(encoding="utf-8")
    assert "PYTHONPATH=unset PYTHONHOME=unset" in python_probes
    assert "<-I>" in python_probes

    second = run_bash(
        fixture,
        home,
        fake_bin,
        command,
        extra_env={**env, "FAKE_UV_FAIL": "1"},
    )
    assert second.returncode == 0, second.stdout + second.stderr
    assert len(uv_log.read_text(encoding="utf-8").splitlines()) == 1

    wrapper = home / ".local/bin/cloak-chromium"
    wrapper.parent.mkdir(parents=True)
    wrapper.write_text("# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1\nold\n", encoding="utf-8")
    before_wrapper = wrapper.read_bytes()
    marker = home / "cloak/.rldyour-browser-stack"
    marker.write_text(
        "# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1\n"
        "# This dedicated directory may be updated only by the browser bootstrap layer.\n",
        encoding="utf-8",
    )
    lock = fixture / "templates/browser/cloakbrowser-uv.lock"
    lock.write_text(lock.read_text(encoding="utf-8") + "\n# fault-injection\n", encoding="utf-8")
    failed_upgrade = run_bash(
        fixture,
        home,
        fake_bin,
        "rldyour::install_cloakbrowser",
        extra_env={**env, "FAKE_UV_FAIL": "1"},
    )
    assert failed_upgrade.returncode != 0
    assert published.is_dir()
    assert wrapper.read_bytes() == before_wrapper
    assert not list((home / "cloak/runtimes").glob(".*.staging.*"))


def test_cloak_install_rejects_symlinked_cache_before_uv_or_download(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    uv_log = tmp_path / "uv-called"
    write_executable(fake_bin / "uv", f"#!/usr/bin/env bash\nprintf called >'{uv_log}'\nexit 77\n")
    cloak_home = home / ".local/share/rldyour/cloakbrowser"
    cloak_home.mkdir(parents=True)
    (cloak_home / ".rldyour-browser-stack").write_text(
        "# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1\n",
        encoding="utf-8",
    )
    external = tmp_path / "external-cache"
    external.mkdir()
    sentinel = external / "owner-data"
    sentinel.write_text("preserve\n", encoding="utf-8")
    (cloak_home / "cache").symlink_to(external, target_is_directory=True)
    result = run_bash(fixture, home, fake_bin, "rldyour::install_cloakbrowser")
    assert result.returncode != 0
    assert not uv_log.exists()
    assert sentinel.read_text(encoding="utf-8") == "preserve\n"


def test_deferred_daemon_rollback_restores_linger_through_sudo(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    linger_state = tmp_path / "linger.state"
    linger_state.write_text("yes\n", encoding="utf-8")
    sudo_log = tmp_path / "sudo.log"
    write_executable(
        fake_bin / "loginctl",
        r"""
        #!/usr/bin/env bash
        set -euo pipefail
        command_name=$1
        shift
        case "$command_name" in
          show-user) cat "$FAKE_LINGER_STATE" ;;
          enable-linger|disable-linger)
            [ "${FAKE_LINGER_PRIVILEGED:-0}" = 1 ] || exit 77
            if [ "$command_name" = enable-linger ]; then
              printf '%s\n' yes >"$FAKE_LINGER_STATE"
            else
              printf '%s\n' no >"$FAKE_LINGER_STATE"
            fi
            ;;
          *) exit 64 ;;
        esac
        """,
    )
    write_executable(
        fake_bin / "sudo",
        r"""
        #!/usr/bin/env bash
        set -euo pipefail
        printf '<%s>' "$@" >>"$FAKE_SUDO_LOG"
        printf '\n' >>"$FAKE_SUDO_LOG"
        [ "${1:-}" = -n ] || exit 64
        shift
        FAKE_LINGER_PRIVILEGED=1 exec "$@"
        """,
    )

    result = run_bash(
        fixture,
        home,
        fake_bin,
        r'''
          rldyour::_rollback_cloak_service_handoff() { return 0; }
          RLDYOUR_CLOAK_DAEMON_TX_KIND=systemd
          RLDYOUR_CLOAK_DAEMON_TX_FILE=/unused/unit
          RLDYOUR_CLOAK_DAEMON_TX_SNAPSHOT=
          RLDYOUR_CLOAK_DAEMON_TX_PRIOR_PRESENT=0
          RLDYOUR_CLOAK_DAEMON_TX_PRIOR_ACTIVE=0
          RLDYOUR_CLOAK_DAEMON_TX_PRIOR_ENABLED=0
          RLDYOUR_CLOAK_DAEMON_TX_PRIOR_LINGER=0
          RLDYOUR_CLOAK_DAEMON_TX_DOMAIN=
          rldyour::rollback_cloak_daemon_handoff
        ''',
        extra_env={
            "FAKE_LINGER_STATE": str(linger_state),
            "FAKE_SUDO_LOG": str(sudo_log),
        },
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert linger_state.read_text(encoding="utf-8").strip() == "no"
    assert "<disable-linger>" in sudo_log.read_text(encoding="utf-8")


@pytest.mark.parametrize("failure_mode", ("restart", "health", "inactive-restart", "linger"))
def test_cloak_systemd_handoff_failure_restores_prior_unit_and_active_state(
    tmp_path: Path, failure_mode: str
) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "uname",
        """
        #!/usr/bin/env bash
        case "${1:-}" in
          -s) printf '%s\\n' Linux ;;
          -m) printf '%s\\n' x86_64 ;;
          *) printf '%s\\n' Linux ;;
        esac
        """,
    )
    write_executable(fake_bin / "sleep", "#!/usr/bin/env bash\nexit 0\n")
    write_executable(
        fake_bin / "loginctl",
        r"""
        #!/usr/bin/env bash
        set -euo pipefail
        command_name=$1
        shift
        case "$command_name" in
          show-user) cat "$FAKE_LINGER_STATE" ;;
          enable-linger)
            [ "$FAKE_SERVICE_FAILURE" != linger ] || exit 76
            printf '%s\n' yes >"$FAKE_LINGER_STATE"
            ;;
          disable-linger) printf '%s\n' no >"$FAKE_LINGER_STATE" ;;
          *) exit 64 ;;
        esac
        """,
    )
    write_executable(
        fake_bin / "systemctl",
        r"""
        #!/usr/bin/env bash
        set -euo pipefail
        [ "${1:-}" = --user ] || exit 64
        shift
        command_name=$1
        shift
        printf '<%s>' "$command_name" "$@" >>"${FAKE_SYSTEMCTL_LOG:?}"
        printf '\n' >>"$FAKE_SYSTEMCTL_LOG"
        case "$command_name" in
          is-active)
            [ "$(cat "$FAKE_ACTIVE_STATE")" = active ]
            ;;
          is-enabled)
            [ "$(cat "$FAKE_ENABLED_STATE")" = enabled ]
            ;;
          daemon-reload)
            ;;
          enable)
            printf '%s\n' enabled >"$FAKE_ENABLED_STATE"
            ;;
          disable)
            printf '%s\n' disabled >"$FAKE_ENABLED_STATE"
            ;;
          stop)
            printf '%s\n' inactive >"$FAKE_ACTIVE_STATE"
            ;;
          start)
            printf '%s\n' active >"$FAKE_ACTIVE_STATE"
            ;;
          restart)
            printf '%s\n' inactive >"$FAKE_ACTIVE_STATE"
            [ "$FAKE_SERVICE_FAILURE" != restart ] || exit 75
            printf '%s\n' active >"$FAKE_ACTIVE_STATE"
            ;;
          *)
            exit 64
            ;;
        esac
        """,
    )
    bin_dir = home / ".local/bin"
    write_executable(bin_dir / "cloak-chromium", "#!/usr/bin/env bash\nexit 0\n")
    write_executable(
        bin_dir / "cloakbrowser-cdp-health",
        """
        #!/usr/bin/env bash
        [ "$FAKE_SERVICE_FAILURE" != health ]
        """,
    )
    install_verified_cloak_receipt(home)
    prior_binary = home / ".local/share/rldyour/cloakbrowser/cache/chromium-prior/chrome"
    write_executable(prior_binary, "#!/usr/bin/env bash\nexit 23\n")
    prior_sha256 = hashlib.sha256(prior_binary.read_bytes()).hexdigest()
    unit = home / ".config/systemd/user/rldyour-cloakbrowser.service"
    profile = home / ".local/share/rldyour/cloakbrowser/daemon-profile"
    stable_old_unit = (
        "# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1\n"
        "[Unit]\nDescription=prior working unit\n"
        "[Service]\n"
        f'ExecStart="{bin_dir / "cloak-chromium"}" --headless=new '
        "--remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 "
        f'"--user-data-dir={profile}" --no-first-run --no-default-browser-check '
        "--fingerprint-platform=linux\n"
    )
    expected_stable_rollback = stable_old_unit.replace(
        "# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1",
        "# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1\n"
        f"# rldyour-binary-sha256={prior_sha256}",
    ).replace(str(bin_dir / "cloak-chromium"), str(prior_binary))
    if failure_mode == "inactive-restart":
        old_unit = expected_stable_rollback
        expected_rollback_unit = old_unit
    else:
        old_unit = stable_old_unit
        expected_rollback_unit = expected_stable_rollback
    unit.parent.mkdir(parents=True)
    unit.write_text(old_unit, encoding="utf-8")
    active_state = tmp_path / "active.state"
    enabled_state = tmp_path / "enabled.state"
    linger_state = tmp_path / "linger.state"
    prior_active = "inactive" if failure_mode == "inactive-restart" else "active"
    active_state.write_text(f"{prior_active}\n", encoding="utf-8")
    enabled_state.write_text("enabled\n", encoding="utf-8")
    linger_state.write_text("no\n", encoding="utf-8")
    systemctl_log = tmp_path / "systemctl.log"
    effective_failure = "restart" if failure_mode == "inactive-restart" else failure_mode

    result = run_bash(
        fixture,
        home,
        fake_bin,
        r'''
          rldyour::_active_cloak_service_binary() {
            printf -v "$5" '%s' "$FAKE_PRIOR_BINARY"
            printf -v "$6" '%s' "$FAKE_PRIOR_SHA256"
          }
          rldyour::install_cloakbrowser_daemon
        ''',
        extra_env={
            "FAKE_ACTIVE_STATE": str(active_state),
            "FAKE_ENABLED_STATE": str(enabled_state),
            "FAKE_LINGER_STATE": str(linger_state),
            "FAKE_SERVICE_FAILURE": effective_failure,
            "FAKE_SYSTEMCTL_LOG": str(systemctl_log),
            "FAKE_PRIOR_BINARY": str(prior_binary),
            "FAKE_PRIOR_SHA256": prior_sha256,
            "RLDYOUR_PROFILE": "server",
        },
    )
    assert result.returncode != 0
    assert unit.read_text(encoding="utf-8") == expected_rollback_unit
    assert str(bin_dir / "cloak-chromium") not in unit.read_text(encoding="utf-8")
    assert str(prior_binary) in unit.read_text(encoding="utf-8")
    assert prior_sha256 in unit.read_text(encoding="utf-8")
    assert active_state.read_text(encoding="utf-8").strip() == prior_active
    assert enabled_state.read_text(encoding="utf-8").strip() == "enabled"
    assert linger_state.read_text(encoding="utf-8").strip() == "no"
    assert not list((home / ".local/share/rldyour/cloakbrowser").glob(".*service-snapshot.*"))
    calls = systemctl_log.read_text(encoding="utf-8")
    assert "<stop><rldyour-cloakbrowser.service>" in calls
    assert "<daemon-reload>" in calls
    assert "<enable><rldyour-cloakbrowser.service>" in calls
    if prior_active == "active":
        assert "<start><rldyour-cloakbrowser.service>" in calls


def test_cloak_launchd_bootstrap_failure_restores_prior_plist_and_loaded_state(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "uname",
        """
        #!/usr/bin/env bash
        case "${1:-}" in
          -s) printf '%s\\n' Darwin ;;
          -m) printf '%s\\n' arm64 ;;
          *) printf '%s\\n' Darwin ;;
        esac
        """,
    )
    write_executable(
        fake_bin / "launchctl",
        r"""
        #!/usr/bin/env bash
        set -euo pipefail
        command_name=$1
        shift
        printf '<%s>' "$command_name" "$@" >>"${FAKE_LAUNCHCTL_LOG:?}"
        printf '\n' >>"$FAKE_LAUNCHCTL_LOG"
        case "$command_name" in
          print)
            [ "$(cat "$FAKE_LAUNCHD_STATE")" = loaded ]
            ;;
          bootout)
            [ "$(cat "$FAKE_LAUNCHD_STATE")" = loaded ] || exit 1
            printf '%s\n' unloaded >"$FAKE_LAUNCHD_STATE"
            ;;
          bootstrap)
            failures=$(cat "$FAKE_BOOTSTRAP_FAILURES")
            if [ "$failures" -gt 0 ]; then
              printf '%s\n' "$((failures - 1))" >"$FAKE_BOOTSTRAP_FAILURES"
              exit 76
            fi
            printf '%s\n' loaded >"$FAKE_LAUNCHD_STATE"
            ;;
          *)
            exit 64
            ;;
        esac
        """,
    )
    bin_dir = home / ".local/bin"
    write_executable(bin_dir / "cloak-chromium", "#!/usr/bin/env bash\nexit 0\n")
    write_executable(bin_dir / "cloakbrowser-cdp-health", "#!/usr/bin/env bash\nexit 0\n")
    install_verified_cloak_receipt(home)
    prior_binary = home / ".local/share/rldyour/cloakbrowser/cache/chromium-prior/Chromium"
    write_executable(prior_binary, "#!/usr/bin/env bash\nexit 23\n")
    prior_sha256 = hashlib.sha256(prior_binary.read_bytes()).hexdigest()
    plist = home / "Library/LaunchAgents/com.rldyour.cloakbrowser.plist"
    profile = home / ".local/share/rldyour/cloakbrowser/daemon-profile"
    old_plist = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<!-- Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1 -->\n"
        '<plist version="1.0"><dict><key>Label</key><string>prior</string>'
        f'<key>ProgramArguments</key><array><string>{bin_dir / "cloak-chromium"}</string>'
        "<string>--headless=new</string>"
        "<string>--remote-debugging-address=127.0.0.1</string>"
        "<string>--remote-debugging-port=9222</string>"
        f"<string>--user-data-dir={profile}</string>"
        "<string>--no-first-run</string><string>--no-default-browser-check</string>"
        "<string>--fingerprint-platform=macos</string></array>"
        "</dict></plist>\n"
    )
    expected_rollback_plist = old_plist.replace(
        "<!-- Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1 -->",
        "<!-- Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1 -->\n"
        f"<!-- rldyour-binary-sha256: {prior_sha256} -->",
    ).replace(str(bin_dir / "cloak-chromium"), str(prior_binary))
    plist.parent.mkdir(parents=True)
    plist.write_text(old_plist, encoding="utf-8")
    launchd_state = tmp_path / "launchd.state"
    bootstrap_failures = tmp_path / "bootstrap.failures"
    launchctl_log = tmp_path / "launchctl.log"
    launchd_state.write_text("loaded\n", encoding="utf-8")
    bootstrap_failures.write_text("1\n", encoding="utf-8")

    result = run_bash(
        fixture,
        home,
        fake_bin,
        r'''
          rldyour::_active_cloak_service_binary() {
            printf -v "$5" '%s' "$FAKE_PRIOR_BINARY"
            printf -v "$6" '%s' "$FAKE_PRIOR_SHA256"
          }
          rldyour::install_cloakbrowser_daemon
        ''',
        extra_env={
            "FAKE_BOOTSTRAP_FAILURES": str(bootstrap_failures),
            "FAKE_LAUNCHCTL_LOG": str(launchctl_log),
            "FAKE_LAUNCHD_STATE": str(launchd_state),
            "FAKE_PRIOR_BINARY": str(prior_binary),
            "FAKE_PRIOR_SHA256": prior_sha256,
        },
    )
    assert result.returncode != 0
    assert plist.read_text(encoding="utf-8") == expected_rollback_plist
    assert str(prior_binary) in plist.read_text(encoding="utf-8")
    assert prior_sha256 in plist.read_text(encoding="utf-8")
    assert launchd_state.read_text(encoding="utf-8").strip() == "loaded"
    assert not list((home / ".local/share/rldyour/cloakbrowser").glob(".*service-snapshot.*"))
    calls = launchctl_log.read_text(encoding="utf-8")
    assert calls.count("<bootstrap>") == 2
    assert calls.count("<bootout>") >= 2


def test_cloak_health_accepts_restored_prior_binary_with_managed_provenance(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    install_fake_uv(fake_bin)
    write_executable(
        fake_bin / "uname",
        """
        #!/usr/bin/env bash
        case "${1:-}" in
          -s) printf '%s\\n' Linux ;;
          -m) printf '%s\\n' x86_64 ;;
          *) printf '%s\\n' Linux ;;
        esac
        """,
    )
    current_binary = install_verified_cloak_receipt(home)
    prior_binary = home / ".local/share/rldyour/cloakbrowser/cache/chromium-prior/chrome"
    write_executable(prior_binary, "#!/usr/bin/env bash\nexit 23\n")
    (home / ".local/share/rldyour/cloakbrowser/.rldyour-browser-stack").write_text(
        "# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1\n"
        "# This dedicated directory may be updated only by the browser bootstrap layer.\n",
        encoding="utf-8",
    )
    prior_sha256 = hashlib.sha256(prior_binary.read_bytes()).hexdigest()
    installed = run_bash(
        fixture,
        home,
        fake_bin,
        "rldyour::install_cloakbrowser",
        extra_env={
            "FAKE_CLOAK_BINARY": str(current_binary),
            "FAKE_PYTHON_LOG": str(tmp_path / "python.log"),
            "FAKE_UV_LOG": str(tmp_path / "uv.log"),
        },
    )
    assert installed.returncode == 0, installed.stdout + installed.stderr

    profile = home / ".local/share/rldyour/cloakbrowser/daemon-profile"
    unit = home / ".config/systemd/user/rldyour-cloakbrowser.service"
    unit.parent.mkdir(parents=True)
    unit.write_text(
        "# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1\n"
        f"# rldyour-binary-sha256={prior_sha256}\n"
        "[Service]\n"
        f'ExecStart="{prior_binary}" --headless=new '
        "--remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 "
        f'"--user-data-dir={profile}" --no-first-run --no-default-browser-check '
        "--fingerprint-platform=linux\n",
        encoding="utf-8",
    )
    write_executable(
        fake_bin / "systemctl",
        """
        #!/usr/bin/env bash
        if [ "$1" = --user ] && [ "$2" = is-active ]; then exit 0; fi
        if [ "$1" = --user ] && [ "$2" = show ]; then printf '%s\\n' 4242; exit 0; fi
        exit 64
        """,
    )
    write_executable(
        fake_bin / "ps",
        f"""
        #!/usr/bin/env bash
        printf '%s\\n' '{prior_binary} --headless=new --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --user-data-dir={profile} --no-first-run --no-default-browser-check --fingerprint-platform=linux'
        """,
    )
    write_executable(fake_bin / "readlink", f"#!/usr/bin/env bash\nprintf '%s\\n' '{prior_binary}'\n")
    write_executable(
        fake_bin / "ss",
        "#!/usr/bin/env bash\nprintf '%s\\n' 'LISTEN 0 128 127.0.0.1:9222 users:((chrome,pid=4242,fd=3))'\n",
    )
    write_executable(
        fake_bin / "curl",
        "#!/usr/bin/env bash\nprintf '%s\\n' '{\"Browser\":\"Cloak\",\"Protocol-Version\":\"1.3\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9222/devtools/browser/test\"}'\n",
    )
    health = subprocess.run(
        [str(home / ".local/bin/cloakbrowser-cdp-health")],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "HOME": str(home), "PATH": f"{fake_bin}:{os.environ['PATH']}"},
    )
    assert health.returncode == 0, health.stdout + health.stderr


def test_webwright_git_failure_and_import_poison_preserve_previous_runtime(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    install_fake_git(fake_bin)
    install_fake_uv(fake_bin)
    git_log = tmp_path / "git.log"
    uv_log = tmp_path / "uv.log"
    python_log = tmp_path / "python.log"
    pin = "4a46f282ec37f27d6003cc498a977939d62d9015"
    env = {
        "FAKE_GIT_LOG": str(git_log),
        "FAKE_UV_LOG": str(uv_log),
        "FAKE_PYTHON_LOG": str(python_log),
        "PYTHONPATH": "poisoned-pythonpath",
        "PYTHONHOME": "poisoned-pythonhome",
    }
    command = f'''
      rldyour::_install_webwright https://example.invalid/Webwright.git {pin} \
        "$HOME/webwright" "$FIXTURE/templates/browser/webwright-uv.lock" runtime_result || exit
      printf '%s\\n' "$runtime_result"
    '''

    first = run_bash(fixture, home, fake_bin, command, extra_env=env)
    assert first.returncode == 0, first.stdout + first.stderr
    published = Path(first.stdout.strip().splitlines()[-1])
    assert published.is_dir()
    assert "PYTHONPATH=unset PYTHONHOME=unset" in uv_log.read_text(encoding="utf-8")
    python_probes = python_log.read_text(encoding="utf-8")
    assert "PYTHONPATH=unset PYTHONHOME=unset" in python_probes
    assert "<-I>" in python_probes

    second = run_bash(
        fixture,
        home,
        fake_bin,
        command,
        extra_env={**env, "FAKE_GIT_FAIL": "1", "FAKE_UV_FAIL": "1"},
    )
    assert second.returncode == 0, second.stdout + second.stderr
    assert len(uv_log.read_text(encoding="utf-8").splitlines()) == 1

    wrapper = home / ".local/bin/webwright"
    wrapper.parent.mkdir(parents=True)
    wrapper.write_text("# Managed by rldyour-new-mac-or-ubuntu: browser-stack-v1\nold\n", encoding="utf-8")
    before_wrapper = wrapper.read_bytes()
    lock = fixture / "templates/browser/webwright-uv.lock"
    lock.write_text(lock.read_text(encoding="utf-8") + "\n# fault-injection\n", encoding="utf-8")
    failed_upgrade = run_bash(
        fixture,
        home,
        fake_bin,
        command,
        extra_env={**env, "FAKE_GIT_FAIL": "1"},
    )
    assert failed_upgrade.returncode != 0
    assert published.is_dir()
    assert wrapper.read_bytes() == before_wrapper
    assert not list((home / "webwright/runtimes").glob(".*.staging.*"))


def test_browser_wrappers_reject_privacy_bypasses_and_ignore_global_remote(tmp_path: Path) -> None:
    fixture = runtime_fixture(tmp_path)
    home = tmp_path / "home"
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "node",
        """
        #!/usr/bin/env bash
        printf '%s\\n' '24.18.0'
        """,
    )
    write_executable(fake_bin / "bun", "#!/usr/bin/env bash\nexit 0\n")
    chrome_provider = tmp_path / "providers/chrome"
    playwright_provider = tmp_path / "providers/playwright"
    provider_log = tmp_path / "wrapper-provider.log"
    write_executable(
        chrome_provider,
        r"""
        #!/usr/bin/env bash
        printf 'chrome usage=%s updates=%s args=' "${CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS:-}" "${CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS:-}" >>"${WRAPPER_PROVIDER_LOG:?}"
        printf '<%s>' "$@" >>"$WRAPPER_PROVIDER_LOG"
        printf '\n' >>"$WRAPPER_PROVIDER_LOG"
        """,
    )
    write_executable(
        playwright_provider,
        r"""
        #!/usr/bin/env bash
        config=""
        for argument in "$@"; do
          case "$argument" in --config=*) config=${argument#*=} ;; esac
        done
        global="$PWTEST_CLI_GLOBAL_CONFIG/.playwright/cli.config.json"
        route=none
        [ ! -f "$global" ] || route=remote
        if grep -Fq '"remoteEndpoint": null' "$config" && grep -Fq '"cdpEndpoint": "http://127.0.0.1:9222"' "$config"; then
          route=cdp
        fi
        printf 'playwright notifier=%s global=%s global_exists=%s route=%s args=' \
          "${NO_UPDATE_NOTIFIER:-}" "$PWTEST_CLI_GLOBAL_CONFIG" "$([ -f "$global" ] && printf 1 || printf 0)" "$route" >>"${WRAPPER_PROVIDER_LOG:?}"
        printf '<%s>' "$@" >>"$WRAPPER_PROVIDER_LOG"
        printf '\n' >>"$WRAPPER_PROVIDER_LOG"
        """,
    )
    fake_webwright = tmp_path / "fake-webwright"
    (fake_webwright / ".venv/bin").mkdir(parents=True)
    write_executable(fake_webwright / ".venv/bin/python", "#!/usr/bin/env bash\nexit 0\n")
    malicious = home / ".playwright/cli.config.json"
    malicious.parent.mkdir(parents=True)
    malicious.write_text('{"browser":{"remoteEndpoint":"http://attacker.invalid"}}\n', encoding="utf-8")
    env = {
        "FAKE_CHROME_PROVIDER": str(chrome_provider),
        "FAKE_PLAYWRIGHT_PROVIDER": str(playwright_provider),
        "FAKE_WEBWRIGHT": str(fake_webwright),
        "WRAPPER_PROVIDER_LOG": str(provider_log),
    }
    install = r'''
      rldyour::_install_browser_node_bundle() {
        printf -v "$6" '%s' "$FAKE_CHROME_PROVIDER"
        printf -v "$7" '%s' "$FAKE_PLAYWRIGHT_PROVIDER"
      }
      rldyour::install_cloakbrowser() {
        mkdir -p "$HOME/.local/bin"
        printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.local/bin/cloakbrowser-cdp-health"
        printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.local/bin/cloak-chromium"
        chmod 0755 "$HOME/.local/bin/cloakbrowser-cdp-health" "$HOME/.local/bin/cloak-chromium"
      }
      rldyour::install_cloakbrowser_daemon() { :; }
      rldyour::_install_webwright() {
        [ "${FAKE_WEBWRIGHT_FAIL:-0}" -eq 0 ] || return 73
        printf -v "$5" '%s' "$FAKE_WEBWRIGHT"
      }
      rldyour::install_browser_providers
    '''
    installed = run_bash(fixture, home, fake_bin, install, extra_env=env)
    assert installed.returncode == 0, installed.stdout + installed.stderr

    wrappers = home / ".local/bin"
    before = {name: (wrappers / name).read_bytes() for name in ("chrome-devtools-mcp", "playwright-cli", "webwright")}
    rejected = subprocess.run(
        [str(wrappers / "chrome-devtools-mcp"), "--performanceCrux"],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "WRAPPER_PROVIDER_LOG": str(provider_log)},
    )
    assert rejected.returncode == 64
    assert not provider_log.exists()
    literal_separator = subprocess.run(
        [str(wrappers / "chrome-devtools-mcp"), "--", "--version"],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "WRAPPER_PROVIDER_LOG": str(provider_log)},
    )
    assert literal_separator.returncode == 64
    assert not provider_log.exists()

    allowed = subprocess.run(
        [str(wrappers / "chrome-devtools-mcp"), "--version", "--noUsageStatistics"],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "WRAPPER_PROVIDER_LOG": str(provider_log)},
    )
    assert allowed.returncode == 0, allowed.stdout + allowed.stderr
    chrome_log = provider_log.read_text(encoding="utf-8").splitlines()[-1]
    assert "chrome usage=1 updates=1" in chrome_log
    assert chrome_log.endswith(
        "<--browser-url=http://127.0.0.1:9222><--version><--no-usage-statistics><--no-performance-crux>"
    )

    playwright = subprocess.run(
        [str(wrappers / "playwright-cli"), "--version"],
        capture_output=True,
        text=True,
        check=False,
        env={
            **os.environ,
            "HOME": str(home),
            "PWTEST_CLI_GLOBAL_CONFIG": str(home),
            "WRAPPER_PROVIDER_LOG": str(provider_log),
        },
    )
    assert playwright.returncode == 0, playwright.stdout + playwright.stderr
    playwright_log = provider_log.read_text(encoding="utf-8").splitlines()[-1]
    expected_empty_root = home / ".local/share/rldyour/browser-stack/playwright-global-empty"
    assert f"notifier=1 global={expected_empty_root} global_exists=0 route=cdp" in playwright_log
    assert not any(expected_empty_root.iterdir())
    config_runtimes = home / ".local/share/rldyour/browser-stack/config-runtimes"
    published_configs = sorted(config_runtimes.glob("config-*/playwright-cli.json"))
    assert len(published_configs) == 1
    old_config = published_configs[0]
    old_config_bytes = old_config.read_bytes()
    managed_config = json.loads(old_config.read_text(encoding="utf-8"))
    assert managed_config["browser"]["remoteEndpoint"] is None

    overlay_template = fixture / "templates/browser/webwright-local-cdp.yaml"
    overlay_template.write_text(
        overlay_template.read_text(encoding="utf-8") + "\n# transactional-upgrade-candidate\n",
        encoding="utf-8",
    )
    failed_switch = run_bash(
        fixture,
        home,
        fake_bin,
        install,
        extra_env={**env, "FAKE_WEBWRIGHT_FAIL": "1"},
    )
    assert failed_switch.returncode != 0
    assert before == {name: (wrappers / name).read_bytes() for name in before}
    assert str(old_config) in (wrappers / "playwright-cli").read_text(encoding="utf-8")
    assert old_config.read_bytes() == old_config_bytes
    assert len(list(config_runtimes.glob("config-*/playwright-cli.json"))) == 2


def test_webwright_wrapper_replaces_inherited_pythonpath() -> None:
    common = (ROOT / "scripts/lib/common.sh").read_text(encoding="utf-8")
    assert 'unset LOCAL_BROWSER_EXECUTABLE BROWSER_EXECUTABLE PYTHONHOME' in common
    assert 'export PYTHONPATH="${webwright_home}/src"' in common
    assert '${PYTHONPATH:+' not in common
    assert "--performanceCrux|--performanceCrux=*" in common
    assert "CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1" in common
    assert 'export PWTEST_CLI_GLOBAL_CONFIG="\\$global_config_root"' in common
    assert 'export NO_UPDATE_NOTIFIER=1' in common
