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
    assert "2.1.199" in macos_versions.get("CLAUDE_CODE_VERSION", "")
    assert "0.142.5" in macos_versions.get("CODEX_VERSION", "")
    assert "1.17.13" in macos_versions.get("OPENCODE_VERSION", "")
    assert "0.1.4" in macos_versions.get("MIMOCODE_VERSION", "")

    assert "gopls" in macos


def test_ubuntu_installs_marksman_for_verify_contract() -> None:
    ubuntu = Path("scripts/ubuntu/install.sh").read_text(encoding="utf-8")
    macos = Path("scripts/macos/install.sh").read_text(encoding="utf-8")
    verify = Path("scripts/ubuntu/verify.sh").read_text(encoding="utf-8")

    array_pattern = re.compile(
        r"^\s*BUN_LSP_PACKAGES=\((.*?)\)", re.MULTILINE | re.DOTALL
    )
    system_pattern = re.compile(
        r"^\s*BREW_SYSTEM_PACKAGES=\((.*?)\)", re.MULTILINE | re.DOTALL
    )

    def parse_array(body: str, pattern: re.Pattern[str], name: str) -> set[str]:
        match = pattern.search(body)
        assert match is not None, f"{name} array not found"
        raw = match.group(1)
        tokens = []
        for token in re.findall(r"\"([^\"]+)\"|'([^']+)'|([^\s#]+)", raw):
            value = token[0] or token[1] or token[2]
            value = value.strip()
            if value:
                tokens.append(value)
        return set(tokens)

    assert "marksman" in parse_array(ubuntu, array_pattern, "ubuntu BUN_LSP_PACKAGES")
    assert "marksman" in parse_array(macos, system_pattern, "macOS BREW_SYSTEM_PACKAGES")
    assert "marksman" in verify
