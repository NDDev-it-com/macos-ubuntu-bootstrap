"""Test-session invariants that must not come from the developer's environment.

Several suites assert properties about file and directory modes -- the
validation-path resolver refuses a Homebrew keg or a Codex bundle whose subtree
is group- or world-writable, which is the whole point of those checks. Fixtures
build those trees with `Path.mkdir()`, which subtracts the process umask.

On a CI runner the umask is 022, so a fixture directory is 0755 and the checks
pass. On a developer machine with umask 002 -- common where a shared group is
used -- the same directory is 0775, the resolver correctly refuses it, and four
tests fail for a reason that has nothing to do with the code under test.

A test that asserts a mode must control the mode. Pinning the umask for the
session makes the suite give the same answer on every host.
"""

from __future__ import annotations

import os

import pytest


@pytest.fixture(autouse=True, scope="session")
def _deterministic_umask():
    previous = os.umask(0o022)
    try:
        yield
    finally:
        os.umask(previous)
