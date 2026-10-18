#!/usr/bin/env python3
"""Exercise generated renewal scripts and BBR without root, ACME or host changes."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def shell(body, **kwargs):
    return subprocess.run(
        ["bash", "-c", 'source "$1"; ' + body, "test", str(ROOT / "install.sh")],
        text=True, capture_output=True, **kwargs,
    )


def executable(path, body):
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
    path.chmod(0o755)


class GenerationTests(unittest.TestCase):
    def test_service_generation_under_nounset(self):
        with tempfile.TemporaryDirectory(prefix="trojan-unit-test-") as work:
            base = Path(work)
            units = base / "units"
            units.mkdir()
            renewal = base / "renew.sh"
            source = (ROOT / "install.sh").read_text()
            source = source.replace("/etc/systemd/system", str(units))
            source = source.replace("/usr/local/sbin/trojan-renew-cert", str(renewal))
            fixture = base / "installer.sh"
            fixture.write_text(source)
            result = subprocess.run([
                "bash", "-c", 'source "$1"; unset rc; DOMAIN=example.com; LEGO_BIN=/bin/true; '
                'systemctl() { :; }; write_service; write_renewal_service',
                "test", str(fixture),
            ], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run(["bash", "-n", str(renewal)], check=True)
            self.assertIn("ExecReload=/bin/kill -USR1 $MAINPID", (units / "trojan.service").read_text())
            self.assertIn(f"ExecStart={renewal}", (units / "trojan-cert-renew.service").read_text())
            self.assertEqual(renewal.stat().st_mode & 0o777, 0o750)


class RenewalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory(prefix="trojan-cert-fixtures-")
        cls.fixture_dir = Path(cls.fixtures.name)
        for name, days, domain in [("old", 1, "example.com"), ("new", 90, "example.com"),
                                   ("wrong", 90, "other.example.com")]:
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-days", str(days), "-subj", f"/CN={domain}",
                "-addext", f"subjectAltName=DNS:{domain}",
                "-keyout", str(cls.fixture_dir / f"{name}.key"),
                "-out", str(cls.fixture_dir / f"{name}.crt"),
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        cls.fixtures.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="trojan-renew-test-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.cache = self.work / "lego" / "certificates"
        self.cache.mkdir(parents=True)
        self.log = self.work / "calls"
        self.log.touch()
        self.pending = self.work / "pending"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_WORK=str(self.work), FIXTURES=str(self.fixture_dir),
                        REAL_INSTALL=shutil.which("install"), ACTIVE="1")
        executable(self.bin / "systemctl", '''
echo "systemctl $*" >> "$TEST_WORK/calls"
case "$1" in
  is-active) [[ "$ACTIVE" == 1 ]] ;;
  reload) [[ ! -f "$TEST_WORK/fail-reload" ]] ;;
  *) echo 'unexpected service interruption' >&2; exit 99 ;;
esac
''')
        executable(self.bin / "lego", '''
echo "lego $*" >> "$TEST_WORK/calls"
[[ " $* " == *" --http "* && " $* " != *" --tls "* ]]
[[ ! -f "$TEST_WORK/fail-acme" ]]
name=new
[[ ! -f "$TEST_WORK/wrong-cert" ]] || name=wrong
cp "$FIXTURES/$name.crt" "$TEST_WORK/lego/certificates/example.com.crt"
cp "$FIXTURES/$name.key" "$TEST_WORK/lego/certificates/example.com.key"
''')
        executable(self.bin / "install", '''
[[ ! -f "$TEST_WORK/fail-copy" ]]
args=()
while (($#)); do
  case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec "$REAL_INSTALL" "${args[@]}"
''')
        executable(self.bin / "trojan", '''
echo "trojan $*" >> "$TEST_WORK/calls"
[[ ! -f "$TEST_WORK/fail-config" ]]
''')
        result = shell('unset rc; DOMAIN=example.com; LEGO_BIN=/usr/bin/lego; render_renewal_script')
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = result.stdout
        overrides = {
            "lego_dir": self.work / "lego", "cert_file": self.work / "cert.pem",
            "key_file": self.work / "key.pem", "lego_bin": self.bin / "lego",
            "trojan_bin": self.bin / "trojan", "config_file": self.work / "server.json",
            "pending_file": self.pending, "lock_file": self.work / "renew.lock",
        }
        for key, value in overrides.items():
            rendered, count = re.subn(rf"^{key}=.*$", f"{key}={shlex.quote(str(value))}",
                                     rendered, count=1, flags=re.M)
            self.assertEqual(count, 1)
        self.script = self.work / "renew.sh"
        self.script.write_text(rendered)
        subprocess.run(["bash", "-n", str(self.script)], check=True)
        self.set_pair("old")
        self.deploy_pair("old")

    def set_pair(self, name):
        for suffix in ("crt", "key"):
            shutil.copyfile(self.fixture_dir / f"{name}.{suffix}", self.cache / f"example.com.{suffix}")

    def deploy_pair(self, name):
        shutil.copyfile(self.fixture_dir / f"{name}.crt", self.work / "cert.pem")
        shutil.copyfile(self.fixture_dir / f"{name}.key", self.work / "key.pem")

    def run_renew(self, ok=True):
        result = subprocess.run(["bash", str(self.script)], env=self.env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        calls = self.log.read_text()
        self.assertNotRegex(calls, r"systemctl (stop|start|restart)")
        return calls

    def test_http_renewal_reloads_and_keeps_service_running(self):
        calls = self.run_renew()
        self.assertIn("--http renew --days 30", calls)
        self.assertIn("systemctl reload trojan.service", calls)
        self.assertEqual((self.work / "cert.pem").read_bytes(), (self.fixture_dir / "new.crt").read_bytes())
        self.assertEqual((self.work / "key.pem").stat().st_mode & 0o777, 0o640)
        self.assertFalse(self.pending.exists())

    def test_fresh_deployed_pair_does_nothing(self):
        self.set_pair("new")
        self.deploy_pair("new")
        self.assertEqual(self.run_renew(), "")

    def test_acme_failure_preserves_deployed_pair(self):
        (self.work / "fail-acme").touch()
        calls = self.run_renew(ok=False)
        self.assertNotIn("systemctl", calls)
        self.assertEqual((self.work / "cert.pem").read_bytes(), (self.fixture_dir / "old.crt").read_bytes())

    def test_wrong_hostname_is_not_deployed(self):
        (self.work / "wrong-cert").touch()
        self.run_renew(ok=False)
        self.assertEqual((self.work / "cert.pem").read_bytes(), (self.fixture_dir / "old.crt").read_bytes())

    def test_mismatched_key_is_not_deployed(self):
        self.set_pair("new")
        shutil.copyfile(self.fixture_dir / "old.key", self.cache / "example.com.key")
        (self.work / "fail-acme").touch()
        self.run_renew(ok=False)
        self.assertEqual((self.work / "key.pem").read_bytes(), (self.fixture_dir / "old.key").read_bytes())

    def test_copy_failure_retries_cached_new_certificate(self):
        (self.work / "fail-copy").touch()
        self.run_renew(ok=False)
        self.assertTrue(self.pending.exists())
        (self.work / "fail-copy").unlink()
        self.log.write_text("")
        calls = self.run_renew()
        self.assertNotIn("lego", calls)
        self.assertIn("systemctl reload", calls)

    def test_reload_failure_retries_even_when_files_match(self):
        (self.work / "fail-reload").touch()
        self.run_renew(ok=False)
        self.assertTrue(self.pending.exists())
        (self.work / "fail-reload").unlink()
        self.log.write_text("")
        calls = self.run_renew()
        self.assertNotIn("lego", calls)
        self.assertIn("systemctl reload", calls)
        self.assertFalse(self.pending.exists())

    def test_config_failure_does_not_reload(self):
        (self.work / "fail-config").touch()
        calls = self.run_renew(ok=False)
        self.assertNotIn("systemctl reload", calls)
        self.assertTrue(self.pending.exists())

    def test_stopped_service_remains_stopped(self):
        self.env["ACTIVE"] = "0"
        calls = self.run_renew()
        self.assertNotIn("systemctl reload", calls)
        self.assertFalse(self.pending.exists())


class BBRTests(unittest.TestCase):
    def scenario(self, body):
        with tempfile.TemporaryDirectory(prefix="trojan-bbr-test-") as work:
            env = dict(os.environ, TEST_WORK=work)
            result = shell(r'''
cc=cubic; qdisc=fq_codel; available='reno cubic'; calls=''
sysctl() {
  calls+="sysctl $*;"
  case "$1 $2" in
    '-n net.ipv4.tcp_available_congestion_control') echo "$available" ;;
    '-n net.ipv4.tcp_congestion_control') echo "$cc" ;;
    '-n net.core.default_qdisc') echo "$qdisc" ;;
    '-p '*) qdisc=fq; [[ "${fail_apply:-0}" == 0 ]] || return 1; cc=bbr ;;
    '-w net.ipv4.tcp_congestion_control='*) cc="${2#*=}" ;;
    '-w net.core.default_qdisc='*) qdisc="${2#*=}" ;;
    *) return 99 ;;
  esac
}
modprobe() {
  calls+="modprobe $*;"
  [[ "${unsupported:-0}" == 0 ]] || return 1
  [[ "$1" != tcp_bbr ]] || available+=' bbr'
}
conf="$TEST_WORK/bbr.conf"
''' + body, env=env)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_default_loads_builtin_module_and_persists(self):
        self.scenario('''configure_bbr "$conf"
[[ "$cc" == bbr && "$qdisc" == fq && "$BBR_CREATED" == 1 ]]
[[ "$BBR_OLD_CC" == cubic && "$BBR_OLD_QDISC" == fq_codel ]]
[[ "$calls" == *"modprobe tcp_bbr"* ]]
grep -qx 'net.ipv4.tcp_congestion_control=bbr' "$conf"
''')

    def test_skip_does_not_change_existing_settings(self):
        self.scenario('''ENABLE_BBR=0; configure_bbr "$conf"
[[ "$calls" == '' && ! -e "$conf" && "$cc" == cubic ]]
''')

    def test_unsupported_is_nonfatal_and_unchanged(self):
        self.scenario('''unsupported=1; configure_bbr "$conf"
[[ "$cc" == cubic && "$qdisc" == fq_codel && ! -e "$conf" ]]
''')

    def test_partial_apply_failure_restores_settings(self):
        self.scenario('''fail_apply=1; configure_bbr "$conf"
[[ "$cc" == cubic && "$qdisc" == fq_codel && ! -e "$conf" && "$BBR_CREATED" == 0 ]]
''')

    def test_unmanaged_config_is_preserved(self):
        self.scenario('''echo '# someone else' > "$conf"; configure_bbr "$conf"
[[ "$calls" == '' ]]
grep -qx '# someone else' "$conf"
''')


if __name__ == "__main__":
    unittest.main(verbosity=2)
