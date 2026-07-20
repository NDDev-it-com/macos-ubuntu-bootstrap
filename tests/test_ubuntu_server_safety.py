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
    assert 'sshd -T -C "$context"' in server
    assert "AuthenticationMethods publickey" in server
    assert "probe_as_root ssh-keygen -l" in server
    assert "NTPSynchronized" in server
    assert "healthy existing Docker CE installation preserved; no package transaction" in server
    assert "partial existing Docker CE package set detected; preserving it without upgrade" in server
    assert 'primary_count != 1' in server
    assert 'if [ "$enable_ufw" -eq 1 ] || [ "$harden_ssh" -eq 1 ]' in server
    assert 'args+=(--ssh-allow-cidr "$allow_cidr")' in server

    server_verify = (ROOT / "scripts/ubuntu/verify-server.sh").read_text(encoding="utf-8")
    assert '--ssh-allow-cidr' in server_verify
    assert 'ufw "$resolved_port" "$ssh_allow_cidr"' in server_verify
    assert 'primary_count != 1' in server_verify

    installer = (ROOT / "scripts/ubuntu/install.sh").read_text(encoding="utf-8")
    assert "rldyour::ubuntu::as_root" in installer
    # sudo exists only inside the root-aware helper; all call sites delegate.
    assert installer.count("rldyour::run sudo") == 2
    assert "sudo apt-get" not in installer
    assert "sudo install" not in installer
