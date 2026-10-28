# House heating, scheduled from Home Assistant rather than the Hilo app.
#
# Two kinds of heat, three layers:
#
#   sensors    sensor.living_area_temperature is the median of the IR hub and
#              the two Hilo thermostats under the heat pump. The hub alone
#              reads 1-1.5°C warm; the median ignores whichever one is off.
#              binary_sensor.living_area_needs_backup is the last-resort
#              signal for the living/dining baseboards.
#   policy     the targets below, keyed on the clock and sensor.defi_hilo.
#   actuators  one automation for the heat pump, one for every baseboard.
#              The heat pump is HA's alone: it re-evaluates on a timer and on
#              HA start, so a missed edge or a restart corrects itself. The
#              baseboards are only set at their scheduled switch times (and
#              the living/dining ones when the backup flips); between those
#              they are left to whoever turns the dial or uses the Hilo app.
#              A switch missed while HA was down is skipped, not caught up,
#              so a deploy never overwrites a manual change.
#
# The heat pump (Kanion, IR-only) heats the living and dining rooms, and its heat
# reaches the bedrooms too (their baseboards only hold 18 underneath it), so it
# should run as much as possible: it turns on
# below 18.5°C from 05:00 (an hour of pre-heat) to 22:00 and below 18°C
# overnight, and only shuts down above 21°C. Its own thermostat reads far colder
# than the room, so it is driven on/off from the living area sensor. Its setpoint
# is 19 in mild weather, where running long and gently beats short bursts; below
# 5°C outside it is 21, because at 19 it only holds the room near 18.5 and its
# heat never reaches the bedrooms. It is also 21 whatever the weather from
# 05:00 to 08:00, so the house is warm when everyone wakes around 7, and from
# 10:00 to 13:00, so it is warmer over lunch (11-13) on the heat pump alone;
# each window starts early as pre-heat and turns it on below 21°C rather than
# 18.5, and midday is also when it runs most efficiently. On frosty
# mornings it shows "dF" and stops blowing for 5-10 minutes while it defrosts;
# the room drops ~1°C and recovers, which is why the backup waits 30 minutes.
#
# Hilo challenges: Hilo lowers the baseboards itself, so the baseboard
# automation stands down from pre_heat through recovery, and the heat pump is
# turned off during the reduction.
{lib, ...}: let
  tpl = import ./templates.nix {inherit lib;};
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
  };
  zones = lib.mapAttrs (_: z: zoneDefaults // z) (import ./zones.nix);

  # A zone learns the rate helper named after it; others only borrow one.
  learning = lib.filterAttrs (name: z: z.rate != null && z.rate.helper == name) zones;
  boostHelpers = lib.unique (lib.concatMap (z: lib.optional (z.boost != null) z.boost.helper) (lib.attrValues zones));

  living = tpl.targetEntity "living_area";
  targetAttributes = ["reason" "window" "minutes" "start" "since" "from_temp" "assisted" "reached"];

  hiloReduction = "states('sensor.defi_hilo') in ['reduction', 'on']";
  hiloActive = "states('sensor.defi_hilo') in ['pre_heat', 'reduction', 'on', 'recovery']";
  night = "(now().hour >= 22 or now().hour < 6)";

  # Living/dining baseboards: off, unless the heat pump cannot hold the floor.
  # Last-resort floor for the living/dining baseboards: 17 at night, 18 by day.
  backupFloor = "(17 if state_attr('${living}', 'reason') == 'base' else 18)";
  livingBaseboards = tpl.targetEntity "living_baseboards";
  backupTarget = "(${backupFloor} + 1 if is_state('binary_sensor.living_area_needs_backup', 'on') else 5)";

  # Hilo thermostats only support heat; 5°C, their minimum, is off. `at` is
  # the hours a room is reset to its target; fixed-target rooms still reset
  # at the day/night switches, so a manual change lasts until the next one.
  dayNight = [6 22];
  backupRooms = ["living_room_1" "dining_room"];
  baseboards =
    {
      master_bedroom = {
        target = "18";
        at = dayNight;
      };
      amanda_bedroom = {
        target = "18";
        at = dayNight;
      };
      beas_bedroom = {
        target = "18";
        at = dayNight;
      };
      bathroom = {
        target = "19";
        at = dayNight;
      };

      # Basement
      office = {
        target = "(17 if ${night} else 19)";
        at = dayNight;
      };
      bathroom_downstairs = {
        target = "(17 if ${night} else 19)";
        at = dayNight;
      };

      # Family room (still living_room_2 in HA): too far for the heat pump.
      living_room_2 = {
        target = "(19 if 17 <= now().hour < 22 else 16)";
        at = [17 22];
      };

      # Baseboards not ready yet.
      workshop_1 = {
        target = "5";
        at = dayNight;
      };
      workshop_2 = {
        target = "5";
        at = dayNight;
      };
      garage = {
        target = "5";
        at = dayNight;
      };
    }
    // lib.genAttrs backupRooms (_: {
      target = backupTarget;
      at = dayNight;
    });

  switchHours = lib.unique (lib.concatMap (b: b.at) (lib.attrValues baseboards));
  climates = rooms: map (room: "climate.${room}") rooms;
  roomsAt = hour: climates (lib.attrNames (lib.filterAttrs (_: b: lib.elem hour b.at) baseboards));

  # The rooms each baseboard trigger (by id) is allowed to touch.
  roomsByTrigger =
    lib.listToAttrs (map (hour: lib.nameValuePair (toString hour) (roomsAt hour)) switchHours)
    // {backup = climates backupRooms;};

  livingAreaSensors = [
    "sensor.living_room_ir_temperature_2"
    "sensor.living_room_1_temperature"
    "sensor.dining_room_temperature"
  ];
  livingAreaReadings = "${builtins.toJSON livingAreaSensors} | map('states') | select('is_number') | map('float') | list";
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
            # area target of 20 or more (the eco hours are 19), so zones.nix
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

    "automation heating" = [
      {
        alias = "Heating - Heat pump";
        description = "Run the heat pump below the living area's target - 0.5°C until it passes 21°C (21.5 when boosted); setpoint 21 whenever the target is 20 or more or it is below 5°C outside, else 19";
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
            trigger = "state";
            entity_id = ["sensor.defi_hilo" "sensor.living_area_temperature" living];
          }
        ];
        # HA renders these in order and Nix sorts attribute names, so each
        # may only use variables that sort before it.
        variables = {
          current = "{{ states('climate.living_room_heat_pump') }}";
          # IR is one-way, so the unit can disagree with the state HA
          # restored; on start, send the wanted state even if HA thinks the
          # unit is already there.
          resend = "{{ trigger.id == 'start' }}";
          setpoint = "{{ 21 if states('${living}') | float(0) >= 20 or states('sensor.outdoor_weather_hilo') | float(99) < 5 else 19 }}";
          want = ''
            {%- set temp = states('sensor.living_area_temperature') | float(none) %}
            {%- set target = states('${living}') | float(none) %}
            {%- set high = 21.5 if is_state('${tpl.boostEntity "living_area"}', 'on') else 21 %}
            {%- if ${tpl.hiloReduction} %}off
            {%- elif temp is none or target is none %}{{ current }}
            {%- elif temp < target - 0.5 %}heat
            {%- elif temp > high %}off
            {%- else %}{{ current }}
            {%- endif %}
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
        description = "Set Hilo baseboards to their targets at scheduled switch times, unless a Hilo challenge is running";
        triggers =
          map (hour: {
            trigger = "time";
            at = "${lib.fixedWidthNumber 2 hour}:00:00";
            id = toString hour;
          })
          switchHours
          ++ [
            {
              trigger = "state";
              entity_id = "binary_sensor.living_area_needs_backup";
              to = ["on" "off"];
              id = "backup";
            }
          ];
        conditions = [
          {
            condition = "template";
            value_template = "{{ not (${hiloActive}) }}";
          }
        ];
        variables = {
          rooms = "{{ ${builtins.toJSON roomsByTrigger}[trigger.id] }}";
          targets = "{{ {${lib.concatStringsSep ", " (lib.mapAttrsToList (room: b: "'climate.${room}': ${b.target}") baseboards)}} }}";
        };
        actions = [
          {
            repeat = {
              for_each = "{{ rooms }}";
              sequence = [
                {
                  "if" = [
                    {
                      condition = "template";
                      value_template = "{{ states(repeat.item) not in ['unavailable', 'unknown'] and state_attr(repeat.item, 'temperature') | float(0) != targets[repeat.item] | float }}";
                    }
                  ];
                  "then" = [
                    {
                      action = "climate.set_temperature";
                      target.entity_id = "{{ repeat.item }}";
                      data.temperature = "{{ targets[repeat.item] }}";
                    }
                  ];
                }
              ];
            };
          }
        ];
        mode = "single";
        max_exceeded = "silent";
      }
    ];
  };
}
