"""Midea AC infrared protocol, encoded as Tuya IR pulse codes.

A Midea frame is 6 bytes, sent MSB first after a 4.4 ms header, then sent
again bit-inverted:

  byte 0  0xA1, the command type
  byte 1  power (bit 7), 1 (bit 5), fan (bits 4-3), mode (bits 2-0)
  byte 2  0x40 | (temperature - 17)
  byte 3  0xFF, no on-timer
  byte 4  0xFF, no off-timer
  byte 5  checksum

Derived from codes learned off a Kanion remote. The constant bits are kept
exactly as that remote sends them.
"""

import base64
import struct

MODE_COOL = 0
MODE_DRY = 1
MODE_AUTO = 2
MODE_HEAT = 3
MODE_FAN = 4

FAN_AUTO = 0
FAN_LOW = 1
FAN_MEDIUM = 2
FAN_HIGH = 3

MIN_TEMP = 17
MAX_TEMP = 30

# Microseconds, averaged from the learned codes.
HEADER_MARK = 4400
HEADER_SPACE = 4400
BIT_MARK = 550
ONE_SPACE = 1650
ZERO_SPACE = 550
FRAME_GAP = 5200
TRAILER = 30000


def _reverse(byte: int) -> int:
    return int(f"{byte:08b}"[::-1], 2)


def checksum(frame: bytes) -> int:
    """Midea checksum over the first five bytes, computed in LSB-first order."""
    total = sum(_reverse(b) for b in frame[:5])
    return _reverse((256 - total) & 0xFF)


def frame(power: bool, mode: int, temperature: int, fan: int) -> bytes:
    """Build the 6-byte frame for a full AC state."""
    temperature = max(MIN_TEMP, min(MAX_TEMP, int(temperature)))
    body = bytes(
        [
            0xA1,
            (0x80 if power else 0) | 0x20 | (fan & 0x3) << 3 | (mode & 0x7),
            0x40 | (temperature - MIN_TEMP),
            0xFF,
            0xFF,
        ]
    )
    return body + bytes([checksum(body)])


def pulses(data: bytes) -> list[int]:
    """Mark/space timings for a frame followed by its inverted repeat."""
    out: list[int] = []
    for i, part in enumerate((data, bytes(~b & 0xFF for b in data))):
        out += [HEADER_MARK, HEADER_SPACE]
        for byte in part:
            for bit in range(7, -1, -1):
                out += [BIT_MARK, ONE_SPACE if byte >> bit & 1 else ZERO_SPACE]
        out += [BIT_MARK, FRAME_GAP if i == 0 else TRAILER]
    return out


def tuya_code(data: bytes) -> str:
    """Base64 of little-endian uint16 timings, the format Tuya IR hubs take."""
    timings = pulses(data)
    return base64.b64encode(struct.pack(f"<{len(timings)}H", *timings)).decode()
