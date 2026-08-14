"""Discovery must report drift without ever becoming a way to change a pin.

`scripts/ci/discover_source_drift.py` reads first-party release metadata and
says where the contract stands. It is deliberately incapable of editing the
contract, and its failure modes are chosen so the report stays trustworthy: a
source that contradicts the contract fails the run, while a source that is
merely unreachable does not, because "GitHub rate-limited us" is not evidence
that a pin drifted and a report that cries wolf gets ignored.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import urllib.error
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/ci/discover_source_drift.py"
SPEC = importlib.util.spec_from_file_location("discover_source_drift", MODULE_PATH)
assert SPEC and SPEC.loader
drift = importlib.util.module_from_spec(SPEC)
# Registered before exec: `@dataclass` resolves its own module through
# `sys.modules[cls.__module__]`, which is absent for a module loaded by path.
sys.modules["discover_source_drift"] = drift
SPEC.loader.exec_module(drift)

CONTRACT = json.loads((ROOT / "config/rldyour-contract.json").read_text(encoding="utf-8"))


def _contract_with(**overrides) -> dict:
    data = json.loads(json.dumps(CONTRACT))
    for dotted, value in overrides.items():
        node = data
        *path, leaf = dotted.split(".")
        for key in path:
            node = node[key]
        node[leaf] = value
    return data


# ----------------------------- normalisation -----------------------------


@pytest.mark.parametrize("raw,expected", [
    ("1.2.3", "1.2.3"),
    ("v1.2.3", "1.2.3"),
    ("go1.26.6", "1.26.6"),
    ("bun-v1.3.14", "1.3.14"),
    # A monorepo tagging per module. Stripping a leading `go` from this yields
    # `pls/v0.23.0`, which the first version of this function actually produced
    # and reported as drift against an identical pin.
    ("gopls/v0.23.0", "0.23.0"),
])
def test_every_upstream_tag_spelling_normalizes(raw: str, expected: str) -> None:
    assert drift._normalize(raw) == expected


# ----------------------------- fail-closed -----------------------------


def test_a_missing_required_asset_is_a_violation(monkeypatch) -> None:
    """A release that no longer publishes an architecture we install is drift."""
    monkeypatch.setattr(drift, "_get", lambda url: {
        "tag_name": "v9.9.9",
        "assets": [{"name": "uv-x86_64-unknown-linux-gnu.tar.gz",
                    "browser_download_url": "https://example.invalid/v9.9.9/x86_64"}],
    })
    findings = {item.name: item for item in drift.discover(CONTRACT)}
    uv = findings["uv"]
    assert uv.status == "violation"
    assert "aarch64" in uv.detail


def test_a_mutable_download_url_is_a_violation(monkeypatch) -> None:
    """A moving target defeats the point of pinning."""
    monkeypatch.setattr(drift, "_get", lambda url: {
        "tag_name": "v9.9.9",
        "assets": [{"name": "herdr-linux-x86_64",
                    "browser_download_url": "https://example.invalid/latest/herdr"}],
    })
    findings = {item.name: item for item in drift.discover(CONTRACT)}
    assert findings["herdr"].status == "violation"
    assert "mutable URL" in findings["herdr"].detail


def test_a_source_publishing_nothing_is_a_violation(monkeypatch) -> None:
    monkeypatch.setattr(drift, "_get", lambda url: [] if "nodejs" in url else {"tag_name": None})
    findings = {item.name: item for item in drift.discover(CONTRACT)}
    assert findings["node"].status == "violation"
    assert findings["uv"].status == "violation"


def test_violations_fail_the_run(monkeypatch, capsys) -> None:
    monkeypatch.setattr(drift, "_get", lambda url: {"tag_name": None})
    assert drift.main(["--json"]) == 1
    assert "source-drift-violation" in capsys.readouterr().err


# --------------------- reachability is not drift ---------------------


@pytest.mark.parametrize("failure", [
    urllib.error.URLError("dns"),
    urllib.error.HTTPError("u", 403, "rate limited", {}, None),
    OSError("connection reset"),
    TimeoutError("timed out"),
])
def test_an_unreachable_source_is_reported_but_does_not_fail(monkeypatch, failure) -> None:
    """A report that fails on GitHub's rate limit is a report people mute."""
    def explode(url):
        raise failure
    monkeypatch.setattr(drift, "_get", explode)
    monkeypatch.setattr(drift, "_rust_stable", lambda name: (_ for _ in ()).throw(failure))

    findings = drift.discover(CONTRACT)
    assert findings, "discovery produced nothing"
    assert all(item.status == "unknown" for item in findings), (
        [f"{i.name}={i.status}" for i in findings if i.status != "unknown"]
    )
    assert drift.main([]) == 0


# ----------------------------- drift itself -----------------------------


def test_a_newer_upstream_is_reported_as_behind(monkeypatch) -> None:
    monkeypatch.setattr(drift, "_npm_latest", lambda pkg, name: ("999.0.0", []))
    findings = {item.name: item for item in drift.discover(CONTRACT)}
    assert findings["codex"].status == "behind"
    assert findings["codex"].latest == "999.0.0"


def test_an_intentional_hold_reads_as_a_decision(monkeypatch) -> None:
    """A held pin must not look like an oversight."""
    monkeypatch.setattr(drift, "_npm_latest", lambda pkg, name: ("999.0.0", []))
    monkeypatch.setitem(drift.INTENTIONAL_HOLDS, "codex", "held pending vendor advisory")
    findings = {item.name: item for item in drift.discover(CONTRACT)}
    assert findings["codex"].status == "held"
    assert findings["codex"].detail == "held pending vendor advisory"


# ------------------------- coverage of the contract -------------------------


def test_every_pinned_source_tool_has_a_probe() -> None:
    """A tool added to the contract without a probe would drift unseen."""
    probed = {name for name, *_ in drift._pins(CONTRACT)}
    declared = set(CONTRACT["runtime_support"]["ubuntu_pinned_source_tools"])
    assert declared <= probed, f"pinned tools with no discovery probe: {sorted(declared - probed)}"


def test_every_runtime_host_and_user_tool_has_a_probe() -> None:
    probed = {name for name, *_ in drift._pins(CONTRACT)}
    for expected in ("node", "uv", "bun", "go", "rust", "dart", "gopls",
                     "herdr", "telegram", "codex", "homebrew-pkg"):
        assert expected in probed, f"{expected} has no discovery probe"


def test_discovery_cannot_write_the_contract() -> None:
    """The one property that keeps this safe to run on a schedule."""
    import re as _re

    source = MODULE_PATH.read_text(encoding="utf-8")
    for forbidden in ("write_text", "write_bytes", "urlretrieve", "subprocess", "os.remove"):
        assert forbidden not in source, (
            f"discovery gained {forbidden!r}; it must only read metadata"
        )
    # `open(` alone matches `urlopen(`, which is how this script reads. Look for
    # a write mode instead.
    assert not _re.search(r"\bopen\([^)]*['\"][wax]", source), (
        "discovery opened a file for writing; it must only read metadata"
    )


@pytest.mark.parametrize("url,expected", [
    ("https://api.github.com/repos/x/y/releases/latest", True),
    # A lookalike host that merely contains the API host as a substring.
    ("https://evil.example.invalid/api.github.com/repos/x/y", False),
    ("https://api.github.com.evil.example.invalid/repos/x/y", False),
    ("https://nodejs.org/dist/index.json", False),
    ("https://registry.npmjs.org/@openai/codex/latest", False),
])
def test_the_token_goes_only_to_the_github_api_host(monkeypatch, url, expected) -> None:
    """`"api.github.com" in url` would hand the credential to a lookalike host.

    Every URL in this script is a hardcoded constant, so it was not reachable --
    but a credential boundary that is right by accident is one refactor away
    from being wrong, and CodeQL was correct to say so.
    """
    seen: dict[str, str] = {}

    class _Response:
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return b"{}"

    def capture(request, timeout=None):
        seen.update(request.headers)
        return _Response()

    monkeypatch.setenv("GITHUB_TOKEN", "secret-value")
    monkeypatch.setattr(drift.urllib.request, "urlopen", capture)
    drift._get(url)
    carried = any("secret-value" in value for value in seen.values())
    assert carried is expected, f"{url}: token carried={carried}, expected {expected}"
