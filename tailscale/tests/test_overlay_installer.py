import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install_recovery_patch.sh"
UNINSTALLER = ROOT / "uninstall_recovery_patch.sh"


class OverlayInstallerTest(unittest.TestCase):
    def test_install_and_uninstall_preserve_original_plugin(self):
        with tempfile.TemporaryDirectory() as tmp:
            ks = pathlib.Path(tmp) / "koolshare"
            for name in ("scripts", "init.d", "webs", "configs/tailscale"):
                (ks / name).mkdir(parents=True, exist_ok=True)
            plugin = ks / "scripts/tailscale_config"
            plugin.write_text("plugin-core")
            plugin.chmod(0o755)
            original = ks / "webs/Module_tailscale.asp"
            original.write_text("original-web\nfunction get_tcnets_status(){}\n")

            env = os.environ.copy()
            env.update({"KS_ROOT": str(ks), "SKIP_RECOVERY": "1"})
            installed = subprocess.run(
                ["sh", str(INSTALLER)], env=env, text=True, capture_output=True
            )
            self.assertEqual(installed.returncode, 0, installed.stderr)
            self.assertTrue((ks / "scripts/tailscale_recover.sh").exists())
            self.assertTrue((ks / "init.d/S97tailscale-recover.sh").exists())
            self.assertIn("tailscale_recover_status", original.read_text())
            backup = ks / "configs/tailscale/recovery-patch-backup/Module_tailscale.asp"
            self.assertEqual(backup.read_text(), "original-web\nfunction get_tcnets_status(){}\n")

            removed = subprocess.run(
                ["sh", str(UNINSTALLER)], env=env, text=True, capture_output=True
            )
            self.assertEqual(removed.returncode, 0, removed.stderr)
            self.assertFalse((ks / "scripts/tailscale_recover.sh").exists())
            self.assertFalse((ks / "init.d/S97tailscale-recover.sh").exists())
            self.assertEqual(original.read_text(), "original-web\nfunction get_tcnets_status(){}\n")


if __name__ == "__main__":
    unittest.main()
