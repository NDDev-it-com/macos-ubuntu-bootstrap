#!/usr/bin/env python3
"""Compile, statically check, and cold-import every repository test module."""

from __future__ import annotations

import argparse
import ast
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from pyflakes.checker import Checker
from pyflakes.messages import UndefinedName

SCHEMA = "rldyour.test-module-audit/v1"
TIMEOUT_SECONDS = 30


def test_modules(root: Path) -> list[Path]:
    modules = sorted((root / "tests").glob("test_*.py"))
    if not modules:
        raise RuntimeError("no test modules discovered")
    return modules


def compile_modules(modules: list[Path]) -> None:
    for path in modules:
        compile(path.read_bytes(), str(path), "exec", dont_inherit=True)


def static_check(modules: list[Path]) -> None:
    failures: list[str] = []
    for path in modules:
        tree = compile(
            path.read_bytes(), str(path), "exec", flags=ast.PyCF_ONLY_AST, dont_inherit=True,
        )
        for finding in Checker(tree, filename=str(path)).messages:
            if isinstance(finding, UndefinedName):
                failures.append(str(finding))
    if failures:
        raise RuntimeError("undefined test-module names:\n" + "\n".join(sorted(failures)))


def cold_import(modules: list[Path], cwd: Path, home: Path) -> None:
    loader = (
        "import runpy,sys; "
        "runpy.run_path(sys.argv[1], run_name='rldyour_cold_import')"
    )
    environment = {
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "PYTHONPATH": str(home / "hostile-shadow-path"),
    }
    for path in modules:
        completed = subprocess.run(
            [sys.executable, "-I", "-c", loader, str(path.resolve())],
            cwd=cwd,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=TIMEOUT_SECONDS,
            check=False,
        )
        if completed.returncode:
            detail = completed.stderr.strip() or completed.stdout.strip()
            raise RuntimeError(f"cold import failed for {path.name} from {cwd}: {detail}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    root = args.root.resolve()
    modules = test_modules(root)
    compile_modules(modules)
    static_check(modules)
    with tempfile.TemporaryDirectory(prefix="rldyour-test-import-") as temporary:
        unrelated = Path(temporary)
        cold_import(modules, root, unrelated)
        cold_import(modules, unrelated, unrelated)
    print(f"{SCHEMA}:ok:{len(modules)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
