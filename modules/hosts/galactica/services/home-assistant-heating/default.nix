# House heating, scheduled from Home Assistant rather than the Hilo app.
# Design: docs/superpowers/specs/2026-10-28-dynamic-heating-design.md
#
#   policy     _zones.nix: each zone's weekly windows, base, boost, presence
#              gating and warm-up rate. Change a schedule there.
#   sensors    sensor.heating_<zone>_target is what each zone wants now (see
#              _templates.nix `plan`); its `reason` attribute says why (base,
#              schedule, preheat, boost, away) and `start` when the next
#              pre-heat begins. sensor.living_area_temperature is the median
#              of the IR hub and the two Hilo thermostats under the heat pump;
#              the hub alone reads 1-1.5°C warm. binary_sensor.living_area_
#              shortfall and _needs_backup bring in the living/dining
#              baseboards through sensor.heating_living_baseboards_target.
#   actuators  one automation for the heat pump, one for every baseboard.
#              The heat pump is HA's alone: it re-evaluates on a timer and
#              re-sends its state on HA start and when the IR hub returns, so
#              a missed edge, a restart or a hub outage corrects itself. A
#              baseboard is set when its zone's target changes, on HA start,
#              every morning at 06:00 and when a Hilo challenge ends; between
#              those it is left to whoever turns the dial or uses the Hilo app.
#
# Pre-heat starts (target - temp) / rate before a window; a zone that owns a
# rate helper learns it from its own unassisted pre-heats. The heat pump
# (Kanion, IR-only) heats the living and dining rooms and, through them, the
# bedrooms, so it stays on all the time (2026-11-07: every rule that let it
# switch off left the house cold), except during a Hilo reduction.
# Its setpoint is always 21: it never gets the room to 21, and 21 is how
# it pushes heat through the house (at 19 its own sensor, which reads warm
# near the unit, idles it). On frosty
# mornings it shows "dF" and stops blowing for 5-10 minutes while it
# defrosts; the room drops ~1°C and recovers, which is why the backup waits
# 30 minutes.
#
# Hilo challenges: Hilo lowers the baseboards itself, so the baseboard
# automation stands down from pre_heat through recovery and re-asserts every
# zone once the challenge ends, and the heat pump is turned off during the
# reduction. Boosts (cleared at midnight) do not override a challenge.
{
  configurations.nixos.galactica.module = {lib, ...}: let
    tpl = import ./_templates.nix {inherit lib;};
    pretty = lib.replaceStrings ["_"] [" "];

    zoneDefaults = {
      temperature = null;
      weekday = [];
      weekend = [];
      boost = null;
      presence = false;
      rate = null;
      devices = [];
      assist = null;
      outdoor = [];
    };
    zones = lib.mapAttrs (_: z: zoneDefaults // z) (import ./_zones.nix);

    # A zone learns the rate helper named after it; others only borrow one.
    learning = lib.filterAttrs (name: z: z.rate != null && z.rate.helper == name) zones;
    boostHelpers = lib.unique (lib.concatMap (z: lib.optional (z.boost != null) z.boost.helper) (lib.attrValues zones));

    living = tpl.targetEntity "living_area";
    irHub = "remote.living_room_ir";
    phone = "notify.mobile_app_alexandres_iphone";
    livingBaseboards = tpl.targetEntity "living_baseboards";
    targetAttributes = ["reason" "window" "minutes" "start" "since" "from_temp" "assisted" "reached" "outdoor_cap"];

    # Last-resort floor for the living/dining baseboards: 17 at night, 18 by day.
    backupFloor = "(17 if state_attr('${living}', 'reason') == 'base' else 18)";

    # Every target sensor that drives baseboards, and the baseboards it drives.
    baseboards =
      lib.mapAttrs' (name: z: lib.nameValuePair (tpl.targetEntity name) z.devices)
      (lib.filterAttrs (_: z: z.devices != []) zones)
      // {${livingBaseboards} = ["climate.living_room_1" "climate.dining_room"];};

    livingAreaSensors = [
      "sensor.living_room_ir_temperature_2"
      "sensor.living_room_1_temperature"
      "sensor.dining_room_temperature"
    ];
    livingAreaReadings = "${builtins.toJSON livingAreaSensors} | map('states') | select('is_number') | map('float') | list";

    # Fold the rate an unassisted pre-heat achieved into the zone's helper (30%
    # new), clamped to 0.2-3 °C/h. A run is sampled when it reaches its target
    # (`reached`), or, if it never did, when the window opens (`late`) - which
    # is what lets a too-high rate come back down. The window opening clears
    # the run's attributes, so the late path reads them from the old state.
    # Runs under 15 minutes, helped by the shortfall baseboards, during a Hilo
    # challenge, or with a baseboard dial moved off the target are not learned
    # from; a boost or presence change takes the pre-heat to `boost`/`away`
    # rather than `schedule`, so neither path sees it.
    learn = name: z: let
      sensor = tpl.targetEntity name;
      run = attr: "{{ trigger.from_state.attributes.get('${attr}') if trigger.id == 'late' else state_attr('${sensor}', '${attr}') }}";
      sameSetpoint = lib.concatMapStrings (d: " and state_attr('${d}', 'temperature') | float(0) == states('${sensor}') | float(0)") z.devices;
    in {
      alias = "Heating - Learn ${pretty name} warm-up rate";
      description = "Learn how fast pre-heat warms the ${pretty name}";
      triggers = [
        {
          trigger = "template";
          value_template = "{{ state_attr('${sensor}', 'reason') == 'preheat' and state_attr('${sensor}', 'reached') == true }}";
          id = "reached";
        }
        {
          trigger = "state";
          entity_id = sensor;
          attribute = "reason";
          from = "preheat";
          to = "schedule";
          id = "late";
        }
      ];
      # The run being sampled; none depends on another.
      variables = {
        assisted = run "assisted";
        from_temp = run "from_temp";
        reached = run "reached";
        since = run "since";
        temp = "{{ states('${z.temperature}') }}";
      };
      conditions = [
        {
          condition = "template";
          value_template = ''
            {%- set since = since | float(none) %}
            {%- set start = from_temp | float(none) %}
            {%- set temp = temp | float(none) %}
            {{ since is not none and start is not none and temp is not none
               and (trigger.id == 'reached' or not reached)
               and now().timestamp() - since >= 900 and temp > start
               and not assisted
               and not (${tpl.hiloActive})${sameSetpoint} }}
          '';
        }
      ];
      actions = [
        {
          action = "input_number.set_value";
          target.entity_id = tpl.rateEntity name;
          data.value = ''
            {%- set hours = (now().timestamp() - since | float) / 3600 %}
            {%- set observed = (temp | float - from_temp | float) / hours %}
            {{ ([[0.7 * ${tpl.rate z} + 0.3 * observed, 3] | min, 0.2] | max) | round(2) }}
          '';
        }
      ];
      mode = "single";
    };
  in {
    # Pre-heat never looks past midnight, so no window may need to start
    # before it.
    assertions = lib.concatLists (lib.mapAttrsToList (name: z:
      lib.optionals (z.rate != null) (map (w: {
        assertion = tpl.minutes (builtins.elemAt w 0) >= z.rate.maxLead;
        message = "heating zone ${name}: the ${builtins.elemAt w 0} window would pre-heat before midnight";
      }) (z.weekday ++ z.weekend)))
    zones);

    services.home-assistant.config = {
      input_boolean = lib.listToAttrs (map (h:
        lib.nameValuePair "heating_boost_${h}" {
          name = "Boost ${pretty h}";
          icon = "mdi:fire";
        })
      boostHelpers);

      input_number = lib.mapAttrs' (name: _:
        lib.nameValuePair "heating_rate_${name}" {
          name = "Heating rate ${pretty name}";
          min = 0;
          max = 3;
          step = 0.01;
          mode = "box";
          unit_of_measurement = "°C/h";
        })
      learning;

      template = [
        {
          sensor =
            [
              {
                name = "Living area temperature";
                unique_id = "living_area_temperature";
                unit_of_measurement = "°C";
                device_class = "temperature";
                state_class = "measurement";
                availability = "{{ (${livingAreaReadings}) | count > 0 }}";
                state = "{{ (${livingAreaReadings}) | median | round(1) }}";
              }
            ]
            ++ lib.mapAttrsToList (name: z: {
              name = "Heating ${pretty name} target";
              unique_id = "heating_${name}_target";
              unit_of_measurement = "°C";
              device_class = "temperature";
              state = "${tpl.plan z}{{ p.target }}";
              attributes = lib.genAttrs targetAttributes (a: "${tpl.plan z}{{ p.${a} }}");
            })
            zones
            ++ [
              {
                # The living/dining baseboards: off, unless the heat pump is
                # about to miss a comfort window (shortfall) or cannot hold the
                # floor at all (backup).
                name = "Heating living baseboards target";
                unique_id = "heating_living_baseboards_target";
                unit_of_measurement = "°C";
                device_class = "temperature";
                state = ''
                  {%- if is_state('binary_sensor.living_area_shortfall', 'on') %}{{ states('${living}') }}
                  {%- elif is_state('binary_sensor.living_area_needs_backup', 'on') %}{{ ${backupFloor} + 1 }}
                  {%- else %}5
                  {%- endif %}
                '';
              }
            ];
          binary_sensor = [
            {
              name = "Living area needs backup";
              unique_id = "living_area_needs_backup";
              delay_on.minutes = 30;
              state = ''
                {% set t = states('sensor.living_area_temperature') | float(none) %}
                {% set floor = ${backupFloor} %}
                {{ t is not none and (t < floor or (this.state == 'on' and t < floor + 1)) }}
              '';
            }
            {
              # Not home for 30 minutes; unknown counts as home, so heat fails warm.
              name = "Alexandre away";
              unique_id = "alexandre_away";
              delay_on.minutes = 30;
              state = "{{ states('person.alexandre_rosenfeld') not in ['home', 'unknown', 'unavailable'] }}";
            }
            {
              # The heat pump will miss the comfort window: within 45 minutes
              # of it, temp + rate × time left is short of the target. Holds
              # until the room gets there or the window ends. A boost brings the
              # living/dining baseboards in at once, until the room reaches 21,
              # because someone is cold now. "Comfort window" here means a living
              # area target of 20 or more (the eco hours are 19), so _zones.nix
              # must keep eco/base targets for living_area below 20.
              name = "Living area shortfall";
              unique_id = "living_area_shortfall";
              state = ''
                {%- set target = states('${living}') | float(none) %}
                {%- set temp = states('sensor.living_area_temperature') | float(none) %}
                {%- set reason = state_attr('${living}', 'reason') %}
                {%- set minutes = state_attr('${living}', 'minutes') %}
                {%- if target is none or temp is none or temp >= target %}{{ false }}
                {%- elif reason == 'boost' %}{{ true }}
                {%- elif this.state == 'on' and (reason == 'preheat' or (reason == 'schedule' and target >= 20)) %}{{ true }}
                {%- elif reason == 'preheat' %}{{ minutes is not none and minutes <= 45 and temp + ${tpl.rate zones.living_area} * minutes / 60 < target }}
                {%- else %}{{ false }}
                {%- endif %}
              '';
            }
          ];
        }
      ];

      "automation heating" =
        [
          {
            alias = "Heating - Heat pump";
            description = "Keep the heat pump on, except during a Hilo reduction, at setpoint 21";
            triggers = [
              {
                trigger = "homeassistant";
                event = "start";
                id = "start";
              }
              {
                trigger = "time_pattern";
                minutes = "/5";
              }
              {
                # not_to makes this fire on state changes only, not on every
                # attribute tick of the living target (pre-heat minutes); the
                # timer above covers anything else.
                trigger = "state";
                entity_id = ["sensor.defi_hilo" "sensor.living_area_temperature" living];
                not_to = ["unknown" "unavailable"];
              }
              {
                # Commands sent while the IR hub is unavailable are dropped,
                # yet HA's climate state moves as if they were not, so the unit
                # is stuck on whatever it last received (see tuya-local-rehost).
                trigger = "state";
                entity_id = irHub;
                from = "unavailable";
                not_to = ["unknown" "unavailable"];
                id = "ir_back";
              }
            ];
            # HA renders these in order and Nix sorts attribute names, so each
            # may only use variables that sort before it.
            variables = {
              current = "{{ states('climate.living_room_heat_pump') }}";
              # IR is one-way, so the unit can disagree with the state HA
              # restored or assumed; on start, and when the IR hub comes back,
              # send the wanted state even if HA thinks the unit is already there.
              resend = "{{ trigger.id in ['start', 'ir_back'] }}";
              setpoint = "{{ 21 }}";
              want = ''
                {%- if ${tpl.hiloReduction} %}off{% else %}heat{% endif %}
              '';
            };
            actions = [
              {
                # Give the IR hub time to connect after a restart.
                "if" = [
                  {
                    condition = "template";
                    value_template = "{{ resend }}";
                  }
                ];
                "then" = [{delay.seconds = 60;}];
              }
              {
                choose = [
                  {
                    conditions = [
                      {
                        condition = "template";
                        value_template = "{{ want == 'heat' and (resend or current != 'heat' or state_attr('climate.living_room_heat_pump', 'temperature') | float(0) != setpoint | float) }}";
                      }
                    ];
                    sequence = [
                      {
                        action = "climate.set_temperature";
                        target.entity_id = "climate.living_room_heat_pump";
                        data = {
                          hvac_mode = "heat";
                          temperature = "{{ setpoint }}";
                        };
                      }
                    ];
                  }
                  {
                    conditions = [
                      {
                        condition = "template";
                        value_template = "{{ want == 'off' and (resend or current != 'off') }}";
                      }
                    ];
                    sequence = [
                      {
                        action = "climate.turn_off";
                        target.entity_id = "climate.living_room_heat_pump";
                      }
                    ];
                  }
                ];
              }
            ];
            mode = "single";
            max_exceeded = "silent";
          }
          {
            alias = "Heating - Baseboards";
            description = "Set each zone's baseboards when its target changes, and all of them at 06:00 and when a Hilo challenge ends, unless one is running";
            triggers = [
              {
                # HA arms triggers only once it has started, after most targets
                # have already rendered, so re-assert every zone then; otherwise
                # a restart (or an outage) leaves each baseboard on whatever it
                # had until the 06:00 re-assert.
                trigger = "homeassistant";
                event = "start";
                id = "all";
              }
              {
                # No not_from, for a target that only renders after the start.
                trigger = "state";
                entity_id = lib.attrNames baseboards;
                not_to = ["unknown" "unavailable"];
                id = "change";
              }
              {
                # Re-assert every zone daily, so a dial turned by hand lasts at
                # most until morning and a changed _zones.nix applies by then.
                trigger = "time";
                at = "06:00:00";
                id = "all";
              }
              {
                # Target changes during a challenge are dropped, and Hilo then
                # restores its pre-challenge setpoints, so re-assert every zone
                # once it ends.
                trigger = "state";
                entity_id = "sensor.defi_hilo";
                not_from = ["unknown" "unavailable"];
                to = "off";
                id = "all";
              }
            ];
            conditions = [
              {
                condition = "template";
                value_template = "{{ not (${tpl.hiloActive}) }}";
              }
              {
                # With not_from/not_to set, HA already ignores attribute-only
                # changes (pre-heat minutes tick every minute); this is a cheap
                # guard that only a new target counts.
                condition = "template";
                value_template = "{{ trigger.id == 'all' or trigger.from_state.state != trigger.to_state.state }}";
              }
            ];
            variables.pairs = ''
              {%- set ns = namespace(pairs=[]) %}
              {%- for sensor, climates in (${builtins.toJSON baseboards}).items() if trigger.id == 'all' or sensor == trigger.entity_id %}
                {%- for climate in climates %}
                  {%- set ns.pairs = ns.pairs + [[climate, states(sensor)]] %}
                {%- endfor %}
              {%- endfor %}
              {{ ns.pairs }}
            '';
            actions = [
              {
                repeat = {
                  for_each = "{{ pairs }}";
                  sequence = [
                    {
                      "if" = [
                        {
                          condition = "template";
                          value_template = "{{ states(repeat.item[0]) not in ['unavailable', 'unknown'] and repeat.item[1] is is_number and state_attr(repeat.item[0], 'temperature') | float(0) != repeat.item[1] | float }}";
                        }
                      ];
                      "then" = [
                        {
                          action = "climate.set_temperature";
                          target.entity_id = "{{ repeat.item[0] }}";
                          data.temperature = "{{ repeat.item[1] }}";
                        }
                      ];
                    }
                  ];
                };
              }
            ];
            mode = "queued";
          }
          {
            # The IR hub once sat unreachable for six days with nothing but a
            # log line to show for it, and the heat pump stuck on heat 21.
            alias = "Heating - IR hub alert";
            description = "Tell the phone when the heat pump's IR hub has been unavailable for 15 minutes, and when it is back";
            triggers = [
              {
                trigger = "state";
                entity_id = irHub;
                to = "unavailable";
                for.minutes = 15;
                id = "lost";
              }
              {
                trigger = "state";
                entity_id = irHub;
                from = "unavailable";
                not_to = ["unknown" "unavailable"];
                id = "back";
              }
            ];
            conditions = [
              {
                # Only report a recovery from an outage that was reported.
                condition = "template";
                value_template = "{{ trigger.id == 'lost' or (now() - trigger.from_state.last_changed).total_seconds() >= 900 }}";
              }
            ];
            actions = [
              {
                action = phone;
                data = {
                  title = "Heat pump";
                  message = "{{ 'Not controlled: the IR hub is unreachable, so commands are dropped.' if trigger.id == 'lost' else 'Control restored: the IR hub is back.' }}";
                };
              }
            ];
            mode = "queued";
          }
          {
            alias = "Heating - Clear boosts";
            description = "Turn every heating boost off at midnight, so none is forgotten on";
            triggers = [
              {
                trigger = "time";
                at = "00:00:00";
              }
            ];
            actions = [
              {
                action = "input_boolean.turn_off";
                target.entity_id = map tpl.boostEntity boostHelpers;
              }
            ];
            mode = "single";
          }
        ]
        ++ lib.mapAttrsToList learn learning;
    };
  };
}
