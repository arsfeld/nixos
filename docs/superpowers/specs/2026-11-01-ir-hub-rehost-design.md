# IR hub re-discovery and heat pump control alerts

Date: 2026-11-01. Host: galactica.

## Problem

The living room heat pump (Kanion, IR-only) is driven by `midea_ir` through
`remote.living_room_ir`, a Tuya IR hub that tuya_local reaches at a fixed IP.
On 2026-10-26 at 23:37 the hub's DHCP lease moved from `192.168.68.56` to
`192.168.68.77`. tuya_local kept polling `.56` and logged `Failed to refresh
device state for Living room IR` every 90 seconds; every heat pump command was
dropped with only `Referenced entities remote.living_room_ir are missing or not
currently available` in the log. HA's climate entity kept showing whatever it
had last sent, so nothing looked wrong.

The unit stayed on its last received command — heat, 21 — for six days. It is
why the heat pump was "always at 21" and why the bedrooms, at the end of the
corridor it blows down, reached 21–21.5 on 2026-11-01 while HA showed the heat
pump off since 15:15. The dynamic heating policy of 2026-10-28 has never
actually driven the heat pump, so every measurement since then was taken with
it stuck on.

Three defects compound:

1. The hub's address can change, and tuya_local cannot follow it. tuya_local
   2026.5 passes `host` straight to tinytuya and only scans the network in its
   setup flow.
2. Losing the hub is silent.
3. When the hub comes back, nothing re-sends the wanted state. The heat pump
   automation only sends when HA's assumed state differs from the wanted one,
   and HA already assumes it.

## Design

### 1. `tuya-local-rehost` (systemd service and timer)

`modules/hosts/galactica/services/tuya-local-rehost/`: `default.nix` and
`rehost.py`, packaged with `pkgs.writers.writePython3Bin` against
`python3Packages.tinytuya`. Runs as root: it stops and starts
`home-assistant` and edits `/var/lib/hass/.storage/core.config_entries`.

A timer runs it every 5 minutes. Each run, for every config entry with
`domain == "tuya_local"`:

1. TCP connect to `data.host:6668`, 3 s timeout. Success resets the entry's
   failure count; done.
2. On failure, increment the count, kept in a JSON file under
   `StateDirectory=tuya-local-rehost`. Below 2, done.
3. At 2 or more, `tinytuya.find_device(data.device_id)`. This passively listens
   for the device's own UDP broadcast, which carries its id and IP; verified on
   2026-11-01 to work while HA is running.
4. If found at an IP different from `data.host`, and no rewrite happened in the
   last hour: stop `home-assistant`, copy the file to
   `core.config_entries.bak-<UTC timestamp>`, set `data.host` to the new IP,
   write atomically (temp file, `rename`) with owner `hass:hass` and the
   original mode, start `home-assistant`, reset the count, record the rewrite
   time. Log old and new IP.
5. Otherwise (not found, same IP, or rate limited), log and do nothing. The
   alert below covers those cases.

`rehost.py` keeps the decision in one pure function: entries, reachability,
discovery results and state in; a list of actions and the new state out. The
I/O (sockets, tinytuya, systemctl, file writes) is a thin shell around it.

The restart is deliberate. It is what makes tuya_local reconnect, and HA's
`start` trigger in the heat pump automation re-sends the wanted state. With the
DHCP reservation in place, a move should be rare.

### 2. Re-send when the hub comes back

The heat pump automation in `home-assistant-heating/default.nix` gains a
trigger: `remote.living_room_ir` changing from `unavailable` to any other
state, with id `ir_back`. `resend` becomes true for `start` and `ir_back`, so
both get the existing wait for the hub and the forced send. This covers a hub
that reboots or reconnects without an HA restart.

### 3. Alert on loss and recovery

A new automation in the same file:

- `remote.living_room_ir` is `unavailable` for 15 minutes:
  `notify.mobile_app_alexandres_iphone`, "Heat pump not controlled: the IR hub
  is unreachable".
- It changes from `unavailable` to available after having been unavailable
  for at least 15 minutes: "Heat pump control restored".

### 4. Manual step and docs

- The user adds a DHCP reservation for the hub at `192.168.68.77` on the Deco,
  which is the DHCP server for `192.168.68.0/22` and is not in Nix.
- The comment beside the `midea_ir` climate in `home-assistant.nix` records the
  reservation and points to `tuya-local-rehost`.

## Testing

- `test_rehost.py` covers the decision function: reachable, a single failure,
  two failures moved, two failures not found, same IP, and rate limited. It is
  wired into `modules/flake/checks.nix` as `tuya-local-rehost-test`, the same
  way as `heating-policy-test`.
- `heating-policy-test` is updated if it covers the heat pump automation's
  triggers, and must pass.
- Live: on galactica, `.56` is dead today. The first deploy should log two
  failures, discover `.77`, rewrite the entry and restart HA.
  `remote.living_room_ir` should then be available, the heat pump should get
  its wanted state, and the user should confirm the unit obeys.

## Out of scope

The bedrooms at about 19°C all day, the user's original request. Revisit it
after 3–4 days of the policy really driving the heat pump, comparing the
bedroom thermostats with `sensor.living_area_temperature`. The open question
then is which zone wins when the heat pump cannot hold the living area at 20
and the bedrooms at 19 at once.
