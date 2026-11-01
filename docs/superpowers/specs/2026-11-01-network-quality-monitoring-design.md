# Network quality monitoring in Home Assistant

## Goal

Keep a history of three things and graph them:

1. **Mesh quality**: latency from galactica to raider. The two machines talk
   through the TP-Link Deco mesh, so this number shows how the Wi-Fi mesh is
   doing.
2. **Internet latency**: from galactica, which is wired to the main Deco, which
   is on fiber.
3. **Internet throughput**: download, upload and ping from galactica.

The goal is history and graphs: trends over days and weeks. Alerting and
minute-by-minute diagnostics are out of scope.

## Context

- Home Assistant runs natively on galactica
  (`modules/hosts/galactica/services/home-assistant.nix`). It already ships the
  `ping` component, and the `tplink_deco` custom component exposes the Deco
  nodes and clients.
- The router host's VictoriaMetrics, Grafana and speedtest-exporter stack is
  not running. The Deco is the router now, so that stack is not revived.
- basestar's public IP does not answer ICMP echo. The OCI security list allows
  only ICMP type 3. basestar is therefore pinged over Tailscale.

## Design

### Nix: `home-assistant.nix`

- Add `"speedtestdotnet"` to `extraComponents`.
- Add an automation under the key `"automation network"`, following the keyed
  pattern the heating module uses. Every 4 hours (`time_pattern`,
  `hours: "/4"`) it calls `homeassistant.update_entity` on
  `sensor.speedtest_download`. Updating one entity refreshes the integration's
  coordinator, which updates download, upload and ping together. A comment
  states that this entity ID comes from the UI-created entry, so renaming that
  entry breaks the schedule.
- A comment block lists the one-time UI setup below, the way `beszel.nix`
  documents its OIDC step.

No new service, firewall rule, or infra change.

### One-time UI setup

Both integrations can only be set up through the UI (config flow), not YAML.

| Integration   | Host                      | Measures                               |
|---------------|---------------------------|----------------------------------------|
| Ping          | `raider.local`            | Mesh latency over the LAN, not Tailscale |
| Ping          | `basestar.bat-boa.ts.net` | Internet path to a host we own         |
| Ping          | `1.1.1.1`                 | Neutral internet reference             |
| Speedtest.net | (auto server)             | Download, upload, ping                 |

- `raider.local` resolves to raider's LAN address through avahi with
  `nssmdns4`, which the `base` feature enables on every host. Pinging the
  Tailscale name instead would measure the tunnel, not the mesh.
- Each Ping entry uses a count of 5.
- On the Speedtest.net entry, turn off "Enable polling for updates" in its
  system options, so only the 4-hour automation runs tests. Its default is
  hourly, about 24 full-bandwidth tests a day.

### Data and display

- Each ping target produces round-trip average, min, max and mdev (jitter)
  sensors, polled about every 30s.
- Speedtest produces download, upload and ping sensors.
- All of these have `state_class: measurement`, so the recorder keeps
  long-term hourly mean, min and max statistics beyond the raw history window.
  No recorder change is needed.
- One dashboard view, built in the UI because dashboards here are UI-managed:
  - a history graph of the three latencies
  - a statistics graph of download and upload
  - the Deco node entities for context

## Reading the data and its edge cases

- **raider asleep or off**: its ping entity goes unavailable. That is a gap in
  the graph, not bad latency.
- **Tailscale relayed through DERP**: basestar's latency rises while
  `1.1.1.1` stays flat. The neutral reference exists to tell this apart from a
  fiber problem.
- **Speed test running**: it can briefly raise the other latency readings. At
  one test every 4 hours that is rare. Remember it when you see an isolated
  spike.

## Testing

1. `just build galactica`.
2. Deploy galactica.
3. Add the three Ping entries and the Speedtest.net entry. Turn off its
   polling.
4. Run the `network` automation by hand. Check that the download, upload and
   ping sensors update, and that all three ping targets report values.
5. After a day, check that the statistics graph shows hourly points.
