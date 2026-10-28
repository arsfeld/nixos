# Jinja generators for the heating policy, as pure functions of a zone from
# zones.nix (with default.nix's defaults merged in). test_heating.py renders
# their output.
{lib}: let
  num = builtins.toJSON;
in rec {
  minutes = hhmm: let
    parts = lib.splitString ":" hhmm;
  in
    lib.toIntBase10 (builtins.elemAt parts 0) * 60 + lib.toIntBase10 (builtins.elemAt parts 1);
  windows = map (w: [(minutes (builtins.elemAt w 0)) (minutes (builtins.elemAt w 1)) (builtins.elemAt w 2)]);

  hiloActive = "states('sensor.defi_hilo') in ['pre_heat', 'reduction', 'on', 'recovery']";
  hiloReduction = "states('sensor.defi_hilo') in ['reduction', 'on']";

  awayEntity = "binary_sensor.alexandre_away";
  targetEntity = zone: "sensor.heating_${zone}_target";
  boostEntity = helper: "input_boolean.heating_boost_${helper}";
  rateEntity = helper: "input_number.heating_rate_${helper}";

  # The learned warm-up rate in °C/h, or the seed until one is learned: an
  # input_number starts at its minimum, 0.
  rate = zone: let
    learned = "states('${rateEntity zone.rate.helper}') | float(0)";
  in "(([${learned}, 3] | min) if ${learned} >= 0.2 else ${num zone.rate.seed})";

  # Pre-heat toward the next window today that is warmer than now, starting
  # (target - temp) / rate early, capped at maxLead. Once started it latches
  # through `this` until the window opens, so the lead shrinking as the room
  # warms cannot switch it back off. `since`, `from_temp`, `assisted` and
  # `reached` feed rate learning. Template sensors are not restored across a
  # Home Assistant restart, so `this.attributes` is then empty: a running
  # pre-heat is re-planned from the current temperature (it still reaches the
  # target by the window), and `since`/`from_temp` restart at that moment, so
  # the learning sample covers only the rest of the run.
  preheat = zone: let
    maxLead = num zone.rate.maxLead;
    assist = lib.optionalString (zone.assist != null) " or is_state('${zone.assist}', 'on')";
  in ''
    {%- set temp = states('${zone.temperature}') | float(none) %}
    {%- set rate = ${rate zone} %}
    {%- set next = namespace(w=none) %}
    {%- for w in wins if w[0] > m and w[2] > p.target and next.w is none %}
      {%- set next.w = w %}
    {%- endfor %}
    {%- if next.w is not none %}
      {%- set nw = next.w %}
      {%- set lead = ${maxLead} if temp is none else [0, [(nw[2] - temp) / rate * 60, ${maxLead}] | min] | max %}
      {%- set p.start = '%02d:%02d' | format(((nw[0] - lead) // 60) | int, ((nw[0] - lead) % 60) | int) %}
      {%- set latched = prev.get('reason') == 'preheat' and prev.get('window') == nw[0] %}
      {%- if latched or m >= nw[0] - lead %}
        {%- set p.target = nw[2] %}
        {%- set p.reason = 'preheat' %}
        {%- set p.window = nw[0] %}
        {%- set p.minutes = nw[0] - m %}
        {%- set p.since = prev.get('since') if latched else n.timestamp() %}
        {%- set p.from_temp = prev.get('from_temp') if latched else temp %}
        {%- set p.assisted = (latched and prev.get('assisted', false))${assist} %}
        {%- set p.reached = (latched and prev.get('reached', false)) or (temp is not none and temp >= nw[2]) %}
      {%- endif %}
    {%- endif %}
  '';

  # Sets namespace `p` to what the zone wants now. Highest precedence first:
  # boost, away, then the schedule (with pre-heat), else base.
  plan = zone: let
    boostOn =
      if zone.boost == null
      then "false"
      else "is_state('${boostEntity zone.boost.helper}', 'on')";
    awayOn =
      if zone.presence
      then "is_state('${awayEntity}', 'on')"
      else "false";
  in ''
    {%- set n = now() %}
    {%- set m = n.hour * 60 + n.minute %}
    {%- set prev = this.attributes %}
    {%- set p = namespace(target=${num zone.base}, reason='base', window=none, minutes=none, start=none, since=none, from_temp=none, assisted=false, reached=false) %}
    {%- if ${boostOn} %}
      {%- set p.target = ${
      if zone.boost == null
      then "none"
      else num zone.boost.target
    } %}
      {%- set p.reason = 'boost' %}
    {%- elif ${awayOn} %}
      {%- set p.reason = 'away' %}
    {%- else %}
      {%- set wins = ${builtins.toJSON (windows zone.weekday)} if n.weekday() < 5 else ${builtins.toJSON (windows zone.weekend)} %}
      {%- for w in wins if w[0] <= m < w[1] %}
        {%- set p.target = w[2] %}
        {%- set p.reason = 'schedule' %}
      {%- endfor %}
    ${lib.optionalString (zone.rate != null) (preheat zone)}
    {%- endif %}
  '';
}
