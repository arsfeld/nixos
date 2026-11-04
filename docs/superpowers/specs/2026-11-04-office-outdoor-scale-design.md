# Office target scales with the outdoor temperature

## Problem

The basement office is scheduled at 21°C for work (weekdays 08:30–17:00) and
for evenings (20:30–24:00, every day). On mild days the basement holds heat on
its own and 21 is too warm. On 2026-11-04 it was 11°C outside, and with a
target of 16 overnight the office only fell to 18.5. On days like that, 19 is
enough.

## Decision

Zones in `_zones.nix` gain an optional `outdoor` field: a list of
`[threshold cap]` steps read against `sensor.outdoor_weather_hilo`. When the
outdoor reading is at or above a step's threshold, that step's cap applies.
The lowest applicable cap wins. The office declares:

```nix
outdoor = [[0 20] [10 19]];
```

Its 21 windows therefore become:

| Outside (°C)   | Target |
|----------------|--------|
| below 0        | 21     |
| 0 to 9         | 20     |
| 10 and above   | 19     |

## Rules

- The cap applies to a scheduled window's target and to the pre-heat target,
  as `min(window target, cap)`. Because it can only lower a target, the
  office's 19 windows stay at 19.
- Pre-heat looks for the next window warmer than now using the *capped*
  target. On a mild evening, then, the 20:30 window is 19, the room is already
  there, and no pre-heat runs.
- Boost, base and away are not capped. Boost stays a flat 21: it is the
  "I'm cold" override.
- An unavailable or non-numeric outdoor reading means no cap, so the zone gets
  its full window target. The failure errs warm.
- Hysteresis is deliberately left out. The Hilo reading is an hourly integer,
  so at worst the target moves one step once an hour near a boundary.
- When a cap lowered the target, the target sensor carries an `outdoor_cap`
  attribute (the cap applied), so history shows why the office is at 19 or 20.
  It is absent otherwise.
- Rate learning is unchanged. It learns toward whatever target the pre-heat
  ran to.
- A zone without `outdoor` behaves exactly as before. `zoneDefaults` gains
  `outdoor = []`.

## Where

- `_zones.nix`: document the field in the header and add it to `office`.
- `default.nix`: add `outdoor = []` to `zoneDefaults` and `outdoor_cap` to
  `targetAttributes`.
- `_templates.nix`: compute the cap once in `plan`, apply it to the scheduled
  window and inside `preheat`'s window search and target. The code is emitted
  only for zones whose `outdoor` is non-empty.
- `test_heating.py`, office cases:
  - 21 at −5°C, 20 at 5°C, 19 at 12°C;
  - the 17:00–20:30 window is 19 regardless;
  - boost is 21 at 12°C;
  - no evening pre-heat at 12°C with the room at 19;
  - an unavailable outdoor reading gives 21.

  Living area and the other zones are unchanged.

Verify with `nix build .#checks.x86_64-linux.heating-policy-test`.
