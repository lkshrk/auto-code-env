import re
from pathlib import Path
import unittest


WORKER = Path(__file__).resolve().parents[1]


class TriggerTests(unittest.TestCase):
    def test_activation_is_only_enable_and_verify(self):
        source = (WORKER / "install/common.ps1").read_text()
        activation = source.split("function Invoke-WorkerActivation {", 1)[1].split("\nfunction ", 1)[0]
        self.assertNotIn("Settings", activation)
        self.assertNotIn("Profile", activation)
        self.assertEqual(re.findall(r'& \$Overlay @\("([^" ]+)"\)', activation), ["enable", "verify"])

    def test_only_new_setup_bootstraps(self):
        setup = (WORKER / "install/setup.ps1").read_text()
        update = (WORKER / "install/update.ps1").read_text()
        self.assertIn("Invoke-WorkerBootstrap -Overlay", setup)
        for trigger in ("Get-WorkerSettingsCommand", "Invoke-WorkerBootstrap", "Get-WorkerGuestProfilePaths"):
            self.assertNotIn(trigger, update)
        self.assertLess(setup.index('"update.ps1") @updateParameters'), setup.index("Invoke-WorkerBootstrap -Overlay"))

    def test_bootstrap_waits_before_settings(self):
        source = (WORKER / "install/common.ps1").read_text()
        bootstrap = source.split("function Invoke-WorkerBootstrap {", 1)[1]
        self.assertLess(bootstrap.index("Invoke-WorkerActivation"), bootstrap.index("& $WaitReady"))
        self.assertLess(bootstrap.index("& $WaitReady"), bootstrap.index("Get-WorkerSettingsCommand"))
        setup = (WORKER / "install/setup.ps1").read_text()
        self.assertIn("-WaitReady { Wait-WorkerBackendReady", setup)

    def test_update_waits_for_authenticated_backend(self):
        source = (WORKER / "install/update.ps1").read_text()
        activation = source.split("-ActivateStaging {", 1)[1].split("-ResolveDistribution", 1)[0]
        self.assertIn("Wait-WorkerBackendReady -WslPath $wslPath -Distro $name", activation)
        self.assertLess(activation.index("Invoke-WorkerActivation"), activation.index("Wait-WorkerBackendReady"))

    def test_startup_has_no_profile_apply(self):
        paths = list((WORKER / "image").glob("rootfs*/etc/systemd/**/*.service"))
        paths += list((WORKER / "image").glob("rootfs*/etc/systemd/**/*.timer"))
        paths += [WORKER / "image/rootfs-oci/usr/local/sbin/container-entrypoint"]
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(path=path):
                self.assertNotRegex(path.read_text(), r"apply-profile|overlay\s+settings|Invoke-WorkerBootstrap")


if __name__ == "__main__":
    unittest.main()
