#!/usr/bin/env python3
"""NZXT H1 V2 fan control for raider.

fan2 (140 mm AIO radiator) follows a slow EMA of the CPU package
temperature, standing in for the coolant temperature the H1 V2 cannot
report. fan1 (92 mm GPU-chamber exhaust) follows the amdgpu edge
temperature. Core temperatures on this CPU jump 20-30 °C within a second,
so nothing here reacts to a raw reading except the emergency override.

Design: docs/superpowers/specs/2026-09-24-raider-fan-control-design.md
"""

import math

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
