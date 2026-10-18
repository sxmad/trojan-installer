#!/usr/bin/env python3
"""Exercise generated renewal scripts and BBR without root, ACME or host changes."""
import os
import json
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
    def test_empty_explicit_password_is_not_replaced_with_random(self):
        result = shell('DOMAIN=example.com; EMAIL=admin@example.com; PASSWORD_FROM_STDIN=1; validate_inputs', input='\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('指定的密码不能为空', result.stderr)

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


class PlatformTests(unittest.TestCase):
    def preflight(self, os_id, os_version, requested=None):
        with tempfile.TemporaryDirectory(prefix="trojan-platform-test-") as work:
            base = Path(work)
            os_release = base / "os-release"
            os_release.write_text(f'ID={os_id}\nVERSION="{os_version}"\nVERSION_ID="test"\n')
            systemd = base / "systemd"
            systemd.mkdir()
            source = (ROOT / "install.sh").read_text()
            source = source.replace("/etc/os-release", str(os_release))
            source = source.replace("/run/systemd/system", str(systemd))
            fixture = base / "installer.sh"
            fixture.write_text(source)
            args = ["install", "--domain", "example.com", "--email", "admin@example.com", "--port", "8443"]
            if requested is not None:
                args += ["--version", requested]
            return subprocess.run([
                "bash", "-c", r'''source "$1"; shift
# Follow the actual main -> install -> platform -> input validation path.
# Stop before DNS, ACME or any service/filesystem changes on the host.
require_root() { :; }
install_prerequisites() { echo DEPS_CHECKED; }
lego() { :; }
VERSION=caller-version
ID=caller-id
resolve_release() {
  [[ "$VERSION" == caller-version && "$ID" == caller-id ]]
  printf 'PREFLIGHT_OK version=%s port=%s\n' "$REQUESTED_TROJAN_VERSION" "$PORT"
  exit 0
}
main "$@"
''', "test", str(fixture), *args,
            ], text=True, capture_output=True)

    def test_default_after_real_platform_and_input_flow(self):
        for os_id, version in [("debian", "12 (bookworm)"), ("debian", "13 (trixie)"),
                               ("ubuntu", "24.04.3 LTS (Noble Numbat)")]:
            with self.subTest(os_id=os_id, version=version):
                result = self.preflight(os_id, version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("PREFLIGHT_OK version=latest port=8443", result.stdout)

    def test_explicit_version_survives_platform_detection(self):
        result = self.preflight("debian", "12 (bookworm)", "v1.16.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PREFLIGHT_OK version=v1.16.0 port=8443", result.stdout)

    def test_invalid_version_stops_before_dependencies(self):
        result = self.preflight("ubuntu", "24.04 LTS", "bad-version")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("DEPS_CHECKED", result.stdout)


class ReleaseTests(unittest.TestCase):
    @staticmethod
    def metadata(version="1.16.0", digest=None):
        name = f"trojan-{version}-linux-amd64.tar.xz"
        return {"tag_name": f"v{version}", "draft": False, "prerelease": False,
                "assets": [{"name": name, "state": "uploaded", "digest": digest,
                            "browser_download_url": f"https://github.com/trojan-gfw/trojan/releases/download/v{version}/{name}"}]}

    def parse(self, metadata, requested="latest", ok=True):
        with tempfile.TemporaryDirectory(prefix="trojan-release-test-") as work:
            path = Path(work) / "release.json"
            path.write_text(json.dumps(metadata))
            result = shell(f"REQUESTED_TROJAN_VERSION={shlex.quote(requested)}; "
                           f"parse_release_metadata {shlex.quote(str(path))}")
            self.assertEqual(result.returncode == 0, ok, result.stderr)
            return result.stdout.splitlines()

    def test_latest_current_release_uses_known_checksum(self):
        fields = self.parse(self.metadata())
        self.assertEqual(fields[0], "1.16.0")
        self.assertEqual(fields[3], "daad1ab6edd3f89066c5e1f42c6618b2f8cb59b7ba375dfb043d0c62c9e254ea")

    def test_new_stable_release_requires_official_sha256(self):
        fields = self.parse(self.metadata("9.8.7", "sha256:" + "ab" * 32))
        self.assertEqual(fields[0], "9.8.7")
        self.assertEqual(fields[3], "ab" * 32)
        self.parse(self.metadata("9.8.7"), ok=False)

    def test_reject_conflicting_known_checksum(self):
        self.parse(self.metadata(digest="sha256:" + "00" * 32), ok=False)

    def test_reject_wrong_tag_prerelease_and_external_url(self):
        self.parse(self.metadata(), requested="v9.8.7", ok=False)
        metadata = self.metadata()
        metadata["prerelease"] = True
        self.parse(metadata, ok=False)
        metadata = self.metadata()
        metadata["assets"][0]["browser_download_url"] = "https://example.com/untrusted.tar.xz"
        self.parse(metadata, ok=False)

    def test_reject_missing_and_duplicate_assets(self):
        metadata = self.metadata()
        metadata["assets"] *= 2
        self.parse(metadata, ok=False)
        metadata["assets"] = []
        self.parse(metadata, ok=False)

    def test_pinned_release_does_not_need_metadata_network(self):
        result = shell('''REQUESTED_TROJAN_VERSION=1.16.0
curl() { echo 'unexpected network call' >&2; return 99; }
resolve_release
[[ "$REQUESTED_TROJAN_VERSION" == v1.16.0 && "$TROJAN_VERSION" == 1.16.0 ]]
[[ "$TROJAN_SHA256" == "$VERIFIED_TROJAN_SHA256" ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_latest_resolution_fetches_and_parses_metadata(self):
        with tempfile.TemporaryDirectory(prefix="trojan-latest-test-") as work:
            fixture = Path(work) / "release.json"
            fixture.write_text(json.dumps(self.metadata()))
            result = shell(r'''
curl() {
  local dest='' url=''
  while (($#)); do
    case "$1" in
      -o) dest="$2"; shift 2 ;;
      https://*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  [[ "$url" == https://api.github.com/repos/trojan-gfw/trojan/releases/latest ]]
  cp "$RELEASE_FIXTURE" "$dest"
}
resolve_release
[[ "$TROJAN_VERSION" == 1.16.0 && "$TROJAN_SHA256" == "$VERIFIED_TROJAN_SHA256" ]]
''', env=dict(os.environ, RELEASE_FIXTURE=str(fixture)))
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_latest_failure_does_not_silently_fall_back(self):
        result = shell('curl() { return 22; }; resolve_release')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--version v1.16.0", result.stderr)


class IssuanceTests(unittest.TestCase):
    def issue(self, failure_log, succeed_on=0):
        with tempfile.TemporaryDirectory(prefix="trojan-issuance-test-") as work:
            base = Path(work)
            (base / "failure.log").write_text(failure_log)
            source = (ROOT / "install.sh").read_text()
            source = source.replace('readonly LEGO_DIR="${HOME_DIR}/lego"',
                                    f"readonly LEGO_DIR={shlex.quote(str(base / 'lego'))}")
            source = source.replace('/run/lock/trojan-cert-renew.lock', str(base / 'acme.lock'))
            # Exercise interactive retry choices without requiring a terminal in CI.
            source = source.replace('if [[ -t 0 ]]; then', 'if true; then')
            fixture = base / "installer.sh"
            fixture.write_text(source)
            result = subprocess.run([
                "bash", "-c", r'''source "$1"
DOMAIN=example.com
EMAIL=admin@example.com
PORT=8443
LEGO_BIN=lego
install() { mkdir -p "$LEGO_DIR"; }
port_in_use() { return 1; }
cert_valid() { [[ -f "$TEST_WORK/valid" ]]; }
sync_certificate() { echo CERT_DEPLOYED; }
sleep() { :; }
timeout() {
  local IFS=' '
  [[ " $* " == *" --http "* && " $* " != *" --tls "* ]] || return 99
  echo attempt >> "$TEST_WORK/calls"
  if [[ "$SUCCEED_ON" != 0 ]] && (( $(wc -l < "$TEST_WORK/calls") >= SUCCEED_ON )); then
    touch "$TEST_WORK/valid"
    echo '[INFO] Certificate obtained'
    return 0
  fi
  cat "$TEST_WORK/failure.log"
  return 1
}
obtain_certificate
''', "test", str(fixture),
            ], input="1\n1\n1\n", text=True, capture_output=True,
                env=dict(os.environ, TEST_WORK=work, SUCCEED_ON=str(succeed_on)))
            self.assertTrue((base / "calls").exists(), result.stdout + result.stderr)
            calls = (base / "calls").read_text().splitlines()
            return result, calls

    def test_http_connection_failures_stop_before_another_ca_request(self):
        for reason in ["Timeout during connect (likely firewall problem)", "Connection refused"]:
            with self.subTest(reason=reason):
                result, calls = self.issue(
                    "[INFO] acme: Could not find solver for: tls-alpn-01\n"
                    "[INFO] acme: use http-01 solver\n"
                    "[example.com] acme: error: 400 :: urn:ietf:params:acme:error:connection :: "
                    f"192.0.2.1: Fetching http://example.com/.well-known/acme-challenge/test: {reason}\n"
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)
                self.assertIn("TCP 80", result.stderr)
                self.assertIn("example.com", result.stderr)
                self.assertIn("--port 8443", result.stderr)
                self.assertNotIn("CERT_DEPLOYED", result.stdout)

    def test_informational_solver_line_does_not_prevent_retry_success(self):
        result, calls = self.issue(
            "[INFO] acme: Could not find solver for: tls-alpn-01\n"
            "[INFO] acme: use http-01 solver\n"
            "acme: error: 400 :: urn:ietf:params:acme:error:badNonce :: Invalid nonce\n",
            succeed_on=2,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("CERT_DEPLOYED", result.stdout)

    def test_unknown_failures_keep_the_retry_limit(self):
        result, calls = self.issue("unexpected ACME failure\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 3)
        self.assertIn("连续失败 3 次", result.stderr)
        self.assertNotIn("CERT_DEPLOYED", result.stdout)

    def test_rate_limit_still_stops_before_retry(self):
        result, calls = self.issue("urn:ietf:params:acme:error:rateLimited :: too many certificates\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertIn("CA 速率限制", result.stderr)


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
