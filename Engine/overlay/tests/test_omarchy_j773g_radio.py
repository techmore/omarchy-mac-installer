# SPDX-License-Identifier: MIT
"""Synthetic data only: no Apple firmware or machine calibration."""
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import omarchy_j773g_radio as radio  # noqa: E402

WIFI_ADDRESS = "021122334455"
BT_ADDRESS = "0a1122334466"
CHOSEN = {"mac-address-wifi0": bytes.fromhex(WIFI_ADDRESS),
          "mac-address-bluetooth0": bytes.fromhex(BT_ADDRESS)}
WCAL = b"BLOB" + b"w" * 64
BTBF = b"BLOB" + b"b" * 32


def der(tag, content):
    length = len(content)
    if length < 0x80:
        size = bytes([length])
    else:
        encoded = length.to_bytes((length.bit_length() + 7) // 8, 'big')
        size = bytes([0x80 | len(encoded)]) + encoded
    return bytes([tag]) + size + content


def integer(value):
    return der(0x02, value.to_bytes(4, 'big'))


def field(name, blob):
    return der(0x30, integer(int.from_bytes(name, 'little')) + der(0x16, b"synthetic") + der(0x04, blob))


def bwcl(records=((b"WCAL", WCAL), (b"BTBF", BTBF)), kind=b"BWCl", identifier=b"BWCl"):
    # One record nested a level down, as Apple groups some of them.
    body = integer(int.from_bytes(identifier, 'little'))
    for name, blob in records:
        body += der(0x30, field(name, blob)) if name == b"BTBF" else field(name, blob)
    payload = der(0x30, body)
    im4p = der(0x30, der(0x16, b"IM4P") + der(0x16, kind) + der(0x16, b"synthetic") + der(0x04, payload))
    return der(0x30, der(0x16, b"IMG4") + im4p)


class FactoryRecordTests(unittest.TestCase):
    def test_both_records_come_out_of_one_bwcl(self):
        image = bwcl()
        self.assertEqual(radio.bwcl_record(image, b"WCAL"), WCAL)
        self.assertEqual(radio.bwcl_record(image, b"BTBF"), BTBF)

    def test_malformed_records_are_refused(self):
        for image in (bwcl(()), bwcl(((b"WCAL", WCAL), (b"WCAL", WCAL))),
                      bwcl(((b"WCAL", b"bad!"),)), bwcl(((b"WCAL", b"BLOB" + bytes(32768)),)),
                      bwcl(kind=b"BWC2"), bwcl(identifier=b"BWC2"), bwcl()[:-1], bwcl() + b"\0",
                      b"x" * (radio.MAX_FACTORY_SIZE + 1)):
            with self.subTest(length=len(image)), self.assertRaises(radio.RadioError):
                radio.bwcl_record(image, b"WCAL")

    def test_addresses_must_be_usable_unicast(self):
        self.assertEqual(radio.radio_address(CHOSEN, "mac-address-wifi0"), WIFI_ADDRESS)
        for value in (None, b"\0" * 6, b"\xff" * 6, bytes.fromhex("011122334455"), b"short"):
            with self.subTest(value=value), self.assertRaises(radio.RadioError):
                radio.radio_address({"mac-address-wifi0": value}, "mac-address-wifi0")


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.factory = self.root / radio.FACTORY_DATA
        self.factory.mkdir(parents=True)

    def write(self, name, image):
        (self.factory / name).write_bytes(image)

    def test_each_radio_is_bound_to_its_own_address(self):
        self.write("BWCl-sakhalin-4388-C2-1", bwcl())
        self.write("BWCl-sakhalin-4388-C2-2", bwcl())
        self.write("BWC2-other-board", b"not ours")
        files, errors = radio.calibrations(str(self.root), CHOSEN)
        self.assertEqual(errors, [])
        self.assertEqual(files, {
            f"brcm/brcmfmac4388-{WIFI_ADDRESS}-cal.bin": WCAL,
            f"brcm/brcmbt4388-{BT_ADDRESS}-bf.bin": BTBF,
        })

    def test_a_radio_without_calibration_does_not_cost_the_other(self):
        self.write("BWCl-sakhalin-4388-C2-1", bwcl(((b"WCAL", WCAL),)))
        files, errors = radio.calibrations(str(self.root), CHOSEN)
        self.assertEqual(list(files), [f"brcm/brcmfmac4388-{WIFI_ADDRESS}-cal.bin"])
        self.assertEqual(len(errors), 1)
        self.assertTrue(errors[0].startswith("BTBF:"))
        files, errors = radio.calibrations(str(self.root), {"mac-address-wifi0": CHOSEN["mac-address-wifi0"]})
        self.assertEqual(len(files), 1)

    def test_disagreeing_records_are_never_chosen_between(self):
        self.write("BWCl-sakhalin-4388-C2-1", bwcl())
        self.write("BWCl-sakhalin-4388-C2-2", bwcl(((b"WCAL", b"BLOB-other"), (b"BTBF", BTBF))))
        files, errors = radio.calibrations(str(self.root), CHOSEN)
        self.assertEqual(list(files), [f"brcm/brcmbt4388-{BT_ADDRESS}-bf.bin"])
        self.assertIn("disagree on WCAL", errors[0])

    def test_no_factory_record_is_an_error(self):
        with self.assertRaisesRegex(radio.RadioError, "no BWCl"):
            radio.calibrations(str(self.root), CHOSEN)


class WiFiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.recovery = Path(self.tmp.name) / "recovery"
        self.dext = self.recovery / radio.WIFI_SOURCES[0] / radio.FIRMWARE_DIRECTORY
        self.dext.mkdir(parents=True)
        for extension, name in radio.WIFI_FILES.items():
            data = b"boardrev =0x14\nmacaddr=00:00:00:00:00:00\n" if extension == "txt" else name.encode()
            (self.dext / name).write_bytes(data)

    def test_aliases_name_both_revisions_and_clean_the_nvram(self):
        files = radio.wifi_aliases(str(self.recovery / radio.WIFI_SOURCES[0]))
        self.assertEqual(set(files), {
            f"brcm/brcmfmac4388{rev}-pcie.{ext}" for rev in ("c0", "c2")
            for ext in ("bin", "txt", "clm_blob", "txcap_blob", "sig")})
        self.assertEqual(files["brcm/brcmfmac4388c2-pcie.txt"], b"boardrev=0x14\nmacaddr=00:00:00:00:00:00\n")
        self.assertEqual(files["brcm/brcmfmac4388c0-pcie.bin"], b"sakhalin.trx")

    def test_the_driver_extension_comes_before_the_legacy_directory(self):
        (self.recovery / radio.WIFI_SOURCES[1]).mkdir(parents=True)
        self.assertEqual(radio.wifi_source(str(self.recovery)), str(self.recovery / radio.WIFI_SOURCES[0]))
        with self.assertRaisesRegex(radio.RadioError, "no Wi-Fi firmware"):
            radio.wifi_source(str(self.recovery / "nowhere"))

    def test_the_collection_reads_the_extension_and_adds_the_aliases(self):
        class Base:
            def __init__(self, source_path):
                self.source = source_path

            def files(self):
                yield "brcm/brcmfmac4388c2-pcie.apple,sakhalin-WLMT-u-4.9-X0.txt", "upstream"

        core = ModuleType("asahi_firmware.core")
        core.FWFile = lambda name, data: ("FWFile", name, data)
        package = ModuleType("asahi_firmware")
        package.core = core
        collection_class = radio.wifi_collection_class(Base)
        with mock.patch.dict(sys.modules, {"asahi_firmware": package, "asahi_firmware.core": core}):
            collection = collection_class(os.path.join(str(self.recovery), "usr/share/firmware/wifi/"))
            files = dict(collection.files())
        self.assertEqual(collection.source, str(self.recovery / radio.WIFI_SOURCES[0]))
        self.assertEqual(files["brcm/brcmfmac4388c2-pcie.apple,sakhalin-WLMT-u-4.9-X0.txt"], "upstream")
        self.assertEqual(files["brcm/brcmfmac4388c0-pcie.sig"], ("FWFile", "brcm/brcmfmac4388c0-pcie.sig", b"sakhalin.sig"))
        self.assertEqual(radio.missing(files), sorted(radio.BLUETOOTH_FILES))

    def test_a_missing_board_file_names_itself(self):
        (self.dext / radio.WIFI_FILES["txcap_blob"]).unlink()
        with self.assertRaisesRegex(radio.RadioError, "sakhalin-X0.txcb"):
            radio.wifi_aliases(str(self.recovery / radio.WIFI_SOURCES[0]))


if __name__ == '__main__':
    unittest.main()
