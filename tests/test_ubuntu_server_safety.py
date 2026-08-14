import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "scripts/ubuntu/server.sh"


def run_server_function(script: str, *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", f'source "$1"\n{script}', "_", str(SERVER)],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, **(env or {})},
    )


def test_socket_activated_port_uses_live_session_and_rejects_mismatch(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    systemctl = fake_bin / "systemctl"
    systemctl.write_text(
        "#!/usr/bin/env bash\n"
        "[ \"$1 $2 $3\" = 'is-active --quiet ssh.socket' ]\n",
        encoding="utf-8",
    )
    systemctl.chmod(0o755)
    env = {
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "SSH_CONNECTION": "198.51.100.8 50123 203.0.113.10 2222",
        "RLDYOUR_DRY_RUN": "0",
    }
    result = run_server_function("rldyour::ubuntu_server::detect_ssh_port", env=env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert result.stdout.strip() == "2222"

    mismatch = run_server_function(
        "rldyour::ubuntu_server::detect_ssh_port 22", env=env
    )
    assert mismatch.returncode != 0
    assert "differs from the live session port" in mismatch.stderr


def test_ssh_match_context_contains_full_connection_tuple() -> None:
    result = run_server_function(
        "rldyour::ubuntu_server::probe_as_root() { printf 'usedns yes\\n'; }\n"
        "rldyour::ubuntu_server::ssh_match_context deploy 2222",
        env={
            "SSH_CONNECTION": "198.51.100.8 50123 203.0.113.10 2222",
            "RLDYOUR_SERVER_SSH_MATCH_HOST": "client.example.test",
        },
    )
    assert result.returncode == 0, result.stderr + result.stdout
    assert result.stdout.strip() == (
        "user=deploy,host=client.example.test,addr=198.51.100.8,"
        "laddr=203.0.113.10,lport=2222"
    )


def test_ufw_cidr_must_cover_live_operator_or_have_console_confirmation(tmp_path: Path) -> None:
    inside = run_server_function(
        "rldyour::ubuntu_server::validate_ufw_operator_source 198.51.100.0/24",
        env={"SSH_CONNECTION": "198.51.100.8 50123 203.0.113.10 2222"},
    )
    assert inside.returncode == 0, inside.stderr + inside.stdout

    outside = run_server_function(
        "rldyour::ubuntu_server::validate_ufw_operator_source 203.0.113.0/24",
        env={"SSH_CONNECTION": "198.51.100.8 50123 203.0.113.10 2222"},
    )
    assert outside.returncode != 0
    assert "outside UFW allow CIDR" in outside.stdout

    console = run_server_function(
        "rldyour::ubuntu_server::validate_ufw_operator_source 203.0.113.0/24",
        env={"SSH_CONNECTION": "", "RLDYOUR_SERVER_UFW_CONSOLE_CONFIRMED": "1"},
    )
    assert console.returncode == 0, console.stderr + console.stdout

    canonical_status = run_server_function(
        "status='22/tcp ALLOW IN 192.168.1.0/24'\n"
        "rldyour::ubuntu_server::ufw_status_has_ssh_rule \"$status\" 22 192.168.1.5/24"
    )
    assert canonical_status.returncode == 0, canonical_status.stderr + canonical_status.stdout

    invalid = run_server_function(
        "rldyour::ubuntu_server::validate_ufw_operator_source not-a-cidr",
        env={"SSH_CONNECTION": "", "RLDYOUR_SERVER_UFW_CONSOLE_CONFIRMED": "1"},
    )
    assert invalid.returncode != 0
    assert "invalid UFW allow CIDR" in invalid.stdout

    poisoned_python = tmp_path / "poisoned-python"
    poisoned_python.mkdir()
    (poisoned_python / "ipaddress.py").write_text(
        "def ip_address(value): return value\n"
        "class Network:\n"
        "    def __contains__(self, value): return True\n"
        "def ip_network(value, strict=False): return Network()\n",
        encoding="utf-8",
    )
    poisoned_membership = run_server_function(
        "rldyour::ubuntu_server::validate_ufw_operator_source 203.0.113.0/24",
        env={
            "PYTHONPATH": str(poisoned_python),
            "SSH_CONNECTION": "198.51.100.8 50123 203.0.113.10 2222",
        },
    )
    assert poisoned_membership.returncode != 0
    assert "outside UFW allow CIDR" in poisoned_membership.stdout

    unused_cidr = run_server_function(
        "rldyour::ubuntu_server::main --ssh-allow-cidr 198.51.100.0/24"
    )
    assert unused_cidr.returncode != 0
    assert "--ssh-allow-cidr requires --enable-ufw" in unused_cidr.stdout


def test_authorized_key_preflight_checks_parser_and_strict_modes(tmp_path: Path) -> None:
    uid = subprocess.check_output(["id", "-u"], text=True).strip()
    home = tmp_path / "home"
    ssh_dir = home / ".ssh"
    ssh_dir.mkdir(parents=True)
    home.chmod(0o700)
    ssh_dir.chmod(0o700)
    private_key = tmp_path / "id_ed25519"
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(private_key)],
        check=True,
    )
    authorized_keys = ssh_dir / "authorized_keys"
    authorized_keys.write_bytes(private_key.with_suffix(".pub").read_bytes())
    authorized_keys.chmod(0o600)

    script = rf'''
getent() {{ printf 'test:x:{uid}:{uid}:test:{home}:/bin/bash\n'; }}
id() {{ [ "$1" = -u ] && {{ printf '{uid}\n'; return 0; }}; command id "$@"; }}
rldyour::ubuntu_server::probe_as_root() {{
  if [ "$1" = stat ]; then
    shift
    while [ "$#" -gt 1 ]; do shift; done
    python3 - "$1" <<'PY'
import os
import stat
import sys

info = os.stat(sys.argv[1])
print(info.st_uid, format(stat.S_IMODE(info.st_mode), "o"))
PY
  else
    "$@"
  fi
}}
rldyour::ubuntu_server::validate_authorized_keys test
'''
    result = run_server_function(script)
    assert result.returncode == 0, result.stderr + result.stdout

    authorized_keys.write_text("ssh-ed25519 definitely-not-base64\n", encoding="utf-8")
    invalid = run_server_function(script)
    assert invalid.returncode != 0
    assert "no parseable supported public key" in invalid.stdout

    rsa_key = tmp_path / "id_rsa"
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "rsa", "-b", "1024", "-N", "", "-f", str(rsa_key)],
        check=True,
    )
    authorized_keys.write_bytes(rsa_key.with_suffix(".pub").read_bytes())
    too_small = run_server_function(
        script
        + "\neffective=$'pubkeyacceptedalgorithms rsa-sha2-512,rsa-sha2-256\\n"
        "requiredrsasize 2048'\n"
        "rldyour::ubuntu_server::ssh_effective_accepts_validated_key \"$effective\"\n"
    )
    assert too_small.returncode != 0

    wrong_ecdsa_curve = run_server_function(
        "RLDYOUR_VALIDATED_SSH_KEY_RECORDS=ECDSA:521\n"
        "effective=$'pubkeyacceptedalgorithms ecdsa-sha2-nistp256\\n"
        "requiredrsasize 1024'\n"
        "rldyour::ubuntu_server::ssh_effective_accepts_validated_key \"$effective\"\n"
    )
    assert wrong_ecdsa_curve.returncode != 0

    matching_ecdsa_curve = run_server_function(
        "RLDYOUR_VALIDATED_SSH_KEY_RECORDS=ECDSA:521\n"
        "effective=$'pubkeyacceptedalgorithms ecdsa-sha2-nistp521\\n"
        "requiredrsasize 1024'\n"
        "rldyour::ubuntu_server::ssh_effective_accepts_validated_key \"$effective\"\n"
    )
    assert matching_ecdsa_curve.returncode == 0


def test_server_contract_contains_rollback_and_context_guards() -> None:
    server = SERVER.read_text(encoding="utf-8")
    assert "rollback_fail2ban" in server
    assert "fail2ban-client status sshd" in server
    assert "systemctl enable --now fail2ban.service" not in server
    assert "systemctl restart fail2ban.service" in server
    assert "for _ in {1..20}" in server
    assert 'sshd -T -C "$context"' in server
    assert "AuthenticationMethods publickey" in server
    assert "probe_as_root ssh-keygen -l" in server
    assert "NTPSynchronized" in server
    assert "healthy existing Docker CE installation preserved; no package transaction" in server
    assert "partial existing Docker CE package set detected; preserving it without upgrade" in server
    assert 'rldyour::gpg_primary_fingerprint "$tmp_key"' in server
    assert 'if [ "$enable_ufw" -eq 1 ] || [ "$harden_ssh" -eq 1 ]' in server
    assert 'args+=(--ssh-allow-cidr "$allow_cidr")' in server

    server_verify = (ROOT / "scripts/ubuntu/verify-server.sh").read_text(encoding="utf-8")
    assert '--ssh-allow-cidr' in server_verify
    assert 'ufw "$resolved_port" "$ssh_allow_cidr"' in server_verify
    assert 'rldyour::gpg_primary_fingerprint "$key_path"' in server_verify

    # Exactly one primary key is the invariant; it is enforced once, in the
    # library primitive both files delegate to.
    library = (ROOT / "scripts/lib/common.sh").read_text(encoding="utf-8")
    assert 'primary_count != 1' in library

    installer = (ROOT / "scripts/ubuntu/install.sh").read_text(encoding="utf-8")
    assert "rldyour::ubuntu::as_root" in installer
    # Privilege acquisition is owned by the typed state machine; this caller
    # contains only its narrow compatibility adapter and no direct tool dispatch.
    assert "rldyour::privilege::as_root" in installer
    assert "/usr/bin/sudo" not in installer and "/usr/bin/pkexec" not in installer
    assert "sudo apt-get" not in installer
    assert "sudo install" not in installer


def test_ssh_activation_plan_does_not_require_preinstalled_units() -> None:
    result = run_server_function(
        "RLDYOUR_DRY_RUN=1\n"
        "rldyour::ubuntu_server::ensure_ssh_activation\n"
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "[DRY-RUN] preserve and activate" in result.stdout


def test_plan_never_claims_docker_health_it_did_not_observe() -> None:
    """A plan must not report a daemon verdict it never asked for.

    `as_root` routes through rldyour::run, which in plan mode prints the command
    and returns 0 without running it. The health gate used that helper, so every
    plan on a host with the full Docker CE package set printed "healthy existing
    Docker CE installation preserved" without ever contacting the daemon.
    """
    result = run_server_function(
        """
rldyour::ubuntu_server::check_docker_conflicts() { return 0; }
rldyour::ubuntu_server::package_installed() { return 0; }
rldyour::ubuntu_server::docker_rootful_runtime_active() { return 0; }
rldyour::ubuntu_server::probe_as_root() { return 1; }
rldyour::ubuntu_server::install_docker_packages rootful
""",
        env={"RLDYOUR_DRY_RUN": "1"},
    )
    assert result.returncode == 0, result.stderr[-1000:]
    combined = result.stdout + result.stderr
    assert "healthy existing Docker CE installation preserved" not in combined, (
        "the plan claimed a daemon health verdict it never obtained"
    )
    assert "apply will prove daemon health" in combined


def test_plan_reports_health_when_the_read_only_probe_succeeds() -> None:
    """The honest positive case still reports a preserved healthy runtime."""
    result = run_server_function(
        """
rldyour::ubuntu_server::check_docker_conflicts() { return 0; }
rldyour::ubuntu_server::package_installed() { return 0; }
rldyour::ubuntu_server::docker_rootful_runtime_active() { return 0; }
rldyour::ubuntu_server::probe_as_root() { return 0; }
rldyour::ubuntu_server::install_docker_packages rootful
""",
        env={"RLDYOUR_DRY_RUN": "1"},
    )
    assert result.returncode == 0, result.stderr[-1000:]
    assert "healthy existing Docker CE installation preserved" in result.stdout + result.stderr


def test_authorized_keys_readability_is_not_probed_with_external_test() -> None:
    """`test -r` and an actual open disagree on Ubuntu 26.04 (#57).

    Measured as root, with full capabilities, on a mode 0600 file owned by
    another user -- which is exactly what a correct `authorized_keys` is:

        /usr/bin/test -r   24.04: 0    26.04: 1
        bash builtin -r    24.04: 0    26.04: 0
        /usr/bin/test -e   24.04: 0    26.04: 0

    coreutils 9.5 answers `-r` through access(2) without granting root its
    usual override, so `probe_as_root test -r` refused key-only SSH on 26.04
    for a perfectly valid key file. That is a refusal on a real server, not a
    test artifact, and it would have shipped.

    Opening the file answers the question that matters and depends on no
    coreutils or libc policy about what root "may" read.
    """
    server = (ROOT / "scripts/ubuntu/server.sh").read_text(encoding="utf-8")
    block = server.split(
        "rldyour::ubuntu_server::validate_authorized_keys() {", 1
    )[1].split("\n}", 1)[0]

    assert "probe_as_root test -r" not in block, (
        "authorized_keys readability is probed with external `test -r` again; "
        "it disagrees with an open on Ubuntu 26.04"
    )
    assert """probe_as_root sh -c 'exec 3<"$1"'""" in block, (
        "readability is no longer answered by opening the file"
    )
    # The stat-based probes are unaffected and must stay as they are: only the
    # access-permission predicate changed behaviour between releases.
    for predicate in ("test -L", "test -f", "test -d"):
        assert f"probe_as_root {predicate}" in block, (
            f"{predicate} was changed without cause; it is stat-based and portable"
        )
