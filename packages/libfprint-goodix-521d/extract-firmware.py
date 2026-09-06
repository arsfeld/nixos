#!/usr/bin/env python3
"""Extract a flashable Goodix 52xd firmware image from the Windows driver.

The community Linux tooling (goodix-fp-dump) only ships
`GFUSB_GM168SEC_APP_10019.bin`, but Windows Hello runs the sensor on
`GFUSB_GM168SEC_APP_10034` and reverts the sensor to it on every Windows boot.
Flashing 10034 ourselves -- with our own PSK -- needs a byte-exact 10034 image,
and the only place one exists is inside the Windows UMDF driver `wbdi.dll`.

Usage:
    extract-firmware.py /path/to/wbdi.dll [-o GFUSB_GM168SEC_APP_10034.bin]

`wbdi.dll` lives on the Windows partition under
`Windows/System32/DriverStore/FileRepository/wbdiusb.inf_amd64_*/`. Mount that
partition read-only and copy it out; nothing here writes to the device.

## Container format (recovered from wbdi.dll, function at VA 0x18006ab68)

The DLL does NOT store a ready-to-flash .bin. It stores a blob, located by a
descriptor in .data holding {pointer, length}:

    blob = [1B version-string length][version string][payload][4B CRC]

and builds the flashable image at runtime. `fcn.18006e12c` ("CheckFirmware")
first validates the blob's own trailing CRC over everything preceding it, then
`fcn.18006ab68` assembles a 12-byte header:

    hdr[0:4]  = crc(hdr[4:12])
    hdr[4:8]  = payload length
    hdr[8:12] = crc(payload)
    image     = hdr + payload

`crc` is CRC-32/MPEG-2: poly 0x04C11DB7, init 0xFFFFFFFF, MSB-first, no input
or output reflection, no final XOR. In the DLL its lookup table is built at
runtime, so it reads as zeros in the file on disk -- do not try to lift it out
statically.

That layout is verified against the known-good 10019 image, whose header
satisfies all three rules exactly. `--verify-against` re-runs that check, which
is the only real guard that this script still models the format correctly.

The result is what upstream `driver_52xd.update_firmware()` expects: it writes
the whole file from offset 0 in 256-byte chunks and then calls `check_firmware`
with an HMAC keyed by the PSK, so an image flashed under the all-zero PSK is
self-consistent.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import struct
import sys

# CRC-32/MPEG-2
_TABLE: list[int] = []
for _i in range(256):
    _c = _i << 24
    for _ in range(8):
        _c = ((_c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if _c & 0x80000000 else (_c << 1) & 0xFFFFFFFF
    _TABLE.append(_c)


def crc32_mpeg2(data: bytes, crc: int = 0xFFFFFFFF) -> int:
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _TABLE[((crc >> 24) ^ b) & 0xFF]
    return crc


def build_image(version: str, payload: bytes) -> bytes:
    """Assemble the 12-byte header exactly as wbdi.dll does."""
    hdr = bytearray(12)
    struct.pack_into("<I", hdr, 4, len(payload))
    struct.pack_into("<I", hdr, 8, crc32_mpeg2(payload))
    struct.pack_into("<I", hdr, 0, crc32_mpeg2(bytes(hdr[4:12])))
    return bytes(hdr) + payload


def verify_reference(path: str) -> None:
    """Check our model of the header against a known-good image."""
    ref = open(path, "rb").read()
    h0, h1, h2 = struct.unpack("<III", ref[:12])
    payload = ref[12:]
    checks = [
        ("length field", h1, len(payload)),
        ("crc(payload)", h2, crc32_mpeg2(payload)),
        ("crc(hdr[4:12])", h0, crc32_mpeg2(ref[4:12])),
    ]
    for name, got, want in checks:
        status = "PASS" if got == want else "FAIL"
        print(f"  {name:16s} 0x{got:08x} vs 0x{want:08x}  {status}")
    if any(got != want for _, got, want in checks):
        sys.exit(f"FATAL: header model does not describe {path}")


def find_blobs(dll: bytes) -> list[tuple[int, int, str]]:
    """Locate firmware blobs by their Pascal-style [len][version] prefix.

    A blob starts with a single byte equal to the length of the version string
    that immediately follows it, so the prefix is self-describing and can be
    found without relying on the .data descriptor being laid out any given way.
    """
    out = []
    for m in re.finditer(rb"(GFUSB|MILAN)_[A-Za-z0-9_]{4,40}", dll):
        start, end = m.start(), m.end()
        name = m.group().decode()
        if start == 0 or dll[start - 1] != len(name):
            continue  # not preceded by its own length -> a plain string, not a blob
        out.append((start - 1, end, name))
    return out


def blob_length(dll: bytes, base: int) -> int | None:
    """Recover the blob length via its trailing CRC.

    wbdi.dll gets this from a {pointer,length} descriptor in .data, but the
    trailing CRC lets us confirm the end independently: scan for the length at
    which crc(blob[:-4]) equals the stored trailing word.
    """
    for total in range(64, 96 * 1024):
        end = base + total
        if end > len(dll):
            break
        stored = struct.unpack("<I", dll[end - 4:end])[0]
        if stored and crc32_mpeg2(dll[base:end - 4]) == stored:
            return total
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dll", help="path to wbdi.dll")
    ap.add_argument("-o", "--output", help="output .bin (default: <VERSION>.bin)")
    ap.add_argument("--verify-against", metavar="BIN",
                    help="known-good image to validate the header model against "
                         "(e.g. goodix-fp-dump's GFUSB_GM168SEC_APP_10019.bin)")
    args = ap.parse_args()

    if args.verify_against:
        print(f"validating header model against {args.verify_against}")
        verify_reference(args.verify_against)

    dll = open(args.dll, "rb").read()
    blobs = find_blobs(dll)
    if not blobs:
        return print("no [len][version] firmware blob found") or 1

    written = 0
    for base, ver_end, version in blobs:
        total = blob_length(dll, base)
        if total is None:
            print(f"{version}: found at 0x{base:x} but no trailing CRC matched - skipping")
            continue
        # [1B len][version][payload][4B CRC]
        payload = dll[ver_end:base + total - 4]
        image = build_image(version, payload)
        out = args.output or f"{version}.bin"
        with open(out, "wb") as fh:
            fh.write(image)
        print(f"{version}: blob 0x{base:x} +{total}  payload {len(payload)}  "
              f"image {len(image)}  sha256 {hashlib.sha256(image).hexdigest()}")
        print(f"  -> {out}")
        written += 1
        if args.output:
            break
    return 0 if written else 1


if __name__ == "__main__":
    sys.exit(main())
