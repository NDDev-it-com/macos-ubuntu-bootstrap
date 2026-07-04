import subprocess
from pathlib import Path
import re


def run_shell(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        capture_output=True,
        check=False,
        text=True,
    )


def parse_array(body: str, pattern: re.Pattern[str], name: str) -> set[str]:
    match = pattern.search(body)
    assert match is not None, f"{name} array not found"
    raw = match.group(1)
    tokens = []
    for token in re.findall(r"\"([^\"]+)\"|'([^']+)'|([^\s#]+)", raw):
        value = (token[0] or token[1] or token[2]).strip()
        if value:
            tokens.append(value)
    return set(tokens)


BUN_LSP_PATTERN = re.compile(r"^\s*BUN_LSP_PACKAGES=\((.*?)\)", re.MULTILINE | re.DOTALL)
BREW_SYSTEM_PATTERN = re.compile(r"^\s*BREW_SYSTEM_PACKAGES=\((.*?)\)", re.MULTILINE | re.DOTALL)
PYTHON_TOOLING_PATTERN = re.compile(r"^\s*PYTHON_TOOLING_PACKAGES=\((.*?)\)", re.MULTILINE | re.DOTALL)


def test_bootstrap_help() -> None:
    result = run_shell(["bash", "scripts/bootstrap.sh", "--help"])
    assert result.returncode == 0
    assert "Usage: scripts/bootstrap.sh" in result.stdout
    assert "--platform macos|ubuntu" in result.stdout


def test_bootstrap_plan_is_dry_run_safe() -> None:
    result = run_shell(
        [
            "bash",
            "scripts/bootstrap.sh",
            "--platform",
            "ubuntu",
            "--plan",
            "--skip-system",
            "--skip-ai",
            "--skip-lsps",
            "--skip-checks",
        ]
    )
    assert result.returncode == 0
    assert "rldyour-new-mac-or-ubuntu (Ubuntu) installer" in result.stdout
    assert "mode: dry-run" in result.stdout


def test_profile_pin_and_lsp_parity() -> None:
    macos = Path("scripts/macos/install.sh").read_text(encoding="utf-8")
    ubuntu = Path("scripts/ubuntu/install.sh").read_text(encoding="utf-8")

    pattern = re.compile(r"^(CLAUDE_CODE_VERSION|CODEX_VERSION|OPENCODE_VERSION|MIMOCODE_VERSION)=\"([^\"]+)\"$", re.MULTILINE)

    macos_versions = {k: v for k, v in pattern.findall(macos)}
    ubuntu_versions = {k: v for k, v in pattern.findall(ubuntu)}

    assert macos_versions and ubuntu_versions
    assert macos_versions == ubuntu_versions
    assert "2.1.201" in macos_versions.get("CLAUDE_CODE_VERSION", "")
    assert "0.142.5" in macos_versions.get("CODEX_VERSION", "")
    assert "1.17.13" in macos_versions.get("OPENCODE_VERSION", "")
    assert "0.1.4" in macos_versions.get("MIMOCODE_VERSION", "")

    assert "gopls" in macos


def test_ubuntu_installs_marksman_for_verify_contract() -> None:
    ubuntu = Path("scripts/ubuntu/install.sh").read_text(encoding="utf-8")
    macos = Path("scripts/macos/install.sh").read_text(encoding="utf-8")
    verify = Path("scripts/ubuntu/verify.sh").read_text(encoding="utf-8")

    # marksman is not published on npm, so it must NOT be bun-installed. Ubuntu
    # installs it from the pinned artempyanykh/marksman GitHub release binary.
    assert "marksman" not in parse_array(ubuntu, BUN_LSP_PATTERN, "ubuntu BUN_LSP_PACKAGES")
    assert "artempyanykh/marksman" in ubuntu
    assert "ensure_marksman" in ubuntu

    # macOS installs marksman from Homebrew; verify still requires the binary.
    assert "marksman" in parse_array(macos, BREW_SYSTEM_PATTERN, "macOS BREW_SYSTEM_PACKAGES")
    assert "marksman" in verify


def test_lsp_install_channels_use_published_packages() -> None:
    """Lock the clean-PC install channels so broken package names never regress."""
    macos = Path("scripts/macos/install.sh").read_text(encoding="utf-8")
    ubuntu = Path("scripts/ubuntu/install.sh").read_text(encoding="utf-8")
    macos_verify = Path("scripts/macos/verify.sh").read_text(encoding="utf-8")
    ubuntu_verify = Path("scripts/ubuntu/verify.sh").read_text(encoding="utf-8")

    # taplo ships as the npm `@taplo/cli` package; the bare `taplo` name is
    # unpublished on npm and must never be bun-installed.
    ubuntu_bun = parse_array(ubuntu, BUN_LSP_PATTERN, "ubuntu BUN_LSP_PACKAGES")
    assert "@taplo/cli" in ubuntu_bun
    assert "taplo" not in ubuntu_bun
    assert "taplo" not in parse_array(macos, BUN_LSP_PATTERN, "macOS BUN_LSP_PACKAGES")

    # `pyright` ships both `pyright` and `pyright-langserver`; there is no
    # separate `pyright-langserver` distribution to install.
    for body, name in ((macos, "macOS"), (ubuntu, "ubuntu")):
        tooling = parse_array(body, PYTHON_TOOLING_PATTERN, f"{name} PYTHON_TOOLING_PACKAGES")
        assert "pyright" in tooling
        assert "pyright-langserver" not in tooling

    # Homebrew llvm is keg-only, so macOS must symlink clangd onto PATH.
    assert "ensure_clangd" in macos

    # The Dockerfile LSP is satisfied by either command name across platforms.
    for verify_body in (macos_verify, ubuntu_verify):
        assert "require_one_of_cmd required docker-language-server docker-langserver" in verify_body
