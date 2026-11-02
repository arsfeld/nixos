# Cottage Hilo in Home Assistant

## Goal

Control the cottage's Hilo thermostats from galactica's Home Assistant, next to
home's, and heat the cottage automatically: hold a low setpoint while it is
empty, pre-heat when someone drives there, and return to the low setpoint after
everyone leaves.

## Context

- Hilo is cloud-only. The integration talks to Hilo's REST, SignalR and GraphQL
  endpoints and never to the hub on the LAN, so where Home Assistant runs does
  not matter. pegasus being at the cottage gives it no Hilo advantage.
- Home and the cottage are **separate Hilo accounts**.
- The dvd-dev component (`packages/home-assistant-hilo`) allows exactly one
  instance: `config_flow.py` sets the entry's unique ID to the domain and aborts
  with `single_instance_allowed`. It also reads only the first location of an
  account (`pyhilo/api.py`, `get_location_ids` returns `req[0]`), which is
  harmless here since each account has one location.
- `pyhilo` itself supports multiple accounts in one process. The OAuth session,
  `state_yaml` file and device cache are all per instance.
- Rejected alternatives:
  - **A second Home Assistant on pegasus.** The iOS companion app was the
    deciding constraint, and a second instance doubles upkeep.
  - **Our own "hilo-lite" component.** Even a minimal one needs OAuth with PKCE,
    a reconnecting SignalR DeviceHub loop (the REST device list is gone, and the
    numeric device IDs the setpoint `PUT` needs arrive only over SignalR), and
    `SubscribeToLocation`. That glue follows `pyhilo` internals that change, and
    we would own every fix.
  - **Patching dvd-dev for multiple entries.** Its account-wide entities and
    generated energy meters assume one instance, so that patch would be larger
    than the rename below and harder to rebase.

## Design

### 1. A renamed copy of the Hilo component

`packages/home-assistant-hilo-cottage/package.nix` builds dvd-dev's source a
second time as domain `hilo_cottage`. It takes `version` and `src` from
`pkgs.home-assistant-hilo`, so one version bump updates both, and calls
`buildHomeAssistantComponent` with `domain = "hilo_cottage"`.

`postPatch`:

- `mv custom_components/hilo custom_components/hilo_cottage`. The build copies
  `custom_components/` as-is, and the component's imports are all relative.
- `const.py`: `DOMAIN = "hilo"` → `DOMAIN = "hilo_cottage"`.
- `manifest.json`: `"domain": "hilo"` → `"hilo_cottage"`, `"name": "Hilo"` →
  `"Hilo Cottage"`.
- `__init__.py`: `hilo_state.yaml` → `hilo_cottage_state.yaml`. That file holds
  the account's Firebase and Android registration. The two accounts must not
  share it.
- `sensor.py`: `"Defi Hilo"`, `"Recompenses Hilo"`, `"Notifications Hilo"` and
  `"Outdoor Weather Hilo"` each gain the suffix ` Cottage`. Entity IDs then come
  out as `sensor.defi_hilo_cottage` and so on, not as an unpredictable `_2`.
- `climate.py`: the hardcoded `sensor.defi_hilo` (challenge lock) →
  `sensor.defi_hilo_cottage`.

Every substitution uses `substituteInPlace --replace-fail`. A dvd-dev release
that moves any of these strings fails the build instead of shipping a
half-renamed copy.

The OAuth implementation keeps its internal domain `hilo` from `pyhilo.const`.
Home Assistant keys implementations by the flow's domain first, so the copy's
registration under `hilo_cottage` does not collide with home's.

Entity registry keys include the platform (`hilo` or `hilo_cottage`), so unique
IDs cannot collide between the two components.

### 2. A shared patch: unknown-power accounting stays within its own entry

`Hilo.handle_unknown_power` (`__init__.py`) loops over **every** state in Home
Assistant:

- it adds every `*_power` entity except the chosen smart meter to
  `known_power`, then reports `meter − known_power` as
  `sensor.unknown_source_tracker_power`;
- it runs `fix_utility_sensor` on every `*_hilo_energy` entity;
- `find_meter` picks the alphabetically first registry entity whose ID
  contains `meter` and `_power`.

With the cottage added, home's instance would subtract the cottage's thermostat
power and the cottage's smart meter from home's meter.
`sensor.unknown_source_tracker_power` is the heat pump's power proxy in the
heating analysis, so it would quietly read low or zero.

`packages/home-assistant-hilo/unknown-power-own-entry.patch` makes that loop
skip any entity whose entity-registry entry does not belong to this
integration's config entry. `find_meter` gets the same filter. The patch goes
in `patches` for both `home-assistant-hilo` and `home-assistant-hilo-cottage`,
and fails to apply loudly if upstream moves the code.

### 3. Wiring and one-time UI setup

`modules/hosts/galactica/services/home-assistant.nix` adds
`pkgs.home-assistant-hilo-cottage` to `customComponents` beside
`pkgs.home-assistant-hilo`.

Done once, in the UI:

1. Add the "Hilo Cottage" integration and log in with the cottage account.
   Leave options at their defaults: energy meters off, unknown-source tracking
   off, challenge lock off.
2. Create `zone.cottage` at the cottage. Its coordinates stay out of the repo.
3. Add a Proximity entry named "Cottage" for `zone.cottage`, tracking the
   household's `person.*` entities. It provides
   `sensor.cottage_nearest_distance` and
   `sensor.cottage_nearest_direction_of_travel`.

### 4. Cottage heating

New file `modules/hosts/galactica/services/home-assistant-cottage.nix`, kept
separate from `home-assistant-heating/` because it shares nothing with the zone
policy.

Joliette sits about halfway along the one-hour drive, and trips to Joliette
happen both from home and from the cottage. Two rings around `zone.cottage`
tell those trips apart from arrivals and departures:

```
home ──────────── Joliette ──────────── cottage
     outerKm (≈ whole route)
                departKm (just beyond Joliette)
                            innerKm (just inside Joliette)
```

Named values at the top of the file:

| Name | Value |
|------|-------|
| `outerKm` | home's distance to the cottage, minus a margin |
| `innerKm` | Joliette's distance to the cottage, minus ~5 km |
| `departKm` | Joliette's distance to the cottage, plus ~5 km |
| `preheatTimeout` | 45 min |
| `departureDelay` | 30 min |
| `safetyNet` | 12 h |
| `comfort` | 20 °C |
| `away` | 10 °C |
| `thermostats` | list of the cottage's `climate.*` entity IDs |

`outerKm`, `innerKm` and `departKm` are set from
`sensor.cottage_nearest_distance` readings taken at home and in Joliette. `thermostats` is filled in once the integration
has created the entities.

`input_select.cottage_mode` holds `away`, `preheat` or `comfort`, and can be set
by hand from the app. `preheat` and `comfort` both heat to `comfort`.

`"automation cottage"`:

1. **Heading there → `preheat`.** In `away`, the nearest distance drops below
   `outerKm` with direction `towards`. Notify the phone.
2. **Past Joliette or there → `comfort`.** The nearest distance drops below
   `innerKm`, or `zone.cottage` > 0.
3. **Pre-heat that goes nowhere → `away`.** In `preheat`, the direction becomes
   `away_from`, or `preheatTimeout` passes without reaching `comfort`. Notify
   "pre-heat cancelled". A trip from home to Joliette costs at most 45 minutes
   of heating.
4. **Departure → `away`.** `zone.cottage` = 0 and the nearest distance above
   `departKm` (past Joliette, heading home) for `departureDelay`. An errand to
   Joliette from the cottage stays inside `departKm` and keeps `comfort`.
5. **Safety net → `away`.** In `comfort`, `zone.cottage` = 0 for `safetyNet`.
6. **Apply setpoints.** On a mode change, at Home Assistant start, every hour
   while in `away`, and when `sensor.defi_hilo_cottage` leaves a challenge
   phase: set every entry in `thermostats` to the mode's setpoint, unless
   `sensor.defi_hilo_cottage` is in `pre_heat`, `reduction`, `on` or `recovery`.
   Arriving during a challenge therefore warms the cottage after the challenge,
   which lasts at most four hours.

Notifications go to the phone's existing `notify.mobile_app_*` service. Its
exact name is read from galactica's Home Assistant during implementation.

While someone is at the cottage, their `person` is not `home`, so home's policy
treats the house as away, as it already does for any absence. The two policies
share no entities.

## Failure handling

- **Phones stop reporting**, so Proximity reads `unknown`. Numeric triggers do
  not fire on `unknown`. A stuck `preheat` still ends at `preheatTimeout`, and a
  stuck `comfort` at `safetyNet`. The worst case is late heating, never
  unbounded heating.
- **A Hilo call fails, or a setpoint is changed in the Hilo app.** In `away`,
  the hourly re-apply restores 10 °C. In `comfort`, a change made by hand
  stands.
- **The cottage's internet or galactica goes down.** The thermostats keep their
  last setpoint, and the away setpoint is frost-safe. Hilo's own app still
  works.
- **A dvd-dev bump moves a renamed string or the patched loop.** The build
  fails. The weekly update routine sees it and fixes or holds the bump.

## Testing

1. **Flake check `hilo-cottage-rename`.** Inspect the built package and assert:
   `custom_components/hilo_cottage/` exists, `DOMAIN = "hilo_cottage"`, the
   manifest domain is `hilo_cottage`, the state file is
   `hilo_cottage_state.yaml`, the four entity names carry ` Cottage`, and
   `climate.py` has no `sensor.defi_hilo"` left.
2. **Home is unchanged.** galactica builds, and `heating-policy-test` passes.
3. **Unknown-power patch, live.** Deploy before adding the cottage integration
   and check `sensor.unknown_source_tracker_power` against its recent history.
   After adding the cottage, confirm the value has not shifted and the cottage
   has no tracker of its own.
4. **Cottage logic, live.** Override the Proximity sensors and `zone.cottage` in
   Developer Tools → States, and walk through: home → Joliette → cancel;
   home → cottage → `preheat` → `comfort`; a Joliette errand from the cottage;
   departure; the safety net; a challenge ending. Each time, confirm the cottage
   thermostats got the right setpoint and home's did not change.

## Out of scope

- Energy meters, cost tracking and challenge rewards for the cottage.
- Any non-Hilo devices at the cottage.
- Manual arrival-time planning. The geofence is the only arrival signal, with
  `input_select.cottage_mode` as the manual override.
