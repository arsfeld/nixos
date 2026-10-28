# The heating policy: what each zone should be, and when. Edit here to change
# a schedule; default.nix and templates.nix turn this into Home Assistant.
#
#   base         °C outside every window (5 is a Hilo baseboard's off)
#   weekday,     [from to °C] windows, "HH:MM", "24:00" for midnight; they
#   weekend      may not wrap midnight. Each is reached *by* `from`: zones
#                with a `rate` pre-heat toward the next warmer window.
#   boost        a one-click input_boolean (cleared at midnight) and its °C
#   presence     drop to base once the user has been away 30 minutes
#   rate         warm-up rate in °C/h: the input_number `helper` (learned by
#                the zone of that name), a `seed` until one is learned, and
#                `maxLead`, the most minutes a pre-heat may start early
#   temperature  the room sensor pre-heat and learning read
#   devices      the baseboards this zone's target drives
#   assist       an entity whose "on" marks a pre-heat as helped, so its
#                rate is not learned
{
  # Heat pump zone. Its own baseboards (living_room_1, dining_room) only
  # close a shortfall or back it up; see default.nix.
  living_area = {
    temperature = "sensor.living_area_temperature";
    base = 18;
    # Comfort windows are targets of 20 or more; the shortfall sensor relies on
    # that, so eco/base targets here must stay below 20.
    weekday = [["07:00" "08:00" 20] ["08:00" "17:00" 19] ["17:00" "20:30" 20]];
    weekend = [["07:00" "20:30" 20]];
    boost = {
      helper = "living_area";
      target = 21;
    };
    rate = {
      helper = "living_area";
      seed = 0.4;
      maxLead = 180;
    };
    assist = "binary_sensor.living_area_shortfall";
  };

  # The heat pump carries the bedrooms; their baseboards are a floor.
  bedrooms = {
    base = 18;
    boost = {
      helper = "bedrooms";
      target = 20;
    };
    devices = ["climate.master_bedroom" "climate.amanda_bedroom" "climate.beas_bedroom"];
  };
  bathroom = {
    base = 19;
    boost = {
      helper = "bedrooms";
      target = 20;
    };
    devices = ["climate.bathroom"];
  };

  # Basement: where the user works, gated on their phone.
  office = {
    temperature = "sensor.office_temperature";
    base = 16;
    weekday = [["08:30" "17:00" 21] ["17:00" "20:30" 19] ["20:30" "24:00" 21]];
    weekend = [["08:30" "20:30" 19] ["20:30" "24:00" 21]];
    presence = true;
    boost = {
      helper = "office";
      target = 21;
    };
    rate = {
      helper = "office";
      seed = 1.5;
      maxLead = 210;
    };
    devices = ["climate.office"];
  };
  bathroom_downstairs = {
    temperature = "sensor.bathroom_downstairs_temperature";
    base = 16;
    weekday = [["08:30" "24:00" 19]];
    weekend = [["08:30" "24:00" 19]];
    presence = true;
    boost = {
      helper = "office";
      target = 19;
    };
    rate = {
      helper = "office";
      seed = 1.5;
      maxLead = 120;
    };
    devices = ["climate.bathroom_downstairs"];
  };

  # Family room (still living_room_2 in HA): too far for the heat pump.
  family_room = {
    temperature = "sensor.living_room_2_temperature";
    base = 16;
    weekday = [["17:00" "20:30" 20]];
    weekend = [["08:00" "20:30" 20]];
    rate = {
      helper = "family_room";
      seed = 1.0;
      maxLead = 240;
    };
    devices = ["climate.living_room_2"];
  };

  # Baseboards not ready yet.
  unheated = {
    base = 5;
    devices = ["climate.workshop_1" "climate.workshop_2" "climate.garage"];
  };
}
