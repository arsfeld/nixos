#!/usr/bin/env python3
"""NZXT H1 V2 fan control for raider.

fan2 (140 mm AIO radiator) follows a slow EMA of the CPU package
temperature, standing in for the coolant temperature the H1 V2 cannot
report. fan1 (92 mm GPU-chamber exhaust) follows the amdgpu edge
temperature. Core temperatures on this CPU jump 20-30 °C within a second,
so nothing here reacts to a raw reading except the emergency override.

Design: docs/superpowers/specs/2026-09-24-raider-fan-control-design.md
"""

import glob
import logging
import math
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import date
from typing import Callable

log = logging.getLogger("fan-control")

FAN2_CURVE = [(55, 25), (65, 35), (75, 50), (85, 75), (92, 100)]
FAN1_CURVE = [(60, 30), (75, 40), (85, 60), (95, 100)]

DEADBAND = 3  # % — ignore smaller target changes, except to reach floor or 100
UP_STEP = 5  # % per tick
DOWN_STEP = 1  # % per tick
DOWN_HOLD = 60.0  # s the target must stay below current before ramping down
EMERGENCY_TEMP = 95.0  # °C raw
EMERGENCY_TICKS = 2


class Ema:
    """Exponential moving average with a time constant in seconds."""

    def __init__(self, tau: float):
        self.tau = tau
        self.value: float | None = None

    def update(self, sample: float, dt: float) -> float:
        if self.value is None:
            self.value = sample
        else:
            self.value += (1 - math.exp(-dt / self.tau)) * (sample - self.value)
        return self.value


class Curve:
    """Piecewise-linear temperature -> duty, clamped at both ends."""

    def __init__(self, points: list[tuple[float, int]]):
        self.points = sorted(points)

    @property
    def floor(self) -> int:
        return self.points[0][1]

    def __call__(self, temp: float) -> float:
        if temp <= self.points[0][0]:
            return self.points[0][1]
        for (t0, d0), (t1, d1) in zip(self.points, self.points[1:]):
            if temp <= t1:
                return d0 + (d1 - d0) * (temp - t0) / (t1 - t0)
        return self.points[-1][1]


class Governor:
    """Decides when a fan's duty actually changes. Pure: no I/O, no clock."""

    def __init__(self, curve: Curve, current: int):
        self.curve = curve
        self.current = current
        self.below_since: float | None = None
        self.hot_ticks = 0

    def step(self, smoothed: float, emergency: float, now: float) -> int | None:
        self.hot_ticks = self.hot_ticks + 1 if emergency >= EMERGENCY_TEMP else 0
        if self.hot_ticks >= EMERGENCY_TICKS:
            self.below_since = None
            return None if self.current == 100 else 100

        target = round(self.curve(smoothed))
        if target >= self.current:
            self.below_since = None
        elif self.below_since is None:
            self.below_since = now

        if target == self.current:
            return None
        if abs(target - self.current) < DEADBAND and target not in (self.curve.floor, 100):
            return None
        if target > self.current:
            return min(target, self.current + UP_STEP)
        if now - self.below_since < DOWN_HOLD:
            return None
        return max(target, self.current - DOWN_STEP)

    def commit(self, duty: int) -> None:
        self.current = duty


HWMON_ROOT = "/sys/class/hwmon"


def _read_text(path: str) -> str | None:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def find_temp(chip: str, label: str, root: str = HWMON_ROOT) -> str:
    """Path of the tempN_input for `chip`'s sensor labelled `label`.

    hwmon indices are assigned at boot, so resolve by name, never by number.
    """
    for hwmon in sorted(glob.glob(f"{root}/hwmon*")):
        if _read_text(f"{hwmon}/name") != chip:
            continue
        for label_path in sorted(glob.glob(f"{hwmon}/temp*_label")):
            if _read_text(label_path) == label:
                return label_path.removesuffix("_label") + "_input"
    raise LookupError(f"no {chip} temperature labelled {label!r} under {root}")


def read_temp(path: str) -> float | None:
    try:
        return int(_read_text(path)) / 1000
    except (TypeError, ValueError):
        return None


class Device:
    """The H1 V2 through the liquidctl CLI. Fixed duties only: the device has
    no onboard curves and no coolant sensor."""

    def __init__(self, run=subprocess.run):
        self.run = run

    def _liquidctl(self, *args: str) -> bool:
        cmd = ["liquidctl", *args]
        try:
            result = self.run(cmd, capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as e:
            log.error("%s: %s", " ".join(cmd), e)
            return False
        if result.returncode != 0:
            log.error("%s: exit %d: %s", " ".join(cmd), result.returncode, result.stderr.strip())
            return False
        return True

    def initialize(self) -> bool:
        return self._liquidctl("initialize")

    def set_duty(self, fan: str, duty: int) -> bool:
        return self._liquidctl("set", fan, "speed", str(duty))


TICK = 2.0  # s
FAILSAFE_AFTER = 5  # consecutive sensor failures
FAILSAFE_DUTY = 70
EXIT_DUTY = 50  # the device holds its last duty if we die
STATUS_EVERY = 300.0  # s
RAMP_GAP = 120.0  # s — same-direction commits closer than this are one ramp

Reading = tuple[float, float]  # (control signal, emergency signal), °C


@dataclass
class Channel:
    fan: str  # liquidctl channel
    name: str  # signal label for logs
    read: Callable[[], Reading | None]
    ema: Ema
    governor: Governor
    last: Reading | None = None
    failures: int = 0
    commits: int = 0
    ramps: int = 0  # runs of consecutive same-direction commits; the success metric
    last_dir: int = 0
    last_commit: float = -math.inf


def reader(signal_path: str, emergency_path: str) -> Callable[[], Reading | None]:
    def read() -> Reading | None:
        s, e = read_temp(signal_path), read_temp(emergency_path)
        return None if s is None or e is None else (s, e)

    return read


def apply(ch: Channel, duty: int, now: float, device: Device, why: str) -> None:
    previous = ch.governor.current
    if not device.set_duty(ch.fan, duty):
        return  # current unchanged, so the next tick retries
    direction = 1 if duty > previous else -1
    if direction != ch.last_dir or now - ch.last_commit > RAMP_GAP:
        ch.ramps += 1
    ch.commits += 1
    ch.last_dir, ch.last_commit = direction, now
    ch.governor.commit(duty)
    log.info("%s %d→%d%% (%s)", ch.fan, previous, duty, why)


def prime(ch: Channel, device: Device) -> bool:
    """Set the initial duty from the first reading; the device's own is unknown."""
    reading = ch.read()
    if reading is None:
        duty = FAILSAFE_DUTY
    else:
        ch.last = reading
        duty = round(ch.governor.curve(ch.ema.update(reading[0], TICK)))
    if not device.set_duty(ch.fan, duty):
        return False
    ch.governor.commit(duty)
    log.info("%s start at %d%%", ch.fan, duty)
    return True


def tick(ch: Channel, now: float, dt: float, device: Device) -> None:
    reading = ch.read()
    if reading is None:
        ch.failures += 1
        if ch.failures >= FAILSAFE_AFTER:
            if ch.failures == FAILSAFE_AFTER:
                log.error("%s: %d consecutive sensor failures", ch.fan, ch.failures)
            if ch.governor.current != FAILSAFE_DUTY:
                apply(ch, FAILSAFE_DUTY, now, device, "sensor failsafe")
            return
        if ch.last is None:
            return
        reading = ch.last
    else:
        ch.failures = 0
        ch.last = reading
    raw, emergency = reading
    smoothed = ch.ema.update(raw, dt)
    duty = ch.governor.step(smoothed, emergency, now)
    if duty is not None:
        apply(ch, duty, now, device, f"{ch.name} {smoothed:.1f} °C avg, {raw:.0f} °C raw")


def status(channels: list[Channel]) -> str:
    def avg(ch: Channel) -> str:
        return "no reading" if ch.ema.value is None else f"{ch.ema.value:.1f} °C avg"

    return ", ".join(f"{ch.fan} {ch.governor.current}% ({ch.name} {avg(ch)})" for ch in channels)


def run(channels: list[Channel], device: Device) -> None:
    last = time.monotonic()
    next_status = last + STATUS_EVERY
    day = date.today()
    while True:
        time.sleep(TICK)
        now = time.monotonic()
        dt, last = now - last, now
        for ch in channels:
            tick(ch, now, dt, device)
        if now >= next_status:
            log.info("status: %s", status(channels))
            next_status = now + STATUS_EVERY
        if date.today() != day:
            summary = ", ".join(f"{ch.fan} {ch.ramps} ramps/{ch.commits} writes" for ch in channels)
            log.info("daily %s: %s", day.isoformat(), summary)
            for ch in channels:
                ch.ramps = ch.commits = 0
            day = date.today()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    pkg = find_temp("coretemp", "Package id 0")
    channels = [
        Channel("fan2", "pkg", reader(pkg, pkg), Ema(60), Governor(Curve(FAN2_CURVE), 0)),
        Channel(
            "fan1",
            "gpu",
            reader(find_temp("amdgpu", "edge"), find_temp("amdgpu", "junction")),
            Ema(30),
            Governor(Curve(FAN1_CURVE), 0),
        ),
    ]
    device = Device()
    if not device.initialize():
        return 1
    try:
        for ch in channels:
            if not prime(ch, device):
                return 1
        run(channels, device)
    finally:
        for ch in channels:
            device.set_duty(ch.fan, EXIT_DUTY)
        log.info("exit: fans set to %d%%", EXIT_DUTY)
    return 0


if __name__ == "__main__":
    sys.exit(main())
