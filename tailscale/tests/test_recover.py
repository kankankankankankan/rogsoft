import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RECOVER = ROOT / "tailscale" / "scripts-hnd" / "tailscale_recover.sh"
HOOK = ROOT / "tailscale" / "init.d" / "S97tailscale-recover.sh"
WEB = ROOT / "tailscale" / "webs" / "Module_tailscale.asp"


class RecoverScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = pathlib.Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.state = self.dir / "healthy"
        self.log = self.dir / "tailscale.calls"
        self.status = self.dir / "status.txt"
        self.lock = self.dir / "lock"
        self._write_exe(
            "ip",
            """
            #!/bin/sh
            if [ "$(cat "$TS_TEST_STATE")" = "1" ]; then
                case "$*" in
                    *"addr show dev tailscale0"*) echo "inet 100.66.82.121/32 scope global tailscale0" ;;
                    *"route show table 52"*) echo "100.126.101.39 dev tailscale0" ;;
                    *"route show dev br0"*) echo "192.168.50.0/24 dev br0 scope link" ;;
                esac
            else
                case "$*" in
                    *"route show dev br0"*) echo "192.168.50.0/24 dev br0 scope link" ;;
                esac
            fi
            """,
        )
        self._write_exe(
            "tailscale",
            """
            #!/bin/sh
            printf '%s\n' "$*" >>"$TS_TEST_CALLS"
            if [ "$1" = "up" ] && [ "${TS_TEST_UP_SUCCEEDS:-1}" = "1" ]; then
                printf '1\n' >"$TS_TEST_STATE"
            fi
            exit 0
            """,
        )
        self._write_exe(
            "dbus",
            """
            #!/bin/sh
            case "$2" in
                tailscale_accept_routes|tailscale_advertise_routes) echo 1 ;;
                tailscale_exit_node) echo 0 ;;
                *) echo "" ;;
            esac
            """,
        )
        self._write_exe("sleep", "#!/bin/sh\nexit 0\n")
        self._write_exe(
            "logger",
            "#!/bin/sh\nprintf '%s\n' \"$*\" >>\"$TS_TEST_LOGGER\"\n",
        )

    def _write_exe(self, name, body):
        path = self.bin / name
        path.write_text(textwrap.dedent(body).lstrip())
        path.chmod(0o755)

    def run_recover(self, healthy, up_succeeds=True):
        self.state.write_text("1\n" if healthy else "0\n")
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin}:{env['PATH']}",
                "TS_BIN": str(self.bin / "tailscale"),
                "IP_BIN": str(self.bin / "ip"),
                "DBUS_BIN": str(self.bin / "dbus"),
                "LOGGER_BIN": str(self.bin / "logger"),
                "SLEEP_BIN": str(self.bin / "sleep"),
                "TS_RECOVER_DELAY": "0",
                "TS_RECOVER_FOREGROUND": "1",
                "TS_RECOVER_LOCK": str(self.lock),
                "TS_RECOVER_STATUS": str(self.status),
                "TS_TEST_STATE": str(self.state),
                "TS_TEST_CALLS": str(self.log),
                "TS_TEST_LOGGER": str(self.dir / "logger.txt"),
                "TS_TEST_UP_SUCCEEDS": "1" if up_succeeds else "0",
            }
        )
        return subprocess.run(
            ["sh", str(RECOVER), "start"],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def test_healthy_dataplane_is_not_restarted(self):
        result = self.run_recover(healthy=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        self.assertNotIn("down", calls)
        self.assertFalse(any(call.startswith("up ") for call in calls))
        self.assertIn("状态：正常", self.status.read_text())

    def test_broken_dataplane_runs_down_up_with_preserved_plugin_flags(self):
        result = self.run_recover(healthy=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertIn("down", calls)
        up = next(call for call in calls if call.startswith("up "))
        self.assertIn("up", up)
        self.assertIn("--accept-routes=true", up)
        self.assertIn("--accept-dns=false", up)
        self.assertIn("--advertise-routes=192.168.50.0/24", up)
        self.assertIn("--snat-subnet-routes=false", up)
        self.assertIn("--stateful-filtering=false", up)
        self.assertIn("--netfilter-mode=on", up)
        self.assertIn("--auto-update=true", up)
        self.assertIn("状态：已恢复", self.status.read_text())

    def test_failed_recovery_is_reported(self):
        result = self.run_recover(healthy=False, up_succeeds=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("状态：恢复失败", self.status.read_text())

    def test_wan_hook_starts_recovery(self):
        hook = HOOK.read_text()
        self.assertIn("tailscale_recover.sh start", hook)

    def test_panel_displays_recovery_status(self):
        web = WEB.read_text()
        self.assertIn("get_recover_status", web)
        self.assertIn('id="tailscale_recover_status"', web)


if __name__ == "__main__":
    unittest.main()
