"""Unit tests for _register_limine_efi_entry against a fake efibootmgr.

The fake keeps NVRAM in a JSON file and behaves like efibootmgr 18: a listing
(plain or --verbose, as the orchestrator asks) prints each entry's device path
after its label, --create takes the lowest free
number and puts it first in BootOrder, --delete-bootnum frees the number again,
--bootnext refuses a number that has no entry.
A fake lsblk answers the ESP's partition GUID.

The case that matters: a free-space install next to an existing Omarchy must
not delete the other install's "Limine" entry, nor take the first "Limine"
entry in the list as its own.
"""

import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402

OURS = "8e3f52b7-f024-4125-bd27-696adc846a21"
OTHER = "3c105dda-1eb6-4c87-9669-a4c3b6f1b95f"
WINDOWS = "7a511e2f-439f-4c01-81e3-3687d4a7d72f"
LOADER = "\\EFI\\limine\\limine_x64.efi"

FAKE_EFIBOOTMGR = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["FAKE_NVRAM"]
nvram = json.load(open(path))
args = sys.argv[1:]
if args in ([], ["--verbose"], ["-v"]):
    if "next" in nvram:
        print("BootNext: " + nvram["next"])
    print("BootCurrent: 0001")
    print("BootOrder: " + ",".join(nvram["order"]))
    for num, (label, dp) in sorted(nvram["entries"].items()):
        # FAKE_NO_PATHS: an efibootmgr that lists labels only.
        print(f"Boot{num}* {label}" if os.environ.get("FAKE_NO_PATHS") else f"Boot{num}* {label}\t{dp}")
    sys.exit(0)
if "--create" in args and os.environ.get("FAKE_REFUSE_CREATE"):
    print("Could not prepare Boot variable: Invalid argument", file=sys.stderr)
    sys.exit(2)
if "--delete-bootnum" in args and os.environ.get("FAKE_REFUSE_DELETE"):
    print("Could not delete variable: Permission denied", file=sys.stderr)
    sys.exit(3)
if "--create" in args:
    get = lambda flag: args[args.index(flag) + 1]
    guids = json.loads(os.environ["FAKE_GUIDS"])
    guid = guids[f'{get("--disk")}:{get("--part")}']
    num = next(f"{n:04X}" for n in range(0x10000) if f"{n:04X}" not in nvram["entries"])
    nvram["entries"][num] = [get("--label"), f'HD({get("--part")},GPT,{guid},0x800,0x400000)/{get("--loader")}']
    nvram["order"].insert(0, num)
elif "--delete-bootnum" in args:
    num = args[args.index("--bootnum") + 1]
    del nvram["entries"][num]
    nvram["order"] = [n for n in nvram["order"] if n != num]
elif "--bootorder" in args:
    nvram["order"] = args[args.index("--bootorder") + 1].split(",")
elif "--bootnext" in args:
    num = args[args.index("--bootnext") + 1]
    if os.environ.get("FAKE_REFUSE_BOOTNEXT") or num not in nvram["entries"]:
        print("Could not set BootNext: Invalid argument", file=sys.stderr)
        sys.exit(5)
    nvram["next"] = num
json.dump(nvram, open(path, "w"))
'''

FAKE_LSBLK = r'''#!/usr/bin/env python3
import json, os, sys
dev = sys.argv[-1]
for key, guid in json.loads(os.environ["FAKE_GUIDS"]).items():
    disk, part = key.rsplit(":", 1)
    if "PARTN,PARTUUID" in sys.argv and disk == dev:
        print(part, guid)
    elif "PARTUUID" in sys.argv and dev == f"{disk}p{part}":
        print(guid)
'''

FAKE_FINDMNT = r'''#!/usr/bin/env python3
import os
print(os.environ.get("FAKE_ESP_SOURCE", ""))
'''


class RegisterLimineEfiEntryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)], check=False))
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, text in (("efibootmgr", FAKE_EFIBOOTMGR), ("lsblk", FAKE_LSBLK), ("findmnt", FAKE_FINDMNT)):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        self.nvram = self.tmp / "nvram.json"
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_NVRAM": str(self.nvram),
            "FAKE_GUIDS": json.dumps({
                "/dev/nvme1n1:3": OURS,
                "/dev/nvme1n1:1": OTHER,
                "/dev/nvme0n1:1": WINDOWS,
            }),
            "FAKE_ESP_SOURCE": "/dev/nvme1n1p3",
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def nvram_with(self, entries, order):
        self.nvram.write_text(json.dumps({"entries": entries, "order": order}))

    def entry(self, label, guid, part=1, loader=LOADER):
        return [label, f"HD({part},GPT,{guid},0x800,0x400000)/{loader}"]

    def register(self):
        phases_impl._register_limine_efi_entry(Path("/dev/nvme1n1"), 3, LOADER)
        return json.loads(self.nvram.read_text())

    def limine_guids(self, nvram):
        return {num: dp for num, (label, dp) in nvram["entries"].items() if label == "Limine"}

    def test_another_installs_entry_survives_behind_ours(self):
        self.nvram_with(
            {
                "0000": self.entry("Windows Boot Manager", WINDOWS, loader="\\EFI\\Microsoft\\Boot\\bootmgfw.efi"),
                "0004": self.entry("Limine", OTHER),
            },
            ["0004", "0000"],
        )
        nvram = self.register()
        limine = self.limine_guids(nvram)
        self.assertEqual(len(limine), 2, nvram)
        ours = next(num for num, dp in limine.items() if OURS in dp)
        self.assertEqual(nvram["order"], [ours, "0004", "0000"])

    def test_this_esps_old_entry_is_replaced(self):
        self.nvram_with(
            {
                "0000": self.entry("Windows Boot Manager", WINDOWS),
                "0003": self.entry("Limine", OURS, part=3),
                "0004": self.entry("Limine", OTHER),
            },
            ["0000", "0004", "0003"],
        )
        nvram = self.register()
        limine = self.limine_guids(nvram)
        self.assertEqual(len([dp for dp in limine.values() if OURS in dp]), 1, nvram)
        self.assertIn("0004", limine)
        ours = next(num for num, dp in limine.items() if OURS in dp)
        self.assertEqual(nvram["order"], [ours, "0000", "0004"])

    def test_the_created_entry_is_ours_even_when_listed_after_another(self):
        # The fake reuses the lowest free number: with 0000 taken by another
        # install's "Limine", ours becomes 0001, and the first "Limine" in the
        # listing is not ours.
        self.nvram_with({"0000": self.entry("Limine", OTHER)}, ["0000"])
        nvram = self.register()
        self.assertEqual(nvram["order"][0], "0001")
        self.assertIn(OURS, nvram["entries"]["0001"][1])
        self.assertEqual(nvram["order"], ["0001", "0000"])

    def test_the_next_boot_is_ours_whatever_the_firmware_does_to_bootorder(self):
        # An MSI MAG Z690 Tomahawk rewrites BootOrder at the next POST and
        # puts a new entry behind its own, here the other install's "Limine".
        # BootNext is read before BootOrder.
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        nvram = self.register()
        ours = next(num for num, (_, dp) in nvram["entries"].items() if OURS in dp)
        self.assertEqual(nvram.get("next"), ours, nvram)

    def test_a_refused_bootnext_keeps_the_bootorder_route(self):
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        errors = []
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_BOOTNEXT": "1"}):
            with mock.patch.object(phases_impl, "error", errors.append):
                nvram = self.register()
        ours = next(num for num, (_, dp) in nvram["entries"].items() if OURS in dp)
        self.assertNotIn("next", nvram)
        self.assertEqual(nvram["order"], [ours, "0004"])
        self.assertTrue(any("BootNext" in message for message in errors), errors)

    def test_a_label_only_listing_deletes_nothing(self):
        # Without device paths no entry can be shown to be this ESP's.
        self.nvram_with({"0004": self.entry("Limine", OTHER), "0003": self.entry("Limine", OURS, part=3)}, ["0004", "0003"])
        with mock.patch.dict(os.environ, {"FAKE_NO_PATHS": "1"}):
            nvram = self.register()
        self.assertIn("0004", nvram["entries"])
        self.assertIn("0003", nvram["entries"])

    def test_a_refused_delete_does_not_stop_the_install(self):
        self.nvram_with({"0003": self.entry("Limine", OURS, part=3), "0004": self.entry("Limine", OTHER)}, ["0003", "0004"])
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_DELETE": "1"}), \
                mock.patch.object(phases_impl, "error", lambda _message: None):
            nvram = self.register()
        # The old entry could not be deleted, so the new one took the lowest
        # free number; it boots first and the old one is left behind it.
        self.assertEqual(nvram["entries"]["0000"], self.entry("Limine", OURS, part=3))
        self.assertIn("0003", nvram["entries"])
        self.assertEqual(nvram["order"][0], "0000")

    def test_other_loaders_on_this_esp_survive(self):
        # Only an entry identical to the one created is replaced: same label,
        # this ESP and this loader. A backup loader on the same ESP, or an
        # entry someone labelled differently, is not ours to delete. The old
        # entry still counts when the listing prints its path in upper case,
        # and a BootOrder number with no entry behind it is dropped.
        backup = self.entry("Limine", OURS, part=3, loader="\\EFI\\backup\\limine.efi")
        relabelled = self.entry("Limine backup", OURS, part=3)
        self.nvram_with(
            {
                "0003": [label.upper() for label in self.entry("Limine", OURS, part=3)],
                "0005": backup,
                "0006": relabelled,
            },
            ["0003", "0005", "0006", "FFFF"],
        )
        nvram = self.register()
        self.assertNotIn("0003", nvram["entries"])
        self.assertEqual(nvram["entries"]["0005"], backup)
        self.assertEqual(nvram["entries"]["0006"], relabelled)
        self.assertEqual(nvram["order"], ["0000", "0005", "0006"])

    def test_a_refused_create_leaves_other_installs_alone(self):
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_CREATE": "1"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            nvram = self.register()
        self.assertEqual(nvram, {"entries": {"0004": self.entry("Limine", OTHER)}, "order": ["0004"]})
        self.assertEqual(len(warnings), 1)

    def test_created_entry_reusing_a_deleted_number_is_found(self):
        self.nvram_with({"0000": self.entry("Limine", OURS, part=3)}, ["0000"])
        nvram = self.register()
        self.assertEqual(nvram["order"], ["0000"])
        self.assertIn(OURS, nvram["entries"]["0000"][1])


    def test_boot_check_does_not_count_another_installs_entry(self):
        # validate_boot: our entry was dropped and no fallback was deployed.
        # The other install's "Limine" entry must not pass for ours.
        esp = self.tmp / "esp"
        esp.mkdir()
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        with mock.patch.object(phases_impl, "error", lambda _message: None):
            with self.assertRaises(RuntimeError):
                phases_impl._validate_uefi_boot_routes(esp)
            self.nvram_with({"0004": self.entry("Limine", OTHER), "0005": self.entry("Limine", OURS, part=3)}, ["0005", "0004"])
            phases_impl._validate_uefi_boot_routes(esp)


if __name__ == "__main__":
    unittest.main()
