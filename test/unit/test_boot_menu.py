"""Unit tests for the boot menus.

The x86_64 menus offer Install and Try and nothing else, in GRUB (UEFI, and an
ISO file booted through loopback.cfg) and in syslinux (BIOS), with the same
countdown.
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GRUB = ROOT / "configs/grub"
SYSLINUX = ROOT / "configs/syslinux"


def configured(name, arch):
    """A GRUB config as builder/build-iso.sh leaves it for one architecture."""
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / name
        shutil.copy(GRUB / name, config)
        subprocess.run(
            ["bash", "-c", 'source "$1" && configure_grub_platform "$2" "$3"', "_",
             ROOT / "builder/grub-platform.sh", config, arch],
            check=True,
        )
        return config.read_text()


def entries(config):
    return re.findall(r'^\s*menuentry\s+["\']([^"\']+)["\']', config, re.M)



class MenuEntries(unittest.TestCase):
    def test_uefi_menu_offers_install_and_try(self):
        config = configured("grub.cfg", "x86_64")
        # The device-tree entry is inside `if grub_cpu == arm64`.
        self.assertEqual(
            [e for e in entries(config) if "device tree" not in e],
            ["Install Omarchy", "Try Omarchy"],
        )

    def test_iso_file_menu_offers_install_and_try(self):
        self.assertEqual(entries(configured("loopback.cfg", "x86_64")), ["Install Omarchy", "Try Omarchy"])

    def test_aarch64_keeps_its_own_entries(self):
        config = configured("grub.cfg", "aarch64")
        self.assertIn("N1x recovery shell (hardware probe, no installer)", entries(config))
        self.assertIn("Omarchy (aarch64, ${archiso_platform}, device tree)",
                      [e.replace("%ARCH%", "aarch64") for e in entries(config)])

    def test_bios_menu_offers_install_and_try(self):
        labels = []
        for cfg in ("archiso_sys.cfg", "archiso_sys-linux.cfg", "archiso_head.cfg"):
            labels += re.findall(r"^MENU LABEL (.+)$", (SYSLINUX / cfg).read_text(), re.M)
        # A caret marks an entry's hotkey: T for Try, as before.
        self.assertEqual(labels, ["Install Omarchy", "^Try Omarchy"])
        self.assertFalse((SYSLINUX / "archiso_tail.cfg").exists())

    def test_bios_and_uefi_count_down_alike(self):
        grub_timeout = re.search(r"^timeout=(\d+)$", configured("grub.cfg", "x86_64"), re.M)
        bios_timeout = re.search(r"^TIMEOUT (\d+)$", (SYSLINUX / "archiso_sys.cfg").read_text(), re.M)
        # syslinux counts tenths of a second.
        self.assertEqual(int(bios_timeout.group(1)), int(grub_timeout.group(1)) * 10)


if __name__ == "__main__":
    unittest.main()
