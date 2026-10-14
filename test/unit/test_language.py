#!/usr/bin/python

import inspect
import json
import os
import re
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import language as LANGUAGE  # noqa: E402
from orchestrator import phases_impl  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402

REGISTRY = {
    "en": {"englishName": "English", "locale": "en_US.UTF-8"},
    "da": {"englishName": "Danish", "locale": "da_DK.UTF-8"},
    "pt-BR": {"englishName": "Portuguese (Brazil)", "locale": "pt_BR.UTF-8"},
    "ja": {"englishName": "Japanese", "locale": "ja_JP.UTF-8", "console": False},
}


class LanguageValidationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.omarchy_path = Path(self.tmp.name) / "omarchy"
        registry = self.omarchy_path / "default/i18n/locales.json"
        registry.parent.mkdir(parents=True)
        registry.write_text(json.dumps(REGISTRY))
        patcher = mock.patch.dict(os.environ, {"OMARCHY_PATH": str(self.omarchy_path)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_registry_languages_pass_through(self):
        # Including the ones the console can't draw: the installer falls back
        # to English, but the installed system boots in them.
        for code in ("en", "da", "pt-BR", "ja"):
            with self.subTest(code=code):
                self.assertEqual(LANGUAGE.validate_language(code), code)

    def test_absent_language_means_english(self):
        for value in (None, ""):
            with self.subTest(value=value):
                self.assertEqual(LANGUAGE.validate_language(value), "en")

    def test_unknown_or_malformed_languages_are_rejected(self):
        for value in ("xx", "DA", "da_DK.UTF-8", "../../etc/passwd", "da\nen", ["da"], 1):
            with self.subTest(value=value), self.assertRaises(ValueError):
                LANGUAGE.validate_language(value)

    def test_without_a_registry_only_english_is_known(self):
        (self.omarchy_path / "default/i18n/locales.json").unlink()
        self.assertEqual(LANGUAGE.validate_language("en"), "en")
        with self.assertRaises(ValueError):
            LANGUAGE.validate_language("da")

    def test_configure_language_writes_the_code_into_the_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            LANGUAGE.configure_language(target, "pt-BR")
            self.assertEqual((target / "etc/omarchy/language").read_text(), "pt-BR\n")


class ContextLanguageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        registry = self.dir / "omarchy/default/i18n/locales.json"
        registry.parent.mkdir(parents=True)
        registry.write_text(json.dumps(REGISTRY))
        (self.dir / "user_credentials.json").write_text(
            json.dumps({"users": [{"username": "omarchy", "enc_password": "x"}]})
        )
        self.env = {
            "OMARCHY_PATH": str(self.dir / "omarchy"),
            "OMARCHY_INSTALL_CONFIG": str(self.dir / "user_configuration.json"),
            "OMARCHY_INSTALL_CREDS": str(self.dir / "user_credentials.json"),
            "OMARCHY_INSTALL_STATE_DIR": str(self.dir / "state"),
        }

    def from_env(self, omarchy_install):
        config = {
            "disk_config": {"config_type": "default_layout"},
            "kernels": ["linux-omarchy"],
            "locale_config": {"kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "da_DK.UTF-8"},
        }
        if omarchy_install is not None:
            config["omarchy_install"] = omarchy_install
        (self.dir / "user_configuration.json").write_text(json.dumps(config))
        with mock.patch.dict(os.environ, self.env):
            os.environ.pop("OMARCHY_INSTALL_DEFER_PROVISIONING_FILE", None)
            return InstallContext.from_env()

    def test_configured_language_is_kept(self):
        ctx = self.from_env({"mode": "full_disk", "language": "da"})
        self.assertEqual(ctx.omarchy_install["language"], "da")

    def test_config_without_language_installs_english(self):
        ctx = self.from_env({"mode": "full_disk"})
        self.assertEqual(ctx.omarchy_install["language"], "en")

    def test_config_without_omarchy_install_installs_english(self):
        ctx = self.from_env(None)
        self.assertEqual(ctx.omarchy_install["language"], "en")

    def test_unknown_language_fails_before_anything_is_installed(self):
        with self.assertRaises(ValueError):
            self.from_env({"mode": "full_disk", "language": "klingon"})
        self.assertFalse((self.dir / "state/archinstall-user_configuration.json").exists())

    def test_language_stays_out_of_the_archinstall_config(self):
        self.from_env({"mode": "full_disk", "language": "da"})
        arch_config = json.loads((self.dir / "state/archinstall-user_configuration.json").read_text())
        self.assertNotIn("omarchy_install", arch_config)
        self.assertEqual(arch_config["locale_config"]["sys_lang"], "da_DK.UTF-8")


class LanguageOrderTest(unittest.TestCase):
    """The user install (install/user/language.sh, run by omarchy-provision-user
    in the "Finalizing user" phase) reads /etc/omarchy/language, so the target
    must hold it before that phase, and before the user exists at all."""

    def test_language_is_written_before_the_user_is_created(self):
        source = inspect.getsource(phases_impl.arch_install_system)
        written = source.index("configure_language(")
        self.assertLess(written, source.index("installer.create_users("))
        self.assertLess(written, source.index("_runtime_package_list(ctx)"))

    def test_install_phase_runs_before_user_finalization(self):
        main = (ROOT / "configs/airootfs/usr/share/omarchy-iso/orchestrator/main.py").read_text()
        phases = re.findall(r'^\s*\("[^"]+",\s*(\w+)\),', main, re.MULTILINE)
        self.assertIn("arch_install_system", phases)
        self.assertIn("run_chroot_finalizer", phases)
        self.assertLess(phases.index("arch_install_system"), phases.index("run_chroot_finalizer"))


if __name__ == "__main__":
    unittest.main()
