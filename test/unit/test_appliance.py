"""Unit tests for appliance installs: a deferred install with no questions that
waits for another computer to adopt it over SSH (omarchy-iso-make --appliance).

Covers the InstallContext guards and the phases that stage adoption instead of
first-boot setup, against a temp target with subprocess mocked out.
"""

import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402


class ApplianceContextTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.keys = self.dir / "authorized_keys"
        self.keys.write_text("ssh-ed25519 AAAA adopter\n")
        self.encrypt = self.dir / "user_encrypt_installation.txt"
        self.encrypt.write_text("false\n")

    def from_env(self, config, **extra_env):
        (self.dir / "user_configuration.json").write_text(json.dumps(config))
        env = {
            "OMARCHY_INSTALL_CONFIG": str(self.dir / "user_configuration.json"),
            "OMARCHY_INSTALL_CREDS": str(self.dir / "user_credentials.json"),
            "OMARCHY_INSTALL_STATE_DIR": str(self.dir / "state"),
            "OMARCHY_INSTALL_AUTHORIZED_KEYS_FILE": str(self.keys),
            "OMARCHY_INSTALL_ENCRYPT_FILE": str(self.encrypt),
            **extra_env,
        }
        with mock.patch.dict(os.environ, env, clear=False):
            os.environ.pop("OMARCHY_INSTALL_DEFER_PROVISIONING_FILE", None)
            return InstallContext.from_env()

    def config(self, **disk_config):
        return {
            "disk_config": {"config_type": "default_layout", **disk_config},
            "omarchy_install": {"mode": "full_disk", "target_mount": "/mnt", "appliance": True},
        }

    def test_an_appliance_is_a_deferred_install_with_no_credentials(self):
        ctx = self.from_env(self.config())
        self.assertTrue(ctx.appliance)
        self.assertTrue(ctx.defer_provisioning)
        self.assertEqual(ctx.username, "")

    def test_an_appliance_without_the_adopting_key_is_refused(self):
        self.keys.unlink()
        with self.assertRaisesRegex(RuntimeError, "adopting computer's SSH key"):
            self.from_env(self.config())

    def test_an_encrypted_appliance_is_refused(self):
        self.encrypt.write_text("true\n")
        with self.assertRaisesRegex(RuntimeError, "unencrypted"):
            self.from_env(self.config())
        self.encrypt.write_text("false\n")
        with self.assertRaisesRegex(RuntimeError, "unencrypted"):
            self.from_env(self.config(disk_encryption={"encryption_type": "luks", "partitions": ["x"]}))


def make_ctx(target, keys=None):
    return types.SimpleNamespace(
        target=target,
        defer_provisioning=True,
        appliance=True,
        encrypt=False,
        username="",
        omarchy_install={"mode": "full_disk", "defer_provisioning": True, "appliance": True, "storage": {}},
        user_configuration={"disk_config": {}},
        user_credentials={"users": []},
        state_dir=target / "state",
        authorized_keys_path=keys,
        state={},
    )


class AppliancePhasesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        self.target.mkdir()
        self.calls = []

        for name, patch in (
            ("info", mock.patch.object(phases_impl, "info")),
            ("node", mock.patch.object(phases_impl, "NODE_PACKAGES_DIR", Path(self.tmp.name) / "none")),
            ("platform", mock.patch.object(phases_impl, "hw_platform", return_value="aarch64-gb10")),
            ("run", mock.patch.object(
                phases_impl.subprocess, "run",
                side_effect=lambda cmd, **kw: (self.calls.append(cmd), self.fake_ufw(cmd), CompletedProcess(cmd, 0))[2],
            )),
        ):
            patch.start()
            self.addCleanup(patch.stop)

        for rel, text in (
            ("usr/share/omarchy/install/provisioning/omarchy-provision-owner.service", "[Unit]\n"),
            ("usr/bin/omarchy-provision-owner", "#!/bin/bash\n"),
            ("usr/share/omarchy/version", "4.5.0\n"),
        ):
            path = self.target / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

        self.keys = Path(self.tmp.name) / "authorized_keys"
        self.keys.write_text("# adopter\nssh-ed25519 AAAA adopter@desk\n")

    def fake_ufw(self, cmd):
        # ufw writes its rule file even though it cannot reach netfilter in a chroot.
        if cmd[-2:] == ["allow", "ssh"]:
            rules = self.target / "etc/ufw/user.rules"
            rules.parent.mkdir(parents=True, exist_ok=True)
            rules.write_text("-A ufw-user-input -p tcp --dport 22 -j ACCEPT\n")

    def stage(self):
        ctx = make_ctx(self.target, self.keys)
        phases_impl.stage_provisioning_state(ctx)
        phases_impl.configure_ssh_access(ctx)
        phases_impl.configure_login(ctx)
        return ctx

    def test_adoption_replaces_first_boot_setup(self):
        ctx = self.stage()

        provisioning = self.target / "var/lib/omarchy/provisioning"
        self.assertTrue((provisioning / "pending").exists())
        self.assertTrue((provisioning / "appliance").exists())
        # Nobody is at the console: the tty1 owner setup would hold the boot.
        self.assertFalse((self.target / "etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service").exists())
        # The owner is created over SSH, so the key is not staged for it.
        self.assertFalse((provisioning / "authorized_keys").exists())

        phases_impl._validate_provisioning_state(ctx)

    def test_root_takes_the_adopting_key_by_key_only(self):
        self.stage()

        root_keys = self.target / "root/.ssh/authorized_keys"
        self.assertEqual(root_keys.read_text(), "ssh-ed25519 AAAA adopter@desk\n")
        self.assertEqual(root_keys.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.target / "root/.ssh").stat().st_mode & 0o777, 0o700)
        dropin = (self.target / "etc/ssh/sshd_config.d/20-omarchy-adopt.conf").read_text()
        self.assertIn("PermitRootLogin prohibit-password", dropin)
        self.assertIn("PasswordAuthentication no", dropin)
        self.assertIn(["arch-chroot", str(self.target), "systemctl", "enable", "sshd.service"], self.calls)

    def test_it_boots_headless_until_adopted(self):
        self.stage()

        self.assertIn(["arch-chroot", str(self.target), "systemctl", "disable", "sddm.service"], self.calls)
        self.assertIn(["arch-chroot", str(self.target), "systemctl", "set-default", "multi-user.target"], self.calls)
        self.assertNotIn(["arch-chroot", str(self.target), "systemctl", "enable", "sddm.service"], self.calls)

    def test_it_advertises_itself_for_adoption(self):
        with mock.patch.object(phases_impl, "_adopt_txt_records", wraps=phases_impl._adopt_txt_records):
            self.stage()

        service = (self.target / "etc/avahi/services/omarchy-adopt.service").read_text()
        self.assertIn("<type>_omarchy-adopt._tcp</type>", service)
        self.assertIn("<port>22</port>", service)
        self.assertIn("<txt-record>platform=aarch64-gb10</txt-record>", service)
        self.assertIn("<txt-record>version=4.5.0</txt-record>", service)

    def test_txt_records_are_escaped(self):
        service = phases_impl._adopt_avahi_service({"model": "A&B <Spark>"})
        self.assertIn("<txt-record>model=A&amp;B &lt;Spark&gt;</txt-record>", service)

    def test_a_missing_piece_fails_validation(self):
        ctx = self.stage()
        (self.target / "etc/avahi/services/omarchy-adopt.service").unlink()
        with self.assertRaisesRegex(RuntimeError, "omarchy-adopt.service is missing"):
            phases_impl._validate_provisioning_state(ctx)

    def test_the_factory_image_keeps_no_adoption_access(self):
        self.stage()
        phases_impl._scrub_factory_snapshot(self.target)

        for rel in ("root/.ssh/authorized_keys", "etc/ssh/sshd_config.d/20-omarchy-adopt.conf",
                    "etc/avahi/services/omarchy-adopt.service", "var/lib/omarchy/provisioning/appliance"):
            self.assertFalse((self.target / rel).exists(), rel)


if __name__ == "__main__":
    unittest.main()
