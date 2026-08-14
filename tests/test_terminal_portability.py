import os
import re
import shutil
import socket
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ZSHRC = ROOT / "templates/terminal/zshrc"
ZSH_PLUGINS = ROOT / "templates/terminal/zsh_plugins.txt"
COMMON = ROOT / "scripts/lib/common.sh"
UBUNTU_INSTALL = ROOT / "scripts/ubuntu/install.sh"

# The pinned plugin set the materializer clones. Order matters and
# zsh-syntax-highlighting MUST stay last.
EXPECTED_PLUGINS = [
    "romkatv/zsh-defer",
    "Aloxaf/fzf-tab",
    "zsh-users/zsh-completions",
    "zsh-users/zsh-autosuggestions",
    "olets/zsh-abbr",
    "zsh-users/zsh-syntax-highlighting",
]


def _install_fake_command(bin_dir: Path, name: str) -> None:
    command = bin_dir / name
    command.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    command.chmod(0o755)


def test_ubuntu_command_names_do_not_create_broken_interactive_aliases(
    tmp_path: Path,
) -> None:
    zsh = shutil.which("zsh")
    assert zsh is not None, "zsh is required to verify the managed zsh template"

    home = tmp_path / "home"
    fake_bin = tmp_path / "bin"
    home.mkdir()
    fake_bin.mkdir()
    for name in ("ls", "cat", "batcat", "fdfind", "git", "duf", "btop", "hexyl"):
        _install_fake_command(fake_bin, name)

    probe = r'''
typeset -ga captured_abbrs
abbr() {
  local argument last
  for argument in "$@"; do last=$argument; done
  captured_abbrs+=("$last")
}
source "$1"
(( ${+aliases[ls]} == 0 )) || exit 10
(( ${+aliases[tree]} == 0 )) || exit 11
[[ ${aliases[cat]-} == batcat ]] || exit 12
[[ ${FZF_DEFAULT_COMMAND-} == "fdfind --type f --hidden --exclude .git" ]] || exit 13
[[ ${commands[ls]-} == "$2/ls" ]] || exit 14
[[ ${commands[cat]-} == "$2/cat" ]] || exit 15
(( ${+aliases[lg]} == 0 )) || exit 16
expected_abbrs=(
  'gs=git status'
  'gd=git diff'
  'df=duf'
  'top=btop'
  'htop=btop'
  'xxd=hexyl'
)
[[ ${(j:|:)captured_abbrs} == ${(j:|:)expected_abbrs} ]] || exit 17
'''
    result = subprocess.run(
        [zsh, "-f", "-i", "-c", probe, "_", str(ZSHRC), str(fake_bin)],
        check=False,
        capture_output=True,
        text=True,
        env={
            "HOME": str(home),
            "PATH": str(fake_bin),
            "TERM": "dumb",
            "ZDOTDIR": str(home),
        },
    )

    assert result.returncode == 0, result.stderr + result.stdout


def test_portable_aliases_are_guarded_in_the_template() -> None:
    """Every alias is guarded, and the guarded set comes from the contract.

    This test used to carry a literal list of twelve commands. Six of them --
    dust, dua, procs, doggo, gping and viddy -- were installed by no profile on
    either platform, so the test asserted the presence of guards that could
    never fire and made the divergence look intentional. The guarded set is now
    derived from contract terminal_tools, which is itself bound to both
    installers by the tests at the end of this file.
    """
    import json as _json

    template = ZSHRC.read_text(encoding="utf-8")
    contract = _json.loads(
        (ROOT / "config/rldyour-contract.json").read_text(encoding="utf-8")
    )

    # Debian renames these two, so the template needs both spellings.
    assert "if command -v bat" in template
    assert "elif command -v batcat" in template
    assert "if command -v fd" in template
    assert "elif command -v fdfind" in template

    for command in contract["terminal_tools"]["shared"]:
        assert f"command -v {command}" in template, (
            f"{command} is declared shared but no zshrc guard uses it"
        )


def _plugin_lines() -> list[str]:
    lines = []
    for raw in ZSH_PLUGINS.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        lines.append(raw)
    return lines


def test_zsh_plugins_are_sha_pinned_and_ordered() -> None:
    lines = _plugin_lines()
    repos = [line.split()[0] for line in lines]
    assert repos == EXPECTED_PLUGINS, repos
    # zsh-abbr is referenced by the zshrc abbr block; it must be in the manifest.
    assert "olets/zsh-abbr" in repos
    # zsh-syntax-highlighting must remain the final plugin.
    assert repos[-1] == "zsh-users/zsh-syntax-highlighting"
    # zsh-completions keeps its fpath-only annotation.
    completions = next(line for line in lines if line.startswith("zsh-users/zsh-completions"))
    assert "kind:fpath" in completions
    # Every plugin line records an exact 40-hex pinned commit.
    for line in lines:
        assert re.search(r"pin\s+[0-9a-f]{40}\b", line), line


def test_materializer_installs_pinned_antidote_and_bundle() -> None:
    common = COMMON.read_text(encoding="utf-8")
    # Shared materializer wired into install_terminal_configs (both platforms).
    assert "rldyour::materialize_zsh_plugins" in common
    assert "rldyour::materialize_zsh_plugins\n}" in common or (
        "rldyour::materialize_zsh_plugins" in common
        and "install_config_template" in common
    )
    # Ubuntu publishes Antidote's tracked payload at the pinned SHA to $HOME/.antidote.
    assert "getantidote/antidote" in common
    assert "4913257e0ae3fee2a77e7189e526fe55b6ff9536" in common
    assert "$HOME/.antidote" in common
    # Published source home matches Antidote's default full path style.
    assert "${XDG_CACHE_HOME:-$HOME/.cache}/antidote" in common
    assert "github.com/$repo" in common
    # A compiled static bundle is produced for offline startup.
    assert "antidote bundle" in common
    assert ".zsh_plugins.zsh" in common


def _git(repo: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def _tracked_payload_fixture(tmp_path: Path) -> tuple[Path, str, socket.socket]:
    repo = tmp_path / "plugin-source"
    repo.mkdir()
    _git(repo, "init", "--quiet")
    _git(repo, "config", "user.name", "Bootstrap Test")
    _git(repo, "config", "user.email", "bootstrap-test@example.invalid")
    (repo / "plugin.zsh").write_bytes(b"source payload\n")
    executable = repo / "bin" / "plugin-helper"
    executable.parent.mkdir()
    executable.write_bytes(b"#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)
    (repo / "plugin-link").symlink_to("plugin.zsh")
    _git(repo, "add", "plugin.zsh", "bin/plugin-helper", "plugin-link")
    _git(repo, "commit", "--quiet", "-m", "fixture")
    commit = _git(repo, "rev-parse", "HEAD")

    # A real Unix socket reproduces the macOS hosted failure. It deliberately
    # lives in mutable Git service metadata, never in the tracked commit tree.
    subprocess.run(
        ["git", "-C", str(repo), "fsmonitor--daemon", "stop"],
        check=False,
        capture_output=True,
    )
    (repo / ".git" / "fsmonitor--daemon.ipc").unlink(missing_ok=True)
    fsmonitor = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    previous_directory = Path.cwd()
    try:
        os.chdir(repo / ".git")
        # A relative bind avoids Darwin's short AF_UNIX pathname limit while the
        # resulting socket still physically resides in the fixture's `.git`.
        fsmonitor.bind("fsmonitor--daemon.ipc")
    finally:
        os.chdir(previous_directory)
    return repo, commit, fsmonitor


def _publish_payload(
    git_dir: Path,
    commit: str,
    destination: Path,
    source_root: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    command = 'source "$1"; rldyour::_publish_pinned_git_payload "$2" "$3" "$4"'
    arguments = [str(COMMON), str(git_dir), commit, str(destination)]
    if source_root is not None:
        command += ' "$5"'
        arguments.append(str(source_root))
    return subprocess.run(
        [
            "bash",
            "-c",
            command,
            "tracked-payload-test",
            *arguments,
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def _payload_snapshot(root: Path) -> list[tuple[str, str, int, bytes | str]]:
    snapshot: list[tuple[str, str, int, bytes | str]] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode & 0o777
        if path.is_symlink():
            snapshot.append((relative, "symlink", mode, path.readlink().as_posix()))
        elif path.is_dir():
            snapshot.append((relative, "directory", mode, b""))
        else:
            snapshot.append((relative, "file", mode, path.read_bytes()))
    return snapshot


def test_tracked_payload_excludes_real_git_fsmonitor_socket_and_is_deterministic(
    tmp_path: Path,
) -> None:
    repo, commit, fsmonitor = _tracked_payload_fixture(tmp_path)
    first = tmp_path / "payload-first"
    second = tmp_path / "payload-second"
    try:
        result = _publish_payload(repo / ".git", commit, first)
        assert result.returncode == 0, result.stderr + result.stdout
        first_snapshot = _payload_snapshot(first)
        first_inode = first.stat().st_ino

        # Verification of an already-published payload is a no-op, and an
        # independent publication from the same commit is byte/mode deterministic.
        result = _publish_payload(repo / ".git", commit, first)
        assert result.returncode == 0, result.stderr + result.stdout
        assert first.stat().st_ino == first_inode
        result = _publish_payload(repo / ".git", commit, second)
        assert result.returncode == 0, result.stderr + result.stdout
    finally:
        fsmonitor.close()

    assert first_snapshot == _payload_snapshot(first) == _payload_snapshot(second)
    assert not (first / ".git").exists()
    assert (first / "plugin.zsh").read_bytes() == b"source payload\n"
    assert (first / "plugin.zsh").stat().st_mode & 0o777 == 0o644
    assert (first / "bin" / "plugin-helper").stat().st_mode & 0o777 == 0o755
    assert (first / "plugin-link").is_symlink()
    assert (first / "plugin-link").readlink().as_posix() == "plugin.zsh"


def test_tracked_payload_fails_closed_on_payload_drift(tmp_path: Path) -> None:
    repo, commit, fsmonitor = _tracked_payload_fixture(tmp_path)
    destination = tmp_path / "payload"
    try:
        assert _publish_payload(repo / ".git", commit, destination).returncode == 0
    finally:
        fsmonitor.close()

    (destination / "plugin.zsh").write_bytes(b"tampered\n")
    result = _publish_payload(repo / ".git", commit, destination)
    assert result.returncode != 0
    assert "tracked file bytes diverged" in result.stderr + result.stdout

    (destination / "plugin.zsh").write_bytes(b"source payload\n")
    (destination / "bin" / "plugin-helper").unlink()
    result = _publish_payload(repo / ".git", commit, destination)
    assert result.returncode != 0
    assert "file set is missing or contains additional paths" in result.stderr + result.stdout

    (destination / "bin" / "plugin-helper").write_bytes(b"#!/bin/sh\nexit 0\n")
    (destination / "bin" / "plugin-helper").chmod(0o755)
    (destination / "extra.zsh").write_bytes(b"extra\n")
    result = _publish_payload(repo / ".git", commit, destination)
    assert result.returncode != 0
    assert "file set is missing or contains additional paths" in result.stderr + result.stdout
    (destination / "extra.zsh").unlink()

    extra_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    previous_directory = Path.cwd()
    try:
        os.chdir(destination)
        extra_socket.bind("unexpected.ipc")
        os.chdir(previous_directory)
        result = _publish_payload(repo / ".git", commit, destination)
    finally:
        os.chdir(previous_directory)
        extra_socket.close()
    assert result.returncode != 0
    assert "unsupported file type" in result.stderr + result.stdout


def test_tracked_payload_rejects_tracked_symlink_escape(tmp_path: Path) -> None:
    repo, _commit, fsmonitor = _tracked_payload_fixture(tmp_path)
    try:
        (repo / "plugin-link").unlink()
        (repo / "plugin-link").symlink_to("../outside")
        _git(repo, "add", "plugin-link")
        _git(repo, "commit", "--quiet", "-m", "unsafe tracked symlink")
        commit = _git(repo, "rev-parse", "HEAD")
        result = _publish_payload(repo / ".git", commit, tmp_path / "payload")
    finally:
        fsmonitor.close()
    assert result.returncode != 0
    assert "tracked symlink escapes its payload root" in result.stderr + result.stdout


def test_tracked_payload_rejects_unsupported_tracked_git_entry(tmp_path: Path) -> None:
    repo, commit, fsmonitor = _tracked_payload_fixture(tmp_path)
    try:
        # A gitlink without an exact tracked .gitmodules origin is unsupported.
        # It must never be silently omitted or resolved from ambient Git config.
        _git(repo, "update-index", "--add", "--cacheinfo", f"160000,{commit},nested")
        _git(repo, "commit", "--quiet", "-m", "unsupported tracked gitlink")
        unsupported_commit = _git(repo, "rev-parse", "HEAD")
        result = _publish_payload(repo / ".git", unsupported_commit, tmp_path / "payload")
    finally:
        fsmonitor.close()
    assert result.returncode != 0
    assert "gitlinks and .gitmodules paths do not match exactly" in result.stderr + result.stdout


def test_tracked_payload_recursively_materializes_exact_declared_submodule(
    tmp_path: Path,
    monkeypatch,
) -> None:
    child = tmp_path / "child"
    child.mkdir()
    _git(child, "init", "--quiet")
    _git(child, "config", "user.name", "Bootstrap Test")
    _git(child, "config", "user.email", "bootstrap-test@example.invalid")
    (child / "child.zsh").write_bytes(b"child payload\n")
    _git(child, "add", "child.zsh")
    _git(child, "commit", "--quiet", "-m", "child fixture")
    child_commit = _git(child, "rev-parse", "HEAD")

    source_root = tmp_path / "objects"
    child_store = source_root / "github.com" / "example" / "child.git"
    child_store.parent.mkdir(parents=True)
    subprocess.run(
        ["git", "clone", "--quiet", "--bare", str(child), str(child_store)],
        check=True,
    )
    # Keep the regression hermetic while retaining the production HTTPS
    # identity: Git rewrites only the test transport to this local fixture.
    monkeypatch.setenv("GIT_CONFIG_COUNT", "1")
    monkeypatch.setenv("GIT_CONFIG_KEY_0", f"url.file://{child}.insteadOf")
    monkeypatch.setenv("GIT_CONFIG_VALUE_0", "https://github.com/example/child")
    subprocess.run(
        [
            "git",
            f"--git-dir={child_store}",
            "remote",
            "set-url",
            "origin",
            "https://github.com/example/child",
        ],
        check=True,
    )

    parent = tmp_path / "parent"
    parent.mkdir()
    _git(parent, "init", "--quiet")
    _git(parent, "config", "user.name", "Bootstrap Test")
    _git(parent, "config", "user.email", "bootstrap-test@example.invalid")
    (parent / "parent.zsh").write_bytes(b"parent payload\n")
    (parent / ".gitmodules").write_text(
        '[submodule "child"]\n\tpath = nested\n\turl = https://github.com/example/child\n',
        encoding="utf-8",
    )
    _git(parent, "add", "parent.zsh", ".gitmodules")
    _git(parent, "update-index", "--add", "--cacheinfo", f"160000,{child_commit},nested")
    _git(parent, "commit", "--quiet", "-m", "parent fixture")
    parent_commit = _git(parent, "rev-parse", "HEAD")

    destination = tmp_path / "payload"
    result = _publish_payload(
        parent / ".git", parent_commit, destination, source_root=source_root
    )
    assert result.returncode == 0, result.stderr + result.stdout
    assert (destination / "parent.zsh").read_bytes() == b"parent payload\n"
    assert (destination / "nested" / "child.zsh").read_bytes() == b"child payload\n"
    assert not any(path.name == ".git" for path in destination.rglob(".git"))


def test_static_bundle_preferred_by_zshrc() -> None:
    template = ZSHRC.read_text(encoding="utf-8")
    # Startup sources the compiled offline bundle; there is no network fallback.
    assert '.zsh_plugins.zsh"' in template
    # `antidote load` must never run at shell startup — it resolves/clones plugins
    # over the network during shell init. A missing bundle fails closed (no plugins).
    assert "antidote load" not in template


def test_runtime_pillars_are_managed_pinned_artifacts() -> None:
    install = UBUNTU_INSTALL.read_text(encoding="utf-8")
    for tool in ("STARSHIP", "ATUIN", "CARAPACE"):
        assert f"{tool}_VERSION=" in install
        assert re.search(rf"{tool}_SHA256_X64=\"[0-9a-f]{{64}}\"", install), tool
        assert re.search(rf"{tool}_SHA256_ARM64=\"[0-9a-f]{{64}}\"", install), tool
    # Installed as managed content-addressed artifacts, never via apt/piped script.
    for fn in ("ensure_starship", "ensure_atuin", "ensure_carapace"):
        assert fn in install
        assert f"  {fn}\n" in install, f"{fn} must be wired into the system layer"
    assert "write_runtime_receipt" in install
    assert "ensure_managed_tool_link" in install
    # These pillars must not be added to the apt package list (apt is stale).
    for tool in ("starship", "atuin", "carapace"):
        assert f" {tool} " not in install.split("APT_SOURCE_PACKAGES=(", 1)[1].split(
            ")", 1
        )[0]


def test_login_shell_change_is_opt_in_only() -> None:
    install = UBUNTU_INSTALL.read_text(encoding="utf-8")
    assert "RLDYOUR_SET_LOGIN_SHELL" in install
    # Default OFF.
    assert 'SET_LOGIN_SHELL="${RLDYOUR_SET_LOGIN_SHELL:-0}"' in install
    # Guarded: the function returns early unless explicitly opted in.
    assert '[ "$SET_LOGIN_SHELL" -eq 1 ]' in install
    # Reversible: records the prior login shell for rollback.
    assert "previous-login-shell" in install
    assert "chsh -s" in install
    # /etc/shells is validated/updated before chsh.
    assert "/etc/shells" in install


def test_agent_gate_stays_first_in_zshrc() -> None:
    template = ZSHRC.read_text(encoding="utf-8")
    idx_gate = template.index("_is_agent")
    idx_plugins = template.index("Plugins via antidote")
    idx_history = template.index("HISTFILE")
    # Agent gate is defined and evaluated before history, plugins, and tools.
    assert idx_gate < idx_history < idx_plugins
    # The early `return` inside the agent branch precedes any plugin sourcing.
    idx_return = template.index("return", template.index("if _is_agent"))
    assert idx_return < idx_plugins


# --------------------------------------------------------------------------
# Per-platform tool parity (#68)
#
# The zshrc guards every alias and abbreviation with `command -v`, so a tool
# only one platform installs degrades silently instead of erroring: the shell
# offers less than the template describes and nothing reports it. These tests
# bind the guard set to the contract's declared per-platform tool sets, and
# bind those sets to what the two installers actually publish.
# --------------------------------------------------------------------------

import json  # noqa: E402  (module-level imports above predate this block)

CONTRACT = json.loads((ROOT / "config/rldyour-contract.json").read_text(encoding="utf-8"))
MACOS_INSTALL = ROOT / "scripts/macos/install.sh"

# Homebrew formula name -> the command it publishes, where they differ.
_BREW_COMMAND = {"difftastic": "difft", "git-delta": "delta", "ripgrep": "rg"}
# Debian renames two binaries to avoid clashes; the zshrc handles both spellings.
_APT_COMMAND = {"fd-find": "fdfind", "bat": "batcat", "ripgrep": "rg"}

# Guards that are not tool availability checks.
_NON_TOOL_GUARDS = {"abbr", "git"}


def _bash_array(path: Path, name: str) -> list[str]:
    text = path.read_text(encoding="utf-8")
    match = re.search(rf"^{name}=\(\n(.*?)^\)", text, re.S | re.M)
    assert match, f"{name} not found in {path.name}"
    body = re.sub(r"#.*$", "", match.group(1), flags=re.M)
    return body.split()


def _macos_commands() -> set[str]:
    formulae = _bash_array(MACOS_INSTALL, "BREW_SOURCE_PACKAGES")
    return {_BREW_COMMAND.get(f, f) for f in formulae}


def _ubuntu_commands() -> set[str]:
    apt = {_APT_COMMAND.get(p, p) for p in _bash_array(UBUNTU_INSTALL, "APT_SOURCE_PACKAGES")}
    rows = re.search(r"^PINNED_SOURCE_TOOLS=\(\n(.*?)^\)", UBUNTU_INSTALL.read_text(encoding="utf-8"),
                     re.S | re.M).group(1)
    # `links` is the sixth field: the names actually published into ~/.local/bin.
    published: set[str] = set()
    for line in rows.splitlines():
        line = line.strip()
        if line.startswith('"'):
            published |= set(line.strip('"').split(";")[5].split(","))
    # starship / atuin / carapace have their own ensure_* functions rather than rows.
    return apt | published | {"starship", "atuin", "carapace"}


def _zshrc_guards() -> set[str]:
    guards = set(re.findall(r"command -v ([\w-]+)", ZSHRC.read_text(encoding="utf-8")))
    return guards - _NON_TOOL_GUARDS


def test_every_zshrc_guard_names_a_declared_terminal_tool() -> None:
    """No alias may be guarded on a command the contract does not publish.

    Six guards used to name dust, dua, procs, doggo, gping and viddy, which no
    profile installs on either platform: those abbreviations could not exist on
    any device this repository produces.
    """
    declared = set(CONTRACT["terminal_tools"]["shared"])
    declared |= set(CONTRACT["terminal_tools"]["debian_renamed"].values())
    undeclared = _zshrc_guards() - declared
    assert not undeclared, (
        f"zshrc guards commands absent from contract terminal_tools: {sorted(undeclared)}"
    )


def test_shared_terminal_tools_are_installed_on_both_platforms() -> None:
    """`shared` must mean shared. A tool on one platform is a silent no-op."""
    renamed = CONTRACT["terminal_tools"]["debian_renamed"]
    mac, ubuntu = _macos_commands(), _ubuntu_commands()
    missing_mac = [t for t in CONTRACT["terminal_tools"]["shared"] if t not in mac]
    missing_ubuntu = [
        t for t in CONTRACT["terminal_tools"]["shared"]
        if t not in ubuntu and renamed.get(t) not in ubuntu
    ]
    assert not missing_mac, f"declared shared but no macOS formula publishes: {missing_mac}"
    assert not missing_ubuntu, f"declared shared but no Ubuntu manifest publishes: {missing_ubuntu}"


def test_macos_only_tools_are_absent_from_every_ubuntu_manifest() -> None:
    """A tool declared macOS-only must not quietly appear on Ubuntu."""
    ubuntu = _ubuntu_commands()
    leaked = [t for t in CONTRACT["terminal_tools"]["macos_only"] if t in ubuntu]
    assert not leaked, f"declared macOS-only but Ubuntu publishes: {leaked}"


def test_every_macos_only_tool_states_why() -> None:
    """The boundary is a decision, so each entry carries its reason."""
    for tool, reason in CONTRACT["terminal_tools"]["macos_only"].items():
        assert len(reason) > 30, f"{tool} is declared macOS-only without a reason"


def test_pinned_source_tool_rows_match_the_contract() -> None:
    """Every added row is bound to the contract's version and both digests."""
    declared = CONTRACT["runtime_support"]["ubuntu_pinned_source_tools"]
    rows = re.search(r"^PINNED_SOURCE_TOOLS=\(\n(.*?)^\)", UBUNTU_INSTALL.read_text(encoding="utf-8"),
                     re.S | re.M).group(1)
    seen = set()
    for line in rows.splitlines():
        line = line.strip()
        if not line.startswith('"'):
            continue
        fields = line.strip('"').split(";")
        name, version, _kind = fields[0], fields[1], fields[2]
        sha_x64, sha_arm64 = fields[6], fields[7]
        assert name in declared, f"row {name} is not declared in the contract"
        assert declared[name]["version"] == version, f"{name} version drift"
        assert declared[name]["sha256"]["x64"] == sha_x64, f"{name} x64 digest drift"
        assert declared[name]["sha256"]["arm64"] == sha_arm64, f"{name} arm64 digest drift"
        seen.add(name)
    assert seen == set(declared), f"contract and installer disagree on the row set: {seen ^ set(declared)}"
