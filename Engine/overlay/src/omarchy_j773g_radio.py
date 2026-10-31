# SPDX-License-Identifier: MIT
"""The M4 Mac mini's (j773gap) Broadcom BCM4388 "sakhalin" radio inputs.

Ported from GravityLinux/installer (MIT; gravity_firmware/wifi.py
MACHINE_ALIASES["j773g"], gravity_firmware/bluetooth.py MACHINE_OUTPUTS and
gravity_firmware/radio_calibration.py), which runs Wi-Fi and Bluetooth on this
Mac. Three things differ from the Macs the pinned asahi_firmware knows:

- macOS 26 Recovery keeps the Wi-Fi firmware in the AppleBCMWLAN driver
  extension, not usr/share/firmware/wifi, so the upstream collection finds
  none. WIFI_SOURCES are tried in order.
- Beside the board-specific names brcmfmac builds from brcm,board-type
  ("apple,sakhalin"), the module OTP and apple,antenna-sku, the image carries
  plain per-chip names for this board only (WIFI_ALIASES): the kernel falls
  back to them when the OTP cannot be read, and it names the C2 silicon 4388c0
  or 4388c2 by revision ID. They point at the NVRAM, CLM and TxCap files
  Gravity qualified on this Mac (module WLMT, vendor USI, antenna X0). They
  are machine-scoped: on another board they could load the wrong NVRAM or
  transmit power.
- The ADT carries neither wifi-calibration-msf nor the Bluetooth beamforming
  calibration (bluetooth-taurus-calibration-bf). Both are in this Mac's own
  factory BWCl records (WCAL and BTBF), bound here to the radio's /chosen
  address. They are written as brcm/brcmfmac4388-<address>-cal.bin and
  brcm/brcmbt4388-<address>-bf.bin, Gravity's names, for the boot chain or
  kernel to supply as brcm,cal-blob and brcm,taurus-bf-cal-blob.

Records are parsed as data; Apple's IMG4 signature is not verified.
"""

import glob
import hashlib
import os
import re

import omarchy_mt7932 as _der

DEVICE_CLASS = "j773gap"
WIFI_SOURCES = (
    "System/Library/DriverExtensions/com.apple.DriverKit-AppleBCMWLAN.dext/Firmware",
    "usr/share/firmware/wifi",
)
UPSTREAM_WIFI_SOURCE = "usr/share/firmware/wifi"
FIRMWARE_DIRECTORY = "C-4388__s-C2"
WIFI_FILES = {
    "bin": "sakhalin.trx",
    "txt": "P-sakhalin-X0_M-WLMT_V-u__m-4.9.txt",
    "clm_blob": "sakhalin-X0.clmb",
    "txcap_blob": "sakhalin-X0.txcb",
    "sig": "sakhalin.sig",
}
WIFI_ALIASES = {
    f"brcm/brcmfmac4388{revision}-pcie.{extension}": f"{FIRMWARE_DIRECTORY}/{source}"
    for revision in ("c0", "c2")
    for extension, source in WIFI_FILES.items()
}
BLUETOOTH_FILES = (
    "brcm/brcmbt4388c2-apple,sakhalin-a.bin",
    "brcm/brcmbt4388c2-apple,sakhalin-a.ptb",
)
FACTORY_DATA = "System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata"
FACTORY_RECORDS = "BWCl-sakhalin-4388-C2-*"
MAX_FACTORY_SIZE = 1024 * 1024
MAX_CALIBRATION_SIZE = 32768
CALIBRATIONS = (
    # (record, /chosen address property, firmware name)
    ("WCAL", "mac-address-wifi0", "brcm/brcmfmac4388-{}-cal.bin"),
    ("BTBF", "mac-address-bluetooth0", "brcm/brcmbt4388-{}-bf.bin"),
)


class RadioError(RuntimeError):
    pass


def wifi_source(recovery_root):
    for relative in WIFI_SOURCES:
        path = os.path.join(recovery_root, relative)
        if os.path.isdir(path):
            return path
    raise RadioError("the Recovery image has no Wi-Fi firmware")


def process_nvram(data):
    """asahi_firmware's NVRAM clean-up: one key=value per line, keys stripped."""
    lines = []
    for line in data.decode("ascii").split("\n"):
        if not line:
            continue
        key, value = line.split("=", 1)
        lines.append(f"{key.strip()}={value}\n")
    return "".join(lines).encode("ascii")


def wifi_aliases(source):
    """{name: bytes} for WIFI_ALIASES, read from the Wi-Fi firmware SOURCE."""
    files = {}
    for name, relative in WIFI_ALIASES.items():
        try:
            with open(os.path.join(source, relative), "rb") as stream:
                data = stream.read()
        except FileNotFoundError:
            raise RadioError(f"missing Wi-Fi firmware for the M4 Mac mini: {relative}") from None
        files[name] = process_nvram(data) if name.endswith(".txt") else data
    return files


def wifi_collection_class(base):
    """asahi_firmware's WiFiFWCollection, reading macOS 26's driver extension
    and adding this board's aliases. The stub calls it with
    recovery/usr/share/firmware/wifi/; the Recovery root is above that."""

    class J773gWiFiCollection(base):
        def __init__(self, source_path):
            root = os.path.normpath(source_path)
            suffix = os.path.normpath(UPSTREAM_WIFI_SOURCE)
            if root.endswith(suffix):
                root = root[: -len(suffix)] or "."
            self.j773g_source = wifi_source(root)
            super().__init__(self.j773g_source)

        def files(self):
            yield from super().files()
            for name, data in sorted(wifi_aliases(self.j773g_source).items()):
                yield name, self.fwfile(name, data)

        @staticmethod
        def fwfile(name, data):
            import asahi_firmware.core

            return asahi_firmware.core.FWFile(name, data)

    return J773gWiFiCollection


def _calibration_blob(data):
    if not 4 <= len(data) <= MAX_CALIBRATION_SIZE or not data.startswith(b"BLOB"):
        raise RadioError("invalid radio calibration")
    return bytes(data)


def bwcl_record(image, record):
    """The one RECORD (b"WCAL", b"BTBF") of a factory BWCl IMG4."""
    if len(image) > MAX_FACTORY_SIZE:
        raise RadioError("the factory record exceeds its size limit")
    try:
        _, start, end = _der._tlv(image, 0)
        if end != len(image):
            raise RadioError("the factory record has trailing data")
        parts = list(_der._children(image, start, end))
        if len(parts) < 2 or image[parts[0][1]:parts[0][2]] != b"IMG4" or parts[1][0] != 0x30:
            raise RadioError("the factory record is not an IMG4")
        im4p = list(_der._children(image, parts[1][1], parts[1][2]))
        if (len(im4p) != 4 or [image[s:e] for _, s, e in im4p[:2]] != [b"IM4P", b"BWCl"]
                or im4p[2][0] != 0x16 or im4p[3][0] != 0x04):
            raise RadioError("the factory record is not an uncompressed BWCl IM4P")
        payload = list(_der._children(image, im4p[3][1], im4p[3][2]))
        if len(payload) != 1 or payload[0][0] != 0x30:
            raise RadioError("the BWCl payload is not one sequence")
        records = list(_der._children(image, payload[0][1], payload[0][2]))
        identifier = int.from_bytes(b"BWCl", "little")
        if (not records or records[0][0] != 0x02
                or int.from_bytes(image[records[0][1]:records[0][2]], "big") != identifier):
            raise RadioError("the BWCl payload has the wrong identifier")
        wanted = int.from_bytes(record, "little")
        matches = []

        def visit(children, depth=0):
            if depth > 8:
                raise RadioError("the BWCl payload nests too deeply")
            for tag, cstart, cend in children:
                if not tag & 0x20:
                    continue
                inner = list(_der._children(image, cstart, cend))
                if (tag == 0x30 and inner and inner[0][0] == 0x02
                        and int.from_bytes(image[inner[0][1]:inner[0][2]], "big") == wanted):
                    if len(inner) != 3 or inner[1][0] != 0x16 or inner[2][0] != 0x04:
                        raise RadioError("malformed calibration record")
                    matches.append(_calibration_blob(image[inner[2][1]:inner[2][2]]))
                else:
                    visit(inner, depth + 1)

        visit(records)
    except _der.Mt7932Error as error:
        raise RadioError(f"the factory record is malformed: {error}") from error
    if len(matches) != 1:
        raise RadioError(f"expected exactly one {record.decode()} record, found {len(matches)}")
    return matches[0]


def radio_address(chosen, name):
    """The radio's /chosen address as 12 lowercase hex digits (m1n1's order)."""
    address = chosen.get(name)
    if (not isinstance(address, (bytes, bytearray)) or len(address) != 6
            or bytes(address) in (bytes(6), b"\xff" * 6) or address[0] & 1):
        raise RadioError(f"the device tree has no usable {name}")
    return bytes(address).hex()


def calibrations(root="/", chosen=None):
    """({firmware name: blob}, [error]) for Wi-Fi and Bluetooth, from this
    Mac's factory BWCl records. Every record must agree. Each radio stands
    alone: one whose calibration cannot be read is reported, not collected."""
    paths = sorted(glob.glob(os.path.join(root, FACTORY_DATA, FACTORY_RECORDS)))
    if not paths:
        raise RadioError("this Mac has no BWCl factory radio calibration")
    images = []
    for path in paths:
        if os.path.getsize(path) > MAX_FACTORY_SIZE:
            raise RadioError("the factory record exceeds its size limit")
        with open(path, "rb") as stream:
            images.append(stream.read())
    if chosen is None:
        chosen = _der.device_tree_chosen()
    files, errors = {}, []
    for record, address, filename in CALIBRATIONS:
        try:
            blobs = {}
            for image in images:
                blob = bwcl_record(image, record.encode())
                blobs[hashlib.sha256(blob).digest()] = blob
            if len(blobs) != 1:
                raise RadioError(f"the factory records disagree on {record}; refusing to choose")
            name = filename.format(radio_address(chosen, address))
        except RadioError as error:
            errors.append(f"{record}: {error}")
            continue
        assert re.fullmatch(r"brcm/brcm(fmac|bt)4388-[0-9a-f]{12}-(cal|bf)\.bin", name)
        files[name] = next(iter(blobs.values()))
    return files, errors


def missing(names):
    """The board's Wi-Fi and Bluetooth firmware names absent from NAMES."""
    return sorted((set(WIFI_ALIASES) | set(BLUETOOTH_FILES)) - set(names))
