"""Unit tests for _register_limine_efi_entry against a fake efibootmgr.

The fake keeps NVRAM in a JSON file and behaves like efibootmgr 18: a listing
(plain or --verbose, as the orchestrator asks) prints each entry's device path
after its label, --create takes the lowest free
number and puts it first in BootOrder, --delete-bootnum frees the number again,
--bootnext refuses a number that has no entry. Every call is logged, and the
fake can stand in for firmware that refuses a create, has no room left in
NVRAM, or answers a create of an existing option with that option.
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
with open(path + ".log", "a") as log:
    log.write(json.dumps(args) + "\n")
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
    created = [get("--label"), f'HD({get("--part")},GPT,{guid},0x800,0x400000)/{get("--loader")}']
    # FAKE_SLOTS: an NVRAM store with room for that many boot options.
    if len(nvram["entries"]) >= int(os.environ.get("FAKE_SLOTS", "65536")):
        print("Could not prepare Boot variable: No space left on device", file=sys.stderr)
        sys.exit(28)
    # FAKE_REUSE: firmware that keeps one option per device path and loader
    # answers a create of an existing one with that one, writing nothing.
    if not (os.environ.get("FAKE_REUSE") and created in nvram["entries"].values()):
        num = next(f"{n:04X}" for n in range(0x10000) if f"{n:04X}" not in nvram["entries"])
        nvram["entries"][num] = created
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

    def calls(self):
        log = Path(str(self.nvram) + ".log")
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def writes(self):
        """The efibootmgr calls that change NVRAM, by their action flag."""
        actions = ("--create", "--delete-bootnum", "--bootorder", "--bootnext")
        return [next(flag for flag in actions if flag in args) for args in self.calls()
                if any(flag in args for flag in actions)]

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
        # The old entry goes only once its replacement exists.
        self.assertEqual(self.writes()[:2], ["--create", "--delete-bootnum"])

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

    def test_an_old_entry_that_cannot_be_deleted_is_not_taken_for_the_new_one(self):
        # 0000 is taken, the old 0001 refuses to go, the new entry lands on
        # 0002. 0001 is still the old entry, so BootNext and the front of
        # BootOrder go to 0002 and 0001 stays behind it.
        self.nvram_with(
            {
                "0000": self.entry("Windows Boot Manager", WINDOWS, loader="\\EFI\\Microsoft\\Boot\\bootmgfw.efi"),
                "0001": self.entry("Limine", OURS, part=3),
            },
            ["0001", "0000"],
        )
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_DELETE": "1"}), \
                mock.patch.object(phases_impl, "error", lambda _message: None):
            nvram = self.register()
        self.assertEqual(nvram["entries"]["0002"], self.entry("Limine", OURS, part=3))
        self.assertEqual(nvram.get("next"), "0002", nvram)
        self.assertEqual(nvram["order"], ["0002", "0001", "0000"])

    def test_the_new_entry_is_the_one_that_starts_this_loader(self):
        # Another install's "Limine" entry that the earlier listing did not
        # show is new too, and it holds the lower number.
        self.nvram_with({"0000": self.entry("Limine", OTHER)}, ["0000"])
        phases_impl._register_limine_efi_entry(
            Path("/dev/nvme1n1"), 3, LOADER, pre_state={"entries": {}, "order": []}
        )
        nvram = json.loads(self.nvram.read_text())
        self.assertIn(OURS, nvram["entries"]["0001"][1])
        self.assertEqual(nvram.get("next"), "0001", nvram)
        self.assertEqual(nvram["order"][0], "0001")

    def test_a_refused_create_leaves_other_installs_alone(self):
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_CREATE": "1"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            nvram = self.register()
        self.assertEqual(nvram, {"entries": {"0004": self.entry("Limine", OTHER)}, "order": ["0004"]})
        self.assertEqual(len(warnings), 1)

    def test_a_refused_create_keeps_this_esps_old_entry(self):
        # The old entry is this install's only boot route until the new one
        # exists; a protected target may have no removable loader to fall
        # back on.
        old = {"0003": self.entry("Limine", OURS, part=3), "0004": self.entry("Limine", OTHER)}
        self.nvram_with(old, ["0003", "0004"])
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_CREATE": "1"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            nvram = self.register()
        self.assertEqual(nvram, {"entries": old, "order": ["0003", "0004"]})
        self.assertEqual(self.writes(), ["--create"])
        self.assertEqual(len(warnings), 1)

    def test_an_entry_the_firmware_reuses_is_left_in_place(self):
        # Firmware that answers a create of an existing option with that
        # option adds no new number. The old entry is the new one then: it
        # stays, and BootNext and BootOrder point at it.
        self.nvram_with(
            {"0000": self.entry("Windows Boot Manager", WINDOWS), "0003": self.entry("Limine", OURS, part=3)},
            ["0000", "0003"],
        )
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_REUSE": "1"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            nvram = self.register()
        self.assertEqual(nvram["entries"]["0003"], self.entry("Limine", OURS, part=3))
        self.assertNotIn("--delete-bootnum", self.writes())
        self.assertEqual(nvram["order"], ["0003", "0000"])
        self.assertEqual(nvram.get("next"), "0003", nvram)
        self.assertEqual(warnings, [])

    def test_a_full_nvram_frees_the_old_entrys_slot_and_retries_once(self):
        # No room for a second option: the old identical entry makes way, and
        # the new one, created on the number it freed, is found as ours.
        self.nvram_with(
            {"0000": self.entry("Limine", OURS, part=3), "0004": self.entry("Limine", OTHER)},
            ["0000", "0004"],
        )
        with mock.patch.dict(os.environ, {"FAKE_SLOTS": "2"}):
            nvram = self.register()
        self.assertEqual(self.writes()[:3], ["--create", "--delete-bootnum", "--create"])
        self.assertEqual(nvram["entries"]["0000"], self.entry("Limine", OURS, part=3))
        self.assertEqual(nvram["entries"]["0004"], self.entry("Limine", OTHER))
        self.assertEqual(nvram["order"], ["0000", "0004"])
        self.assertEqual(nvram.get("next"), "0000", nvram)

    def test_a_full_nvram_without_an_old_entry_of_ours_deletes_nothing(self):
        # Another install's entry is not ours to make room with.
        old = {"0000": self.entry("Windows Boot Manager", WINDOWS), "0004": self.entry("Limine", OTHER)}
        self.nvram_with(old, ["0000", "0004"])
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_SLOTS": "2"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            nvram = self.register()
        self.assertEqual(nvram, {"entries": old, "order": ["0000", "0004"]})
        self.assertEqual(self.writes(), ["--create"])
        self.assertEqual(len(warnings), 1)
        self.assertIn("No space left on device", warnings[0])


    def test_boot_check_does_not_count_another_installs_entry(self):
        # validate_boot: our entry was dropped and no fallback was deployed.
        # The other install's "Limine" entry must not pass for ours.
        esp = self.tmp / "esp"
        esp.mkdir()
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        with mock.patch.object(phases_impl, "error", lambda _message: None):
            with self.assertRaises(RuntimeError):
                phases_impl._validate_uefi_boot_routes(esp, fallback_is_ours=True)
            self.nvram_with({"0004": self.entry("Limine", OTHER), "0005": self.entry("Limine", OURS, part=3)}, ["0005", "0004"])
            phases_impl._validate_uefi_boot_routes(esp, fallback_is_ours=True)


if __name__ == "__main__":
    unittest.main()
