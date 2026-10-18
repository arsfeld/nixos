"""Encoder check against frames decoded from codes learned off the Kanion remote."""

import base64
import struct

import midea

LEARNED = {
    # (power, mode, temperature, fan): frame
    (True, midea.MODE_HEAT, 22, midea.FAN_AUTO): "A1A345FFFF68",
    (True, midea.MODE_HEAT, 18, midea.FAN_AUTO): "A1A341FFFF6C",
    (False, midea.MODE_HEAT, 18, midea.FAN_AUTO): "A12341FFFFEC",
}

for state, expected in LEARNED.items():
    data = midea.frame(*state)
    assert data.hex().upper() == expected, (state, data.hex(), expected)

    raw = base64.b64decode(midea.tuya_code(data))
    timings = struct.unpack(f"<{len(raw) // 2}H", raw)
    assert len(timings) == 200, len(timings)
    bits = "".join("1" if s > 1000 else "0" for s in timings[3:99:2])
    assert int(bits, 2).to_bytes(6, "big") == data, bits

print("midea_ir: encoder matches all learned frames")
