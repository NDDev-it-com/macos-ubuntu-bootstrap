import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ZSHRC = ROOT / "templates/terminal/zshrc"


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
    template = ZSHRC.read_text(encoding="utf-8")
    assert "if command -v eza" in template
    assert "if command -v bat" in template
    assert "elif command -v batcat" in template
    assert "if command -v fd" in template
    assert "elif command -v fdfind" in template
    for command in (
        "lazygit",
        "difft",
        "jaq",
        "dust",
        "dua",
        "duf",
        "procs",
        "btop",
        "doggo",
        "gping",
        "hexyl",
        "viddy",
    ):
        assert f"command -v {command}" in template
