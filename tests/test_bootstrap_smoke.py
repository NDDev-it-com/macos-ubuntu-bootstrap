import subprocess


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
