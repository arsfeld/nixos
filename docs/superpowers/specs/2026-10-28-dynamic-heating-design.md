# Dynamic heating: occupancy schedule, learned pre-heat, boosts

Replaces the fixed-hour policy in `hosts/galactica/services/home-assistant-heating.nix`
with a per-zone weekly occupancy schedule. Each comfort window is *reached by* its start
time, using a pre-heat lead learned per zone. The office follows the user's phone. Three
one-click boosts cover "it's cold" complaints for the rest of the day.

## Why: what the current automations did (2026-10-18 → 10-28)

Measured from the recorder on galactica (`/var/lib/hass/home-assistant_v2.db`):

| Day | Outdoor min/max | HP on (h) | Bedrooms kWh | Office kWh | Downstairs bath kWh | Family room kWh | All baseboards kWh |
|---|---|---|---|---|---|---|---|
| 10-22 | −2 / 16 | 12.6 | 4.18 | 7.05 | 2.15 | 0.00 | 13.7 |
| 10-23 | 2 / 12 | 9.7 | 1.64 | 5.84 | 1.26 | 0.22 | 9.2 |
| 10-24 | −2 / 14 | 20.6 | 2.92 | 7.12 | 2.50 | 0.23 | 13.2 |
| 10-25 | −1 / 17 | 24.0 | 0.00 | 6.23 | 2.81 | 0.15 | 9.4 |
| 10-26 | 4 / 13 | 24.0 | 0.00 | 4.87 | 1.41 | 1.26 | 8.5 |
| 10-27 | −1 / 7 | 24.0 | 0.00 | 7.84 | 2.06 | 0.00 | 9.9 |

- **Worked:** since 10-25 (heat pump setpoint 21 below 5°C outside, bedrooms at 18) the
  bedroom baseboards have used 0 kWh, and the bedrooms sit at 19–20.5 on heat pump heat
  alone. The living/dining backup baseboards never ran.
- **Didn't:** the heat pump has not turned off since 10-25. Its off-threshold is 21°C,
  and in cold weather the living area peaks around 20.5, so the 05–08 and 10–13 boosts
  change nothing. The wake window (06–08) averaged 19.0–19.7 in the living area.
- **Biggest cost:** the office is 60–80% of baseboard energy, heated 06–22 while the user
  is there about 08:30–17. The 06:00 recovery from 17.5°C alone costs 1–1.4 kWh. The
  downstairs bathroom is second.
- **Reliability:** `sensor.living_room_ir_temperature_2` dropped out on 10-27. The median
  carried on with the two Hilo sensors.
- **Pricing:** Hilo is on tiered Rate D (7.07¢ / 11.14¢), not time-of-use. Shifting heat
  in time saves nothing; only fewer kWh does, plus Hilo challenges once they start.

## Household schedule

- **Weekdays:** everyone up around 07:00, out at 08:00. The user is back at 08:30 and in
  the basement office until 17:00, with lunch upstairs 12–13. Kids are home at 17:00 and
  in bed at 20:30. The user sometimes works in the office again until midnight.
- **Weekends:** everyone home all day.

## Zones

"Comfort X by HH:MM" means the room is at X at HH:MM; pre-heat starts earlier (see below).

| Zone | Devices | Weekday | Weekend | Boost (until 00:00) |
|---|---|---|---|---|
| Living area | heat pump; `living_room_1` + `dining_room` baseboards for shortfall only | 20 07:00–08:00 · eco 19 08:00–17:00 · 20 17:00–20:30 · night 18 | 20 07:00–20:30 · night 18 | 21, baseboards help |
| Bedrooms | `master_bedroom`, `amanda_bedroom`, `beas_bedroom` | 18 | 18 | 20 |
| Bathroom | `bathroom` | 19 | 19 | 20, rides the bedroom boost |
| Office | `office` | 21 08:30–17:00 · 19 17:00–20:30 · 21 20:30–24:00 · 16 otherwise | 19 08:30–20:30 · 21 20:30–24:00 · 16 otherwise | 21, ignores presence |
| Downstairs bathroom | `bathroom_downstairs` | 19 08:30–24:00 · 16 otherwise | same | 19, rides the office boost |
| Family room | `living_room_2` | 20 17:00–20:30 · 16 otherwise | 20 08:00–20:30 · 16 otherwise | none |
| Workshop, garage | `workshop_1`, `workshop_2`, `garage` | 5 (off) | 5 | none |

Changes from the current policy: the 10–13 lunch boost is dropped (the heat pump runs all
day anyway); upstairs night starts at 20:30 instead of 22:00; the office moves from 19
over 06–22 to the schedule above.

### Presence (office zone only)

The office and downstairs bathroom drop to 16 once `person.alexandre_rosenfeld` has been
`not_home` for 30 minutes. When the user returns they resume the schedule and pre-heat as
usual. An `unknown` or `unavailable` person counts as home, so heat fails warm. The office
boost ignores presence. No one else is tracked.

### Heat pump

The heat pump is driven on/off from `sensor.living_area_temperature`, never from its own
thermostat, which reads far colder than the room.

- **On** below the zone's current target − 0.5.
- **Off** above 21, or 21.5 during a living-area boost. The wide band is deliberate: it
  runs long and gently.
- **Setpoint 21** in any comfort window, during pre-heat, during a boost, and whenever
  `sensor.outdoor_weather_hilo` is below 5. The unit never gets the room to 21; setpoint
  21 is how it pushes heat through the whole house. **Setpoint 19** only in eco/night on
  mild days.

## Dynamic pre-heat

Pre-heat applies to the zones that step up to comfort: the living area, office, downstairs
bathroom (shares the office's rate and start) and family room.

- **Learned rate.** `input_number.heating_rate_<zone>` holds the warm-up rate in °C/h,
  clamped to 0.2–3. Seeds come from this week's data: living area 0.4, office 1.5, family
  room 1.0.
- **Learning.** When a pre-heat reaches its target, an automation records
  `(temp now − temp at start) / hours` and stores `0.7 × old + 0.3 × new`. Runs are not
  learned from when they:
  - were interrupted (boost, manual change, presence change or Hilo challenge),
  - used the living-area shortfall baseboards,
  - lasted under 15 minutes.
- **Lead.** `clamp((comfort target − current temp) / rate, 0, max)`, where max is 3 h for
  the living area and 2 h for baseboard zones. `sensor.heating_<zone>_preheat_start` shows
  the resulting time. Once now ≥ that time, the zone's target becomes the comfort target
  with reason `preheat`.
- **Shortfall (living area only).** From pre-heat start until the window opens,
  `binary_sensor.living_area_shortfall` turns on when
  `temp + rate × hours to window < target` and 45 minutes or less remain. While it is on,
  the living/dining baseboards are set to the target. It turns off when the living area
  reaches the target, or when the comfort window ends. The same rule applies to a
  living-area boost, against 21.
- **Last-resort backup** (kept from today): the living/dining baseboards come on at
  floor + 1 when the living area stays below its floor for 30 minutes. The floor is 17 at
  night and 18 by day.

## Boosts

`input_boolean.heating_boost_office`, `heating_boost_living_area` and
`heating_boost_bedrooms` are one-click buttons on the HA dashboard. One automation turns
all three off at 00:00, so a boost can never be forgotten on. A boost raises its zone's
target to the boost value in the table above. It does not override a Hilo challenge.

## Architecture

All of it is a rewrite of `hosts/galactica/services/home-assistant-heating.nix`, keeping
its three layers.

1. **Policy (Nix).** A `zones` attrset declares each zone's:
   - devices,
   - weekday and weekend windows with their targets,
   - eco target,
   - boost helper and value,
   - presence gating,
   - max lead and seed rate.

   Everything below is generated from it, so a schedule change is a one-line edit.
2. **Sensors (HA templates).** `sensor.living_area_temperature` is unchanged. Per zone:
   `sensor.heating_<zone>_preheat_start` and `sensor.heating_<zone>_target`. The target
   sensor is the single answer to "what should this zone be now". It folds in, in order
   of precedence, Hilo challenge → boost → presence → comfort/pre-heat → eco, and exposes
   a `reason` attribute (`hilo`, `boost`, `away`, `preheat`, `comfort`, `eco`, `night`).
   Living area adds `binary_sensor.living_area_shortfall` beside `living_area_needs_backup`.
3. **Helpers.** Three `input_boolean` boosts and one `input_number` rate per pre-heated
   zone, declared in Nix and restored across restarts.
4. **Actuators.**
   - **Heat pump:** keeps today's shape (5-minute timer, HA start with a 60 s IR delay
     and resend, and state triggers), with its thresholds and setpoint read from the
     living-area target.
   - **Baseboards:** each baseboard is set when its zone's target sensor *changes*, plus
     the shortfall and backup flips for living/dining. Between changes the dial is left
     alone, so a manual or Hilo-app change lasts until the next scheduled change, and a
     restart overwrites nothing.
   - **Hilo challenges:** baseboards still stand down from pre-heat through recovery,
     and the heat pump is off during reduction.

## Failure handling

| Failure | Behaviour |
|---|---|
| One living-area sensor unavailable | The median uses the rest. |
| Living area unavailable entirely | The heat pump holds its current state; lead falls back to the zone max. |
| Person `unknown` or `unavailable` | Treated as home. |
| Learned rate drifts | It is clamped to 0.2–3°C/h, and learning skips interrupted or assisted runs. |
| HA restart | The heat pump state is resent after 60 s; baseboards are not touched. |

## Verification

1. `nix build .#nixosConfigurations.galactica.config.system.build.toplevel`.
2. A replay script mirrors the target and lead logic in Python and runs it over the
   exported 10 days. It checks that start times and targets come out where this document
   says.
3. After deploy, a week's per-room kWh and window-temperature table against the baseline
   above. Success means:
   - the living area is at 20 or above at 07:00 and 17:00 on weekdays,
   - the office is at 21 or above by 08:30 on days the user is home,
   - office kWh/day is at or below the baseline despite the higher target,
   - bedroom baseboards stay near 0 kWh.

## Out of scope

- Tracking anyone but the user.
- Time-of-use shifting: the rate is tiered, not time-of-use.
- A per-outdoor-temperature rate model; one rate per zone is enough until the data says
  otherwise.
- The workshop and garage.
