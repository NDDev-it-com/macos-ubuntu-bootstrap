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
    assert "2.1.202" in macos_versions.get("CLAUDE_CODE_VERSION", "")
    assert "0.142.5" in macos_versions.get("CODEX_VERSION", "")
    assert "1.17.14" in macos_versions.get("OPENCODE_VERSION", "")
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


AI_PIN_PATTERN = re.compile(
    r"^(CLAUDE_CODE_VERSION|CODEX_VERSION|OPENCODE_VERSION|MIMOCODE_VERSION)=\"([^\"]+)\"$",
    re.MULTILINE,
)


def test_ai_runtime_pins_match_documentation_surfaces() -> None:
    """Doc surfaces must cite the same AI CLI versions the installer pins.

    The installer profiles (scripts/*/install.sh) are the source of truth for
    AI runtime pins. README, instruction docs, and the install matrix duplicate
    those versions for humans; without this guard a pin bump (e.g.
    2.1.199 -> 2.1.201) can land in the installers while the prose silently
    drifts, and no other check catches it.
    """
    install = Path("scripts/macos/install.sh").read_text(encoding="utf-8")
    pins = {name: value for name, value in AI_PIN_PATTERN.findall(install)}
    assert set(pins) == {
        "CLAUDE_CODE_VERSION",
        "CODEX_VERSION",
        "OPENCODE_VERSION",
        "MIMOCODE_VERSION",
    }, f"unexpected installer pin set: {sorted(pins)}"

    doc_surfaces = (
        "README.md",
        "AGENTS.md",
        ".claude/CLAUDE.md",
        "docs/install.md",
    )
    for surface in doc_surfaces:
        text = Path(surface).read_text(encoding="utf-8")
        for name, version in pins.items():
            assert version in text, (
                f"{surface} is missing {name}={version}; align the doc surface "
                f"with the installer pin"
            )


def test_vtsls_replaces_typescript_language_server() -> None:
    """@vtsls/language-server must replace typescript-language-server.

    vtsls was chosen as the TS/JS LSP (better feature parity with the VS Code
    TS extension; selected by Zed and LazyVim). A future PR must not silently
    restore typescript-language-server or drop the vtsls entry.
    """
    for profile in ("macos", "ubuntu"):
        body = Path(f"scripts/{profile}/install.sh").read_text(encoding="utf-8")
        bun_lsp = parse_array(body, BUN_LSP_PATTERN, f"{profile} BUN_LSP_PACKAGES")
        assert "@vtsls/language-server" in bun_lsp, (
            f"{profile} BUN_LSP_PACKAGES must include @vtsls/language-server"
        )
        assert "typescript-language-server" not in bun_lsp, (
            f"{profile} BUN_LSP_PACKAGES must not include typescript-language-server"
        )


def test_browser_providers_are_optional_in_verify() -> None:
    """Browser providers must be optional, not required, in verify.sh.

    chrome-devtools-mcp and playwright-cli are installed by the
    --skip-browser-gated rldyour::install_browser_providers layer. Listing them
    as required would fail strict verification on server-only or headless
    profiles where the browser layer is intentionally skipped.
    """
    for profile in ("macos", "ubuntu"):
        verify = Path(f"scripts/{profile}/verify.sh").read_text(encoding="utf-8")
        required = parse_array(verify, re.compile(r"^\s*required_cmds=\((.*?)\)", re.MULTILINE | re.DOTALL), f"{profile} required_cmds")
        optional = parse_array(verify, re.compile(r"^\s*optional_cmds=\((.*?)\)", re.MULTILINE | re.DOTALL), f"{profile} optional_cmds")
        for cmd in ("chrome-devtools-mcp", "playwright-cli"):
            assert cmd not in required, (
                f"{profile} verify.sh must not list {cmd} as required (browser layer is opt-in)"
            )
            assert cmd in optional, (
                f"{profile} verify.sh must list {cmd} as optional"
            )


def test_go_bin_in_ensure_path() -> None:
    """$HOME/go/bin must be in rldyour::ensure_path candidates.

    go-installed binaries (sqls and any future Go tool) land in ~/go/bin; without
    it in ensure_path they are not discoverable during verification in the same
    session.
    """
    common = Path("scripts/lib/common.sh").read_text(encoding="utf-8")
    assert '"$HOME/go/bin"' in common, (
        "scripts/lib/common.sh rldyour::ensure_path must include $HOME/go/bin"
    )


def test_macos_python_tooling_has_no_duplicate_ruff() -> None:
    """macOS PYTHON_TOOLING_PACKAGES must not contain ruff.

    ruff is installed via the Homebrew formula (single source of truth for the
    version and the ruff server LSP). A duplicate uv-tool install would shadow
    or conflict with the brew one depending on PATH ordering.
    """
    macos = Path("scripts/macos/install.sh").read_text(encoding="utf-8")
    tooling = parse_array(macos, PYTHON_TOOLING_PATTERN, "macOS PYTHON_TOOLING_PACKAGES")
    assert "ruff" not in tooling, (
        "macOS PYTHON_TOOLING_PACKAGES must not contain ruff (installed via Homebrew)"
    )


def test_macos_bun_lsp_has_no_duplicate_vscode_ls() -> None:
    """macOS BUN_LSP_PACKAGES must not contain vscode-langservers-extracted.

    The vscode-* language servers are installed via the Homebrew
    vscode-langservers-extracted formula (single source of truth); bun-installing
    the npm package duplicates them.
    """
    macos = Path("scripts/macos/install.sh").read_text(encoding="utf-8")
    bun_lsp = parse_array(macos, BUN_LSP_PATTERN, "macOS BUN_LSP_PACKAGES")
    assert "vscode-langservers-extracted" not in bun_lsp, (
        "macOS BUN_LSP_PACKAGES must not contain vscode-langservers-extracted (Homebrew only)"
    )


def test_ubuntu_installs_security_scanners_required_by_verify() -> None:
    """Ubuntu install.sh must install every scanner verify.sh requires.

    Strict post-checks run verify.sh, so each required scanner must have an
    install channel in install.sh. This guard prevents a regression where a
    scanner is added to verify.sh required_cmds without a matching installer.
    """
    ubuntu_install = Path("scripts/ubuntu/install.sh").read_text(encoding="utf-8")
    assert "install_security_scanners" in ubuntu_install, (
        "ubuntu install.sh must define install_security_scanners()"
    )
    for scanner in ("basedpyright", "osv-scanner", "gitleaks", "semgrep", "hadolint", "actionlint"):
        assert scanner in ubuntu_install, (
            f"ubuntu install.sh must reference scanner '{scanner}' (required by verify.sh)"
        )
