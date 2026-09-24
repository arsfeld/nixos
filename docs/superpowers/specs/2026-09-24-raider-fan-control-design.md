# raider fan control redesign

Date: 2026-09-24
Host: raider (NZXT H1 V2, i5-12500H on ERYING G660 ITX, RX 6650 XT)
Goal: balanced cooling with no audible fan hunting.

## Problem

`nzxt-fan-control` changed fan speed 2,498 times in the 7 days to 2026-09-24,
almost all on fan2 (140 mm AIO radiator) at idle: `20→25%` 743 times,
`25→20%` 718 times. Three causes, from the code and the journal:

1. **Wrong input signal.** It follows the hottest single core from coretemp.
   Alder Lake-H core temperatures jump 20–30 °C within a second on any load
   (sampled: 41 → 71 °C in 10 s at light load). Intel's DTS updates every
   256 ms and Speed Shift is a known cause of fan hunting. Radiator coolant
   changes over minutes, so the fan reacts to spikes it cannot affect.
2. **Broken hysteresis on the way down.** `apply_hysteresis` compares against
   the upper threshold of the *current* band instead of the lower one, so a
   decrease happens as soon as the average crosses a step: there is 2 °C of
   margin going up and none coming down.
3. **Steps and a short window.** A stepped table plus a 20 s average; the CPU
   idled at 30–40 °C, right on the 40 °C edge between 20% and 25%.

## Hardware facts that constrain the design

- liquidctl `fan1` = 92 mm GPU-chamber exhaust (600–1800 rpm, 25% ≈ 660 rpm);
  `fan2` = 140 mm radiator fan (500–1800 rpm, 30% ≈ 750 rpm).
- Pump is fixed at ~4200 rpm and not controllable.
- **No coolant temperature sensor exists** on the H1 V2.
- The device accepts fixed duties only (`set_speed_profile` is unsupported),
  so the control loop must run on the host.
- The device keeps its last duty if the daemon dies.
- The kernel `nzxt-smart2` driver does not cover this device; only liquidctl can drive it.

Sources: liquidctl `docs/nzxt-hue2-guide.md` and issue #449; Intel ARK for
the 12500H (TjMax 100 °C); Corsair on CPU vs coolant temperature control;
Argus Monitor on fluctuating vs constant fan noise.

## Approach

Rewrite the control logic of the existing Python daemon. CoolerControl
(experimental H1 V2 support, GUI state outside Nix, dropped once already)
and fan2go (no liquidctl backend) were considered and rejected.

## Structure

The script moves to `hosts/raider/fan-control/fan_control.py` (underscores so the
test can import it), alongside
`test_fan_control.py`; `hosts/raider/fan-control.nix` points at the new path.
Inside the script:

- `Sensors` reads sysfs directly (`/sys/class/hwmon`, located by chip name
  `coretemp` / `amdgpu`, label `Package id 0` / `edge` / `junction`). No
  `sensors` subprocess, no text parsing.
- `Ema` is an exponential moving average with a time constant in seconds.
- `Curve` does linear interpolation over `(temp, duty)` points, clamped at both ends.
- `Governor` is pure: given smoothed temp, raw temp and the current time, it
  returns the duty to commit, or `None`.
- `Device` is a thin wrapper over `liquidctl initialize` and
  `liquidctl set fanN speed N`, called only on commit. No per-loop status reads.

The loop ticks every 2 s.

## Inputs

| Fan | Signal | EMA τ |
|---|---|---|
| fan2 (radiator) | coretemp `Package id 0` | 60 s (coolant proxy) |
| fan1 (GPU exhaust) | amdgpu `edge` | 30 s |

Out of scope: RAPL power feed-forward and PID control. Add the feed-forward
only if calibration shows the proxy lagging heat-soak.

## Curves

The curves are evaluated on the smoothed temperature, with linear
interpolation between points.

fan2: `(55, 25) (65, 35) (75, 50) (85, 75) (92, 100)`, with 25% below 55 °C
and 100% above 92 °C.

fan1: `(60, 30) (75, 40) (85, 60) (95, 100)`, with 30% below 60 °C and 100%
above 95 °C.

The floors match today's idle duties. The points above 65 °C are estimates,
to be calibrated (see Testing).

## Governor rules

The rules are evaluated per fan, every tick:

1. `target = round(curve(smoothed))`.
2. **Deadband:** no change if `|target − current| < 3`, unless the target is
   the curve's floor or 100 exactly.
3. **Up:** apply immediately, at most +5 per tick.
4. **Down:** only after the target has been below `current` continuously for
   60 s; then at most −1 per tick. Any tick with `target ≥ current` resets the timer.
5. **Emergency:** the emergency signal is raw package temp for fan2 and raw
   GPU junction temp for fan1. If it is ≥ 95 °C on 2 consecutive ticks,
   commit 100 immediately, bypassing rules 2–4. Normal rules resume once it
   reads < 95 °C; the fan then ramps down under rule 4.

## Failure handling

| Situation | Response |
|---|---|
| SIGTERM or SIGINT | set both fans to 50%, then exit |
| Sensor read fails | reuse the last good value; after 5 consecutive failures set that fan to 70% and log an error; resume normal control on the next good read |
| `liquidctl set` fails | log it and keep `current` unchanged, so the next tick retries |
| `liquidctl initialize` fails | exit non-zero |

The unit uses `Restart=always` and `RestartSec=10`.

## Logging

- One line per committed change: `fan2 25→30% (pkg 58.2 °C avg, 61 °C raw)`.
- A status line every 5 minutes.
- A line at local midnight with the day's ramp and write counts per fan.

## Testing

1. **Unit tests.** `test_fan_control.py` uses `unittest` and runs as the flake
   check `raider-fan-control-test`, following the `immich-pixel-sync-test`
   pattern. Cases:
   - curve interpolation and clamping;
   - EMA convergence for a given τ;
   - deadband holds;
   - up rate limit;
   - down only after 60 s, then −1 per tick;
   - timer reset;
   - emergency trigger and release;
   - floor and 100 reachable through the deadband;
   - a recorded spike trace of 41 → 71 → 42 °C over 10 s produces zero commits.
2. **Calibration on raider after deploy.** Run `stress-ng --cpu 16` for 10
   minutes, then record:
   - the plateau of the smoothed package temperature;
   - the duty it settles at;
   - whether the emergency path fired (it should not).

   Adjust the fan2 points above 65 °C if the plateau lands outside roughly
   75–90% duty.
3. **Success criteria**, one normal workday after deploy:
   - under 20 ramps per day in total, where a ramp is a run of same-direction
     commits no more than 120 s apart, counted in the `daily` journal line (a
     −1-per-tick ramp-down is many writes but one ramp);
   - zero ramps while idle.

## Calibration result (2026-09-24)

A 10-minute `stress-ng --cpu 16` run held the raw package temperature at 75–83 °C,
peaking at 87 °C. The emergency path never fired. fan2 levelled off at 52–59%, below
the 75–90% band this spec guessed before measuring. The curve was left unchanged:
full sustained load holds about 17 °C under TjMax at about 55% duty, which is the
balanced target, and pushing the fan to 75–90% would add noise with no thermal need.
The rise committed every 10–110 s, which is why a ramp tolerates 120 s gaps.
