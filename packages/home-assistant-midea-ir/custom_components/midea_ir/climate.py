"""Climate entity that drives a Midea-protocol AC through a remote entity.

IR is one-way: the state shown is the last one sent, restored across
restarts, and goes stale if someone uses the physical remote. Each frame
is sent twice, 30 seconds apart, so one missed frame does not leave the
unit in the wrong state.
"""

from collections.abc import Callable
from typing import Any

import voluptuous as vol

from homeassistant.components.climate import (
    FAN_AUTO,
    FAN_HIGH,
    FAN_LOW,
    FAN_MEDIUM,
    PLATFORM_SCHEMA as CLIMATE_PLATFORM_SCHEMA,
    ClimateEntity,
    ClimateEntityFeature,
    HVACMode,
)
from homeassistant.const import (
    ATTR_TEMPERATURE,
    CONF_NAME,
    CONF_UNIQUE_ID,
    STATE_UNAVAILABLE,
    STATE_UNKNOWN,
    UnitOfTemperature,
)
from homeassistant.core import Event, EventStateChangedData, HomeAssistant, callback
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.event import (
    async_call_later,
    async_track_state_change_event,
)
from homeassistant.helpers.restore_state import RestoreEntity

from . import midea

CONF_REMOTE = "remote"
CONF_TEMPERATURE_SENSOR = "temperature_sensor"

PLATFORM_SCHEMA = CLIMATE_PLATFORM_SCHEMA.extend(
    {
        vol.Required(CONF_NAME): cv.string,
        vol.Optional(CONF_UNIQUE_ID): cv.string,
        vol.Required(CONF_REMOTE): cv.entity_id,
        vol.Optional(CONF_TEMPERATURE_SENSOR): cv.entity_id,
    }
)

HVAC_TO_MIDEA = {
    HVACMode.HEAT: midea.MODE_HEAT,
    HVACMode.COOL: midea.MODE_COOL,
    HVACMode.HEAT_COOL: midea.MODE_AUTO,
    HVACMode.DRY: midea.MODE_DRY,
    HVACMode.FAN_ONLY: midea.MODE_FAN,
}

FAN_TO_MIDEA = {
    FAN_AUTO: midea.FAN_AUTO,
    FAN_LOW: midea.FAN_LOW,
    FAN_MEDIUM: midea.FAN_MEDIUM,
    FAN_HIGH: midea.FAN_HIGH,
}

ATTR_LAST_MODE = "last_mode"

# Seconds before each frame is sent a second time.
REPEAT_DELAY = 30


async def async_setup_platform(
    hass: HomeAssistant,
    config: dict[str, Any],
    async_add_entities: AddEntitiesCallback,
    discovery_info: dict[str, Any] | None = None,
) -> None:
    async_add_entities([MideaIrClimate(config)])


class MideaIrClimate(ClimateEntity, RestoreEntity):
    _attr_assumed_state = True
    _attr_should_poll = False
    _attr_temperature_unit = UnitOfTemperature.CELSIUS
    _attr_min_temp = midea.MIN_TEMP
    _attr_max_temp = midea.MAX_TEMP
    _attr_target_temperature_step = 1
    _attr_hvac_modes = [HVACMode.OFF, *HVAC_TO_MIDEA]
    _attr_fan_modes = list(FAN_TO_MIDEA)
    _attr_supported_features = (
        ClimateEntityFeature.TARGET_TEMPERATURE
        | ClimateEntityFeature.FAN_MODE
        | ClimateEntityFeature.TURN_ON
        | ClimateEntityFeature.TURN_OFF
    )

    def __init__(self, config: dict[str, Any]) -> None:
        self._attr_name = config[CONF_NAME]
        self._attr_unique_id = config.get(CONF_UNIQUE_ID)
        self._remote = config[CONF_REMOTE]
        self._sensor = config.get(CONF_TEMPERATURE_SENSOR)
        self._attr_hvac_mode = HVACMode.OFF
        self._attr_target_temperature = 21
        self._attr_fan_mode = FAN_AUTO
        # The mode turn_on returns to; also what an "off" frame carries.
        self._last_mode = HVACMode.HEAT
        self._cancel_repeat: Callable[[], None] | None = None

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {ATTR_LAST_MODE: self._last_mode}

    async def async_added_to_hass(self) -> None:
        await super().async_added_to_hass()
        if (last := await self.async_get_last_state()) is not None:
            if last.state in self._attr_hvac_modes:
                self._attr_hvac_mode = HVACMode(last.state)
            if (temp := last.attributes.get(ATTR_TEMPERATURE)) is not None:
                self._attr_target_temperature = float(temp)
            if last.attributes.get("fan_mode") in FAN_TO_MIDEA:
                self._attr_fan_mode = last.attributes["fan_mode"]
            if last.attributes.get(ATTR_LAST_MODE) in HVAC_TO_MIDEA:
                self._last_mode = HVACMode(last.attributes[ATTR_LAST_MODE])

        if self._sensor:
            self._update_current_temperature(self.hass.states.get(self._sensor))
            self.async_on_remove(
                async_track_state_change_event(
                    self.hass, [self._sensor], self._sensor_changed
                )
            )

    @callback
    def _sensor_changed(self, event: Event[EventStateChangedData]) -> None:
        self._update_current_temperature(event.data["new_state"])
        self.async_write_ha_state()

    def _update_current_temperature(self, state) -> None:
        if state is None or state.state in (STATE_UNKNOWN, STATE_UNAVAILABLE):
            self._attr_current_temperature = None
            return
        try:
            self._attr_current_temperature = float(state.state)
        except ValueError:
            self._attr_current_temperature = None

    async def _transmit(self) -> None:
        power = self._attr_hvac_mode != HVACMode.OFF
        data = midea.frame(
            power,
            HVAC_TO_MIDEA[self._last_mode],
            self._attr_target_temperature,
            FAN_TO_MIDEA[self._attr_fan_mode],
        )
        await self.hass.services.async_call(
            "remote",
            "send_command",
            {"entity_id": self._remote, "command": ["b64:" + midea.tuya_code(data)]},
            blocking=True,
        )

    async def _send(self) -> None:
        # Nothing confirms the unit heard a frame, and a missed one stays
        # missed: the entity already shows the new state, so nothing sends
        # again. Every frame carries the whole state, so repeating it is
        # harmless (one more beep); a newer change replaces the pending repeat.
        if self._cancel_repeat is not None:
            self._cancel_repeat()
            self._cancel_repeat = None
        await self._transmit()
        self.async_write_ha_state()
        self._cancel_repeat = async_call_later(self.hass, REPEAT_DELAY, self._repeat)

    async def _repeat(self, _now) -> None:
        self._cancel_repeat = None
        await self._transmit()

    async def async_will_remove_from_hass(self) -> None:
        if self._cancel_repeat is not None:
            self._cancel_repeat()
            self._cancel_repeat = None

    async def async_set_hvac_mode(self, hvac_mode: HVACMode) -> None:
        if hvac_mode != HVACMode.OFF:
            self._last_mode = hvac_mode
        self._attr_hvac_mode = hvac_mode
        await self._send()

    async def async_set_temperature(self, **kwargs: Any) -> None:
        if (temp := kwargs.get(ATTR_TEMPERATURE)) is not None:
            self._attr_target_temperature = round(float(temp))
        if (hvac_mode := kwargs.get("hvac_mode")) is not None:
            await self.async_set_hvac_mode(hvac_mode)
        elif self._attr_hvac_mode == HVACMode.OFF:
            # Every frame carries power, so sending now would switch the
            # unit on; keep the setpoint for the next turn_on instead.
            self.async_write_ha_state()
        else:
            await self._send()

    async def async_set_fan_mode(self, fan_mode: str) -> None:
        self._attr_fan_mode = fan_mode
        if self._attr_hvac_mode == HVACMode.OFF:
            self.async_write_ha_state()
        else:
            await self._send()

    async def async_turn_on(self) -> None:
        await self.async_set_hvac_mode(self._last_mode)

    async def async_turn_off(self) -> None:
        await self.async_set_hvac_mode(HVACMode.OFF)
