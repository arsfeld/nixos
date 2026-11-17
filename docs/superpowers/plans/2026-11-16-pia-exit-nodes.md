# PIA Exit Slots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two Tailscale exit-node slots on galactica, each a PIA WireGuard tunnel whose country is picked from a Home Assistant dropdown, with HA showing whether each slot works.

**Architecture:** `packages/pia` gains per-instance paths, a region file, optional port forwarding, and `pia exits serve|node`: a loopback HTTP control service and the per-slot Tailscale login. On the nix side, the tunnel half of `pia.nix` becomes a helper (`_pia/tunnel.nix`) shared by Transmission's namespace and a new `pia-exits.nix`, which builds per-slot VPN-Confinement namespaces, a confined userspace tailscaled each, the control service, and the HA entities.

**Tech Stack:** Rust (`packages/pia`: reqwest blocking, serde, clap, new `tiny_http`), NixOS modules (VPN-Confinement, systemd), Home Assistant YAML via `services.home-assistant.config`.

**Spec:** `docs/superpowers/specs/2026-11-16-pia-exit-nodes-design.md`

## Global Constraints

- Commit straight to master; never branch. Conventional commits with scope `galactica` (for `packages/pia` as well); never mention Claude.
- New files must be `git add`ed (or `git add -N`) before any `nix build` sees them.
- Rust tests: `cd packages/pia && cargo test`. Package build (runs the tests): `nix build .#pia`.
- Host build: `nix build .#nixosConfigurations.galactica.config.system.build.toplevel`, one host at a time, never in parallel with another eval.
- Slot count: `constellation.piaExits.slots`, default 2, asserted `1 <= slots <= 9`.
- Per slot `n`: namespace `piax<n>`, WireGuard interface `piax<n>0`, namespace address `192.168.(100+n).1`, bridge `192.168.(100+n).5`, target `pia-exit-<n>.target`, tailscaled port `41641+n`, tailscaled state `/var/lib/tailscale-piax<n>`, socket `/run/tailscale-piax<n>/tailscaled.sock`, PIA run dir `/run/pia-x<n>`, PIA state dir `/var/lib/pia-x<n>`, region file `/var/lib/pia-exits/slot-<n>`.
- Units per slot: `piax<n>.service` (namespace), `pia-connect-x<n>`, `pia-watchdog-x<n>` (+ timer), `tailscaled-piax<n>`, `tailscale-piax<n>-up`. All `partOf` and wanted by `pia-exit-<n>.target`; nothing wants the target.
- Control service: `pia-exits.service`, `127.0.0.1:8592`, root, `Restart=always`.
- Tailscale node hostname: `pia-<region id>` with every character outside `[a-z0-9-]` mapped to `-` (`us_new_york_city` → `pia-us-new-york-city`).
- Tailscale login: OAuth `tailscale-key` (common sops file) + `?ephemeral=false&preauthorized=true`, `--advertise-tags=tag:service`, `--advertise-exit-node`; the key goes through a 0600 file, never argv.
- `state` values: `off`, `starting` (region file mtime < 120 s ago and not up), `up` (handshake < 300 s, tailscale running and approved, egress country == region country), `degraded`, `down`.
- Refresh: status every 30 s, egress every 300 s and right after a change; region list at start and every 6 h.
- Transmission's `pia` namespace: unit files for `pia.service`, `pia-connect`, `pia-portforward`, `pia-portforward-refresh`, `pia-watchdog` and their timers must be identical before and after the refactor.
- Language order: Rust, then Python, shell only when required. No new shell scripts.

## Review Focus

1. **Region ids that are not DNS-safe** (`us_new_york_city`, uppercase): the node hostname must still be valid. Test in Task 5.
2. **A slot's current region disappears from PIA's list** (retired or offline): the dropdown must still show it as the current option, and selecting a label not offered gives 400 rather than a crash. Test in Task 2 and Task 4.
3. **Changing country while a slot is still `starting`**: a second POST must restart cleanly and the 120 s `starting` window restarts from the new choice (region-file mtime). Test in Task 3.
4. **Region files for slots above `slots`** after lowering the count: ignored, never started. Test in Task 3.
5. **ipinfo answering garbage, a rate-limit page, or nothing**: the slot reads `degraded`, the service keeps running. Test in Task 4.

---

### Task 1: `pia` per-instance paths, region file, optional port forwarding

**Files:**
- Modify: `packages/pia/src/config.rs`, `packages/pia/src/connect.rs`, `packages/pia/src/portforward.rs`

**Interfaces:**
- Produces: `Config` fields `run_dir: PathBuf`, `state_dir: PathBuf`, `region: String` (resolved from `PIA_REGION` or the trimmed contents of `PIA_REGION_FILE`), `port_forward: bool`, `hook: Option<PathBuf>`, `iptables: Option<PathBuf>`; methods `wg_conf_path()`, `port_file_path()`, `state_path()` (all `-> PathBuf`, under `run_dir`/`state_dir` with today's file names). The `*_PATH`/`*_DIR` constants are removed; defaults `/run/pia` and `/var/lib/pia`.
- Produces: `select_region(regions, want, port_forward: bool)`.

- [ ] **Step 1: Write failing tests in `config.rs`**

```rust
#[test] fn default_paths_unchanged() // no PIA_RUN_DIR/PIA_STATE_DIR: wg_conf_path()=="/run/pia/wg0.conf", port_file_path()=="/run/pia/forwarded-port", state_path()=="/var/lib/pia/state.json", port_forward==true
#[test] fn custom_dirs_honoured() // PIA_RUN_DIR=/run/pia-x1, PIA_STATE_DIR=/var/lib/pia-x1 -> "/run/pia-x1/wg0.conf", "/var/lib/pia-x1/state.json"
#[test] fn region_from_file() // PIA_REGION unset, PIA_REGION_FILE -> tempfile containing "br-so\n": region=="br-so"
#[test] fn region_both_or_neither_is_error() // both set -> Err; neither -> Err naming PIA_REGION
#[test] fn hook_optional_without_port_forward() // PIA_PORT_FORWARD=0, no PIA_HOOK/PIA_IPTABLES -> Ok, hook==None
#[test] fn hook_required_with_port_forward() // PIA_PORT_FORWARD unset, no PIA_HOOK -> Err naming PIA_HOOK
```

Update the existing `ALL`/`lookup_without` helpers so the existing two tests still pass.

- [ ] **Step 2: Write failing tests in `connect.rs`**

```rust
#[test] fn region_without_pf_accepted_when_pf_off() // select_region(&r, "<non-pf id>", false).is_ok()
#[test] fn region_without_pf_rejected_when_pf_on()  // existing message "does not support port forwarding"
```

Existing `select_region` calls in tests gain `true`.

- [ ] **Step 3: Run `cd packages/pia && cargo test`** — expect compile errors / failures for the new tests.

- [ ] **Step 4: Implement.** `Config::from_lookup` reads `PIA_RUN_DIR`, `PIA_STATE_DIR` (defaults), `PIA_PORT_FORWARD` (`"0"` → false, unset or `"1"` → true, else error), and the region rule; `PIA_REGION_FILE` is read at config time with `std::fs::read_to_string` and trimmed (empty → error). `connect::run` and `portforward::run` use the path methods; `ensure_dir(run_dir, 0o755)` and `ensure_dir(state_dir, 0o700)` as today. `portforward` errors early if `hook`/`iptables` is `None` (it is never run with PF off).

- [ ] **Step 5: Run `cargo test`** — all pass.

- [ ] **Step 6: Commit**

```bash
git add packages/pia/src
git commit -m "feat(galactica): pia takes per-instance paths, a region file, and optional port forwarding"
```

---

### Task 2: Offered regions and their labels

**Files:**
- Modify: `packages/pia/src/api.rs` (Region fields), `packages/pia/src/lib.rs` (`pub mod exits;`)
- Create: `packages/pia/src/exits/mod.rs` (module declarations only for now), `packages/pia/src/exits/regions.rs`

**Interfaces:**
- Produces: `api::Region` gains `#[serde(default)] name: String, country: String, geo: bool, offline: bool`.
- Produces: `pub struct Offered { pub label: String, pub id: String, pub country: String }` and `pub fn offered(regions: &[Region]) -> Vec<Offered>` — regions not offline with ≥1 WireGuard server; label = `name`, plus `" (virtual)"` when `geo`; sorted by label; on a duplicate label, every duplicate gets `" (<id>)"` appended.
- Produces: `pub fn options(offered: &[Offered], in_use: &[&str]) -> Vec<String>` — `"Off"` first, then offered labels, then for each in-use id not offered, its id as its own label.
- Produces: `pub fn id_for(offered: &[Offered], label: &str) -> Option<&Offered>`.

- [ ] **Step 1: Write failing tests in `regions.rs`** using `api::parse_server_list(include_str!("../../tests/fixtures/servers-v6.txt"))` plus small hand-built regions:

```rust
#[test] fn offline_and_serverless_regions_dropped()
#[test] fn geo_regions_marked_virtual()        // label ends with " (virtual)"
#[test] fn labels_sorted()
#[test] fn duplicate_labels_get_ids()          // two "Same" -> "Same (a)", "Same (b)"
#[test] fn options_start_with_off()            // options(&o, &[])[0] == "Off"
#[test] fn in_use_region_missing_from_list_still_offered() // options(&o, &["gone"]) contains "gone"
#[test] fn id_for_unknown_label_is_none()
```

If the fixture lacks `name`/`country`/`geo`/`offline` (it was trimmed for the old struct), extend it with real entries from `https://serverlist.piaservers.net/vpninfo/servers/v6` (first line only), including `br-so` and one `geo: true` region.

- [ ] **Step 2: Run `cargo test exits::regions`** — fails.
- [ ] **Step 3: Implement** the three functions.
- [ ] **Step 4: Run `cargo test`** — all pass.
- [ ] **Step 5: Commit** `feat(galactica): pia lists offered exit regions with readable labels`

---

### Task 3: Slots: region files and choices

**Files:**
- Create: `packages/pia/src/exits/slots.rs`

**Interfaces:**
- Consumes: `regions::{Offered, id_for}`.
- Produces:
  - `pub fn read_region(path: &Path) -> Option<(String, SystemTime)>` — trimmed id and mtime; absent or empty → `None`.
  - `pub enum Action { Start, Restart, Stop }` (`Debug, PartialEq`).
  - `pub enum ChoiceError { UnknownSlot, UnknownOption, BadBody, Conflict }` (→ 404, 400, 400, 409).
  - `pub fn choose(slot: u8, slots: u8, body: &str, offered: &[Offered], current: &[Option<String>]) -> Result<(Option<String>, Action), ChoiceError>` — `body` is `{"option": "<label>"}`; `current[i]` is slot `i+1`'s region. Returns the new region (`None` for Off) and the action: Off → `Stop`; a region while the slot is Off → `Start`; a region while on (same or different) → `Restart`. Another slot already holding that region → `Conflict`.
  - `pub fn apply_region(path: &Path, region: Option<&str>) -> Result<()>` — atomic write (`state::write_atomic`, 0o644) or remove; removing an absent file is Ok. Writing always refreshes the mtime, even for the same id.
  - `pub fn slots_to_start(slots: u8, dir_files: &[Option<String>]) -> Vec<u8>` — 1-based slots ≤ `slots` with a region.

- [ ] **Step 1: Write failing tests**

```rust
#[test] fn off_stops()                        // ("Off") -> (None, Stop)
#[test] fn region_on_off_slot_starts()
#[test] fn region_on_running_slot_restarts()  // also for the same region again (re-select = retry)
#[test] fn same_region_in_other_slot_conflicts()
#[test] fn unknown_label_is_unknown_option()
#[test] fn slot_zero_and_above_count_unknown()
#[test] fn malformed_body_is_bad_body()       // "", "{}", "{\"option\":3}"
#[test] fn apply_region_writes_and_removes()  // tempdir; read_region round-trips; Off removes; Off twice is Ok
#[test] fn rewrite_same_region_bumps_mtime()  // apply "br", then apply "br" again: read_region's mtime >= the SystemTime::now() taken just before the second apply
#[test] fn files_above_slot_count_ignored()   // slots_to_start(2, [Some, None, Some]) == [1]
```

- [ ] **Step 2: Run** — fails. **Step 3: Implement.** **Step 4: Run `cargo test`** — pass.
- [ ] **Step 5: Commit** `feat(galactica): pia exit slots keep their region in a file per slot`

---

### Task 4: Slot status

**Files:**
- Create: `packages/pia/src/exits/status.rs`

**Interfaces:**
- Consumes: `watchdog::latest_handshake`.
- Produces:
  - `pub struct Tailscale { pub running: bool, pub online: bool, pub approved: bool, pub hostname: String }` and `pub fn parse_tailscale(json: &str) -> Tailscale` — `BackendState == "Running"`, `Self.Online`, `"0.0.0.0/0"` in `Self.AllowedIPs`, `Self.HostName`; unparsable → all false, empty hostname.
  - `pub struct Egress { pub ip: String, pub country: String }` and `pub fn parse_egress(json: &str) -> Option<Egress>` — ipinfo's `ip` and `country`; anything else → `None`.
  - `#[derive(Serialize, Clone, Copy, PartialEq, Debug)] #[serde(rename_all = "lowercase")] pub enum State { Off, Starting, Up, Degraded, Down }`.
  - `pub struct Inputs { pub region: Option<String>, pub country: Option<String>, pub chosen_secs_ago: u64, pub target_active: bool, pub handshake_age_s: Option<i64>, pub tailscale: Tailscale, pub egress: Option<Egress> }`.
  - `pub fn derive(i: &Inputs) -> State` — rules from Global Constraints; `down` = region set and target inactive; `starting` beats `degraded` only within 120 s.
  - `#[derive(Serialize)] pub struct SlotStatus` with exactly the spec's JSON fields: `slot, option, region, country, state, handshake_age_s, tailscale ("running"|"stopped"|"unapproved"|"offline"), hostname, egress_ip, egress_country, egress_checked` (RFC 3339 or null).

- [ ] **Step 1: Write failing tests**

```rust
#[test] fn off_without_region()
#[test] fn up_when_all_checks_pass()           // handshake 41, running+online+approved, egress BR == country BR
#[test] fn starting_within_two_minutes()       // chosen 30 s ago, no handshake
#[test] fn degraded_after_two_minutes()        // chosen 300 s ago, handshake 400
#[test] fn degraded_on_wrong_country()
#[test] fn degraded_when_unapproved()
#[test] fn degraded_without_egress()           // egress None
#[test] fn down_when_target_inactive()
#[test] fn tailscale_json_parsed()             // minimal real-shaped JSON with AllowedIPs ["100.x/32","0.0.0.0/0","::/0"]
#[test] fn tailscale_garbage_is_all_false()
#[test] fn egress_parsed() / egress_rate_limit_page_is_none() // "<html>…" and {"error":…}
```

- [ ] **Step 2: Run** — fails. **Step 3: Implement.** **Step 4: Run** — pass.
- [ ] **Step 5: Commit** `feat(galactica): pia derives whether each exit slot is working`

---

### Task 5: `pia exits serve` and `pia exits node`

**Files:**
- Modify: `packages/pia/Cargo.toml`, `Cargo.lock` (add `tiny_http`), `packages/pia/src/main.rs`, `packages/pia/src/exits/mod.rs`
- Create: `packages/pia/src/exits/config.rs`, `packages/pia/src/exits/http.rs`, `packages/pia/src/exits/node.rs`

**Interfaces:**
- Consumes: Tasks 2–4; `api::server_list`, `cmd::{stdout, succeeds}`.
- Produces:
  - `exits::config::ExitsConfig` (serde, from the JSON file named by `PIA_EXITS_CONFIG`): `listen: String`, `ip, wg, systemctl, tailscale, curl: PathBuf`, `oauth_key: PathBuf`, `slots: Vec<SlotConfig>`; `SlotConfig { slot: u8, namespace: String, interface: String, target: String, socket: PathBuf, region_file: PathBuf, port: u16 }`. Task 7 renders exactly this shape.
  - `exits::http::handle(method: &str, path: &str, body: &str, snap: &Snapshot) -> Response` where `Response { code: u16, body: String, change: Option<(u8, Option<String>, Action)> }` and `Snapshot { options: Vec<String>, offered: Vec<Offered>, slots: Vec<SlotStatus>, current: Vec<Option<String>> }`. Routes: `GET /status` → `{"options","active","slots"}`; `POST /slots/<n>` → `slots::choose`; anything else 404; wrong method 405.
  - `exits::node::hostname(region: &str) -> String` and `exits::node::run(cfg: &ExitsConfig, slot: u8) -> Result<()>`: if `tailscale status --json` says `NeedsLogin`, write `<key>?ephemeral=false&preauthorized=true` to `$RUNTIME_DIRECTORY/authkey` (0600) and `tailscale up --auth-key=file:… --hostname=… --advertise-exit-node --advertise-tags=tag:service`; then always `tailscale set --advertise-exit-node --hostname=…`. With no region file, exit 0 without changes.
  - `exits::run(cfg: &ExitsConfig) -> Result<()>`: at start apply `slots_to_start` (start those targets, stop the rest), then one refresher thread (status 30 s, egress 300 s per slot via `ip netns exec <ns> <curl> -s --max-time 10 https://ipinfo.io/json`, region list 6 h, keeping the last good list) sharing `Arc<Mutex<Snapshot>>` with the `tiny_http` loop on `listen`. A change from `handle` is applied with `slots::apply_region` then `systemctl start|restart|stop --no-block <target>`, and wakes the refresher (channel) so egress is re-checked at once.
  - CLI: `pia exits serve`, `pia exits node <slot>`. These read only `PIA_EXITS_CONFIG`; `connect|portforward|watchdog` keep using `Config::from_env`.

- [ ] **Step 1: Write failing tests**

```rust
// node.rs
#[test] fn hostname_sanitised()      // "br-so"->"pia-br-so", "us_new_york_city"->"pia-us-new-york-city", "CA"->"pia-ca"
// http.rs
#[test] fn status_shape()            // keys options, active, slots; active counts state != off
#[test] fn post_returns_change()     // POST /slots/1 {"option":"Brazil"} -> 200, change == Some((1, Some("br"), Start))
#[test] fn post_conflict_409()
#[test] fn post_unknown_label_400()
#[test] fn unknown_path_404() / get_on_slot_405()
// config.rs
#[test] fn config_round_trips()      // sample JSON with two slots parses; slot 2 namespace "piax2"
```

- [ ] **Step 2: Run** — fails.
- [ ] **Step 3: Add `tiny_http`** (`cargo add tiny_http` in `packages/pia`), implement, wire clap subcommands (`Exits { #[command(subcommand)] cmd: ExitsCmd }`, `ExitsCmd::{Serve, Node { slot: u8 }}`).
- [ ] **Step 4: Run `cargo test` then `nix build .#pia`** — both pass (the nix build proves `Cargo.lock` is complete).
- [ ] **Step 5: Smoke-run locally** without root: write a temp config with one slot pointing at nonexistent sockets, `PIA_EXITS_CONFIG=… cargo run -- exits serve` with `systemctl` set to `/run/current-system/sw/bin/true`, then `curl -s 127.0.0.1:8592/status | jq .` — expect `options[0]=="Off"`, slot 1 `state=="off"`. Stop it.
- [ ] **Step 6: Commit** `feat(galactica): pia exits serve controls exit slots over loopback HTTP`

---

### Task 6: Shared tunnel helper; Transmission's namespace unchanged

**Files:**
- Create: `modules/hosts/galactica/services/_pia/tunnel.nix`
- Modify: `modules/hosts/galactica/services/pia.nix`

**Interfaces:**
- Produces: `import ./_pia/tunnel.nix {inherit lib pkgs;}` returns `mkPiaTunnel` taking `{namespace, connectUnit, watchdogUnit, namespaceAddress, bridgeAddress, env, allowedIngress ? [], portMappings ? [], target ? null}` where `env` is the full `PIA_*` attrset (Task 1 variables). Returns a NixOS config fragment: `vpnNamespaces.<namespace>`, `systemd.services.<connectUnit>` (oneshot `pia connect`, `before`/`requiredBy`/`partOf` the namespace unit, `StateDirectory` derived from `PIA_STATE_DIR`'s basename), `systemd.services.<watchdogUnit>` + timer (`OnBootSec=5min`, `OnUnitActiveSec=2min`). With `target != null`: the namespace unit's `wantedBy` is `mkForce [target]`, every unit gets `partOf = [target]`, and the timer is `wantedBy = [target]` instead of `timers.target`.

- [ ] **Step 1: Record the baseline.** Before editing, for each of `pia.service pia-connect.service pia-portforward.service pia-portforward-refresh.service pia-watchdog.service pia-watchdog.timer pia-portforward-refresh.timer`:

```bash
nix eval --raw .#nixosConfigurations.galactica.config.systemd.units.\"<unit>\".unit > /tmp/…/scratchpad/before-<unit>
```

(one eval at a time; use the session scratchpad).

- [ ] **Step 2: Write `tunnel.nix`** and rewrite `pia.nix` to use it for the `pia` instance (`connectUnit = "pia-connect"`, `watchdogUnit = "pia-watchdog"`, `target = null`), keeping its options, port forwarding units and consumers. Keep the long comments that explain why (partOf on connect, the watchdog history) with the code they explain, in the helper.
- [ ] **Step 3: `git add -N` the new file; repeat Step 1's evals into `after-<unit>`**, then `diff` each pair. Expected: no differences. The `pia` env gains `PIA_RUN_DIR`/`PIA_STATE_DIR`/`PIA_PORT_FORWARD` only if you pass them; don't pass them for this instance, the defaults hold.
- [ ] **Step 4: `just fmt`; build galactica's toplevel** — succeeds.
- [ ] **Step 5: Commit** `refactor(galactica): PIA tunnel units come from a shared helper`

---

### Task 7: Exit slots, control service and Home Assistant entities

**Files:**
- Create: `modules/hosts/galactica/services/pia-exits.nix`
- Modify: `modules/hosts/galactica/configuration.nix` (`constellation.piaExits.slots = 2;` beside `constellation.pia.region`)

**Interfaces:**
- Consumes: `mkPiaTunnel` (Task 6); `pia exits serve|node` and the `ExitsConfig` JSON shape (Task 5).
- Produces: option `constellation.piaExits.slots` (int, default 2, assertion 1..9); per slot all units from Global Constraints; `systemd.targets."pia-exit-<n>"` (no `wantedBy`); `pia-exits.service` (`wantedBy multi-user.target`, `after network-online.target`, `StateDirectory = "pia-exits"`, `Restart=always`, env `PIA_EXITS_CONFIG` = `pkgs.writeText` of the JSON); HA config.

- [ ] **Step 1: Write the module.** Per slot `n`:
  - `mkPiaTunnel` with `namespace = "piax${n}"`, `connectUnit = "pia-connect-x${n}"`, `watchdogUnit = "pia-watchdog-x${n}"`, `target = "pia-exit-${n}.target"`, env with `PIA_REGION_FILE`, `PIA_RUN_DIR=/run/pia-x${n}`, `PIA_STATE_DIR=/var/lib/pia-x${n}`, `PIA_PORT_FORWARD=0`, and the shared `PIA_CREDENTIALS`/`PIA_CA_CERT`/tool paths (take them from `pia.nix`'s `piaEnv` minus hook/iptables: expose that base env from `pia.nix` as a read-only internal option `constellation.pia.baseEnv` so it is not restated).
  - `tailscaled-piax${n}`: `vpnConfinement = {enable = true; vpnNamespace = "piax${n}";}`, `partOf` the namespace unit and the target, `ExecStart = tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale-piax${n} --socket=/run/tailscale-piax${n}/tailscaled.sock --port=${41641+n}`, `StateDirectory`, `RuntimeDirectory`, `Restart=on-failure`.
  - `tailscale-piax${n}-up`: oneshot, `after`/`requires` tailscaled, `partOf` target, `RuntimeDirectory`, `ExecStart = pia exits node ${n}` (root, so it reads the secret directly). `oauth_key` in the JSON is `config.sops.secrets.tailscale-key.path`; galactica's `misc.nix` already declares that secret, so don't redeclare it.
  - HA (`services.home-assistant.config`):
    - `rest = [{ resource = "http://127.0.0.1:8592/status"; scan_interval = 30; sensor = [ {name="PIA exits"; unique_id="pia_exits"; value_template="{{ value_json.active }}"; json_attributes=["options" "slots"];} ] ++ per-slot sensors (state, ip, country, node: `value_template = "{{ value_json.slots[${n-1}].<field> }}"`); binary_sensor = per-slot working (`{{ value_json.slots[${n-1}].state == 'up' }}`);}]`
    - `rest_command.pia_exit_set = { url = "http://127.0.0.1:8592/slots/{{ slot }}"; method = "post"; content_type = "application/json"; payload = "{\"option\": \"{{ option }}\"}"; }`
    - `template = [{ select = per slot { name = "PIA exit ${n}"; unique_id = "pia_exit_${n}"; options = "{{ state_attr('sensor.pia_exits','options') or ['Off'] }}"; state = "{{ (state_attr('sensor.pia_exits','slots') or [{}])[${n-1}].option or 'Off' }}"; select_option = [{action="rest_command.pia_exit_set"; data={slot=n; option="{{ option }}";};} {action="homeassistant.update_entity"; target.entity_id="sensor.pia_exits";}]; }; }]`
    - `recorder.exclude.entities = ["sensor.pia_exits"]`.
- [ ] **Step 2: `git add -N`, `just fmt`, build galactica's toplevel** — succeeds.
- [ ] **Step 3: Inspect the generated pieces** (one eval each):
  - `nix eval .#nixosConfigurations.galactica.config.systemd.services.piax1.wantedBy` → `[ "pia-exit-1.target" ]`
  - `…services."tailscaled-piax2".serviceConfig.ExecStart` contains `--port=41643`
  - `…vpnNamespaces.piax2.namespaceAddress` → `"192.168.102.1"`
  - `…services.home-assistant.config.template` still contains the heating module's entries plus the two selects (list merge, not override).
  - Re-run Task 6's `pia` unit diffs — still identical.
- [ ] **Step 4: Commit** `feat(galactica): PIA exit slots chosen from Home Assistant`

---

### Task 8: Deploy, verify, document

**Files:**
- Modify: `CLAUDE.md` (new "PIA exit slots" section under galactica's PIA material), `docs/superpowers/specs/2026-11-16-pia-exit-nodes-design.md` (record the DERP/direct measurement)

- [ ] **Step 1: Ask the user to do the admin-console step** (`autoApprovers.exitNode: ["tag:service"]`; `autogroup:internet` granted) and wait for confirmation.
- [ ] **Step 2: Push, then deploy** — `git push`, then `nix develop -c just deploy galactica` from raider.
- [ ] **Step 3: Run the spec's Verification list 1–11** on galactica and blackbird; for the HA steps, use the HA UI or `hass` REST API with the user. Any failure: stop and use superpowers:systematic-debugging.
- [ ] **Step 4: Write the CLAUDE.md section** (slot model and cap, entities and `state`, a device follows its slot, admin-console step, changing the slot count, each slot not Off is a PIA connection, don't rename slot nodes in the console) and record step 11's result in the spec's Failure behaviour section.
- [ ] **Step 5: Commit and push** `docs(galactica): PIA exit slots`.
