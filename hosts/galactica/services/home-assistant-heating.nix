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
# The heat pump (Kanion, IR-only) heats the living and dining rooms: 18.5-19.5°C
# from 05:00 (an hour of pre-heat) to 22:00, 17-18°C overnight. Its own
# thermostat reads far colder than the room, so it is driven on/off from the
# living area sensor. By day the band is narrow and the setpoint 19, not its
# top: running often and gently beats short bursts at 21, which overshoot.
# Overnight the setpoint is still the top of the band. On frosty
# mornings it shows "dF" and stops blowing for 5-10 minutes while it defrosts;
# the room drops ~1°C and recovers, which is why the backup waits 30 minutes.
#
# Hilo challenges: Hilo lowers the baseboards itself, so the baseboard
# automation stands down from pre_heat through recovery, and the heat pump is
# turned off during the reduction.
{lib, ...}: let
  hiloReduction = "states('sensor.defi_hilo') in ['reduction', 'on']";
  hiloActive = "states('sensor.defi_hilo') in ['pre_heat', 'reduction', 'on', 'recovery']";
  night = "(now().hour >= 22 or now().hour < 6)";

  # Living/dining baseboards: off, unless the heat pump cannot hold the floor.
  backupFloor = "(16 if ${night} else 18)";
  backupTarget = "(${backupFloor} + 1 if is_state('binary_sensor.living_area_needs_backup', 'on') else 5)";

  # Hilo thermostats only support heat; 5°C, their minimum, is off. `at` is
  # the hours a room is reset to its target; fixed-target rooms still reset
  # at the day/night switches, so a manual change lasts until the next one.
  dayNight = [6 22];
  backupRooms = ["living_room_1" "dining_room"];
  baseboards =
    {
      master_bedroom = {
        target = "19";
        at = dayNight;
      };
      amanda_bedroom = {
        target = "19";
        at = dayNight;
      };
      beas_bedroom = {
        target = "19";
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
  services.home-assistant.config = {
    template = [
      {
        sensor = [
          {
            name = "Living area temperature";
            unique_id = "living_area_temperature";
            unit_of_measurement = "°C";
            device_class = "temperature";
            state_class = "measurement";
            availability = "{{ (${livingAreaReadings}) | count > 0 }}";
            state = "{{ (${livingAreaReadings}) | median | round(1) }}";
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
        ];
      }
    ];

    "automation heating" = [
      {
        alias = "Heating - Heat pump";
        description = "Hold the living area at 18.5-19.5°C by day and 17-18°C at night with the heat pump";
        triggers = [
          {
            trigger = "homeassistant";
            event = "start";
          }
          {
            trigger = "time_pattern";
            minutes = "/5";
          }
          {
            trigger = "state";
            entity_id = ["sensor.defi_hilo" "sensor.living_area_temperature"];
          }
        ];
        variables = {
          temp = "{{ states('sensor.living_area_temperature') | float(none) }}";
          day = "{{ 5 <= now().hour < 22 }}";
          low = "{{ 18.5 if day else 17 }}";
          high = "{{ 19.5 if day else 18 }}";
          setpoint = "{{ 19 if day else 18 }}";
          current = "{{ states('climate.living_room_heat_pump') }}";
          want = ''
            {% if ${hiloReduction} %}off
            {% elif temp is none %}{{ current }}
            {% elif temp < low %}heat
            {% elif temp > high %}off
            {% else %}{{ current }}
            {% endif %}
          '';
        };
        actions = [
          {
            choose = [
              {
                conditions = [
                  {
                    condition = "template";
                    value_template = "{{ want == 'heat' and (current != 'heat' or state_attr('climate.living_room_heat_pump', 'temperature') | float(0) != setpoint | float) }}";
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
                    value_template = "{{ want == 'off' and current != 'off' }}";
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
