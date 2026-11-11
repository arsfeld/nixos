# PIA control plane in Rust

Date: 2026-11-11
Host: galactica
Module: `modules/hosts/galactica/services/pia.nix`

## Goal

Replace the two inline Python programs in `pia.nix` (the `pia` script with its
`connect` and `portforward` subcommands, and the `pia-watchdog` script) with one
Rust binary, `packages/pia`, as a **straight port**. Its value is a typed,
host-tested control plane and the removal of curl, not new behaviour.

Unchanged by this work:

- The four systemd units and two timers: `pia-connect`, `pia-portforward`,
  `pia-portforward-refresh` (+ timer), `pia-watchdog` (+ timer), their ordering,
  `partOf`/`requisite`/`requiredBy` wiring and `startLimitIntervalSec = 0`.
- The file contract: `/var/lib/pia/state.json` (0600, same field names),
  `/run/pia/wg0.conf` (0600), `/run/pia/forwarded-port` (0644, bare port plus
  newline), `/run/pia` 0755, `/var/lib/pia` 0700.
- The `constellation.pia` options, `vpnNamespaces.pia`, and the consumer hook
  (`onPortChange` is arbitrary shell, so the hook stays a `writeShellScript`).
- `transmission-vpn.nix` needs no change.

Out of scope, deliberately: a long-running daemon in place of the oneshots and
timers, generating WireGuard keys in-process, and netlink in place of `ip`/`iptables`.

## HTTP and TLS

`reqwest` in blocking mode with `rustls-tls` and default features off.

- `token` (`www.privateinternetaccess.com`) and the v6 server list
  (`serverlist.piaservers.net`) use an ordinary client with the bundled webpki
  roots and a 30 s timeout.
- `addKey` (`:1337`), `getSignature` and `bindPort` (`:19999`) use a **pinned
  client** built per call: `tls_built_in_root_certs(false)`,
  `add_root_certificate(<pia-ca.rsa.4096.crt>)`, and `resolve(<cn>, <ip>:<port>)`.
  That is curl's `--connect-to <cn>::<ip>:` plus `--cacert`: the connection goes to
  the IP while SNI and certificate validation use the server's CN, and no system
  root is trusted. `getSignature` and `bindPort` keep curl's `-m 10` as a 10 s
  timeout; `addKey` gets 30 s.

Evidence that rustls accepts PIA's certificates, gathered 2026-11-11 against
`montreal421` (140.228.21.113:1337, region `ca`): the leaf carries
`subjectAltName = DNS:montreal421`, is RSA-4096 signed sha512WithRSAEncryption,
the server negotiates TLS 1.3, the CA is X.509 v3 with `CA:TRUE` (valid to
2034), and `openssl s_client -verify_hostname montreal421` against the pinned CA
reports `Verification: OK`. Open question: the SAN is a single DNS label with no
dot, which webpki's name handling has to accept. The first implementation task
settles it with a live handshake; if it fails, stop and switch to `native-tls`
(same reqwest shape, OpenSSL verification identical to today's curl).

The `token` request is a multipart form (`--form username=… --form password=…`),
the others are GETs with URL-encoded query parameters (`-G --data-urlencode`).
Redirects are followed, as with `-L`. A non-2xx status is an error, as with `-f`.

## Crate layout

`packages/pia/package.nix`, `rustPlatform.buildRustPackage` with
`lib.fileset.toSource` over `Cargo.toml`, `Cargo.lock`, `src`, `tests`, in the
same shape as `packages/plab`. `cargo test` runs in `checkPhase`, so a failing
test fails galactica's build. `meta.mainProgram = "pia"`.

Dependencies: `reqwest` (`blocking`, `json`, `multipart`, `rustls-tls`),
`serde`/`serde_json`, `base64`, `chrono` (RFC 3339 parse of `expires_at`),
`anyhow`, `clap` (derive). Dev: `tempfile`. No tokio.

| Module | Responsibility |
|---|---|
| `config.rs` | One `Config` struct read from the environment the unit sets: `PIA_CREDENTIALS`, `PIA_REGION`, `PIA_CA_CERT`, `PIA_NAMESPACE`, `PIA_HOOK`, `PIA_WG`, `PIA_IP`, `PIA_IPTABLES`, `PIA_SYSTEMCTL`. A missing variable is an error naming it. File paths (`state.json`, `wg0.conf`, port file) are constants matching `pia.nix`. The tunnel interface is `<namespace>0`. |
| `creds.rs` | Parse the credentials env file: blank lines and `#` comments skipped, optional `export `, values stripped of surrounding `"`/`'`. Returns `PIA_USER` and `PIA_PASS`, and errors naming whichever is missing. |
| `api.rs` | The PIA client: `token`, `server_list` (first line of the v6 response is JSON; the rest is the signature), `add_key`, `get_signature`, `bind_port`. Typed serde response structs; a body whose `status` is not `"OK"` is an error carrying PIA's status. |
| `state.rs` | `State` with optional fields `token`, `pf_gateway`, `pf_hostname`, `dns_servers`, `payload`, `signature`, `expires_at`, `port`, `applied_port`. Unknown fields are kept (`#[serde(flatten)]` into a map) so a newer or older file round-trips. Missing file reads as empty. Atomic write: `<path>.tmp`, chmod, rename. |
| `connect.rs` | Load creds, ensure the two directories and their modes, token, server list, `select_region(regions, region)` (`auto` = first with `port_forward`; otherwise exact `id`; either way it errors if the region lacks port forwarding), first `servers.wg` entry, `wg genkey` / `wg pubkey`, `addKey`, `render_wg_conf(...)`, write `wg0.conf` 0600, merge `token`/`pf_gateway`/`pf_hostname`/`dns_servers` into the existing state, preserving payload, signature and port. |
| `portforward.rs` | Error if state is empty. `ip route replace <gateway>/32 dev <if>` and the same for each DNS server. `needs_signature(state, now)`: true unless payload, signature and `expires_at` exist and expiry is more than 86 400 s away; an unparseable `expires_at` counts as expired. `decode_payload` (base64 JSON with `port` and `expires_at`). `bindPort`. Write state and the port file. `iptables -C … || -A …` for tcp and udp on every run. If `applied_port != port`: delete the old rules (failures ignored), run `PIA_HOOK <port>` (failure fails the unit), then record `applied_port`. |
| `watchdog.rs` | `systemctl is-active --quiet <ns>.service`; if inactive, restart. Otherwise `systemctl show -P ActiveEnterTimestamp --timestamp=unix`; inside a 300 s grace, exit. Otherwise `ip netns exec <ns> wg show <ns>0 latest-handshakes`; `latest_handshake(output)` takes the max second column (0 if none); restart when `now - last >= 300`. |
| `main.rs` | clap: `pia connect`, `pia portforward`, `pia watchdog`. Errors print as `pia: <context>: <cause>` (the watchdog keeps its `pia-watchdog:` prefix) and exit 1. |

`ip`, `iptables`, `wg` and `systemctl` stay subprocesses, invoked by the absolute
paths from the environment.

## `pia.nix` after the change

- Both Python blocks are deleted.
- One `piaEnv` attrset holds the variables above (`PIA_CA_CERT = "${caCert}"`,
  `PIA_HOOK = "${hookScript}"`, tool paths from `pkgs`), set as `environment` on
  `pia-connect`, `pia-portforward`, `pia-portforward-refresh` and `pia-watchdog`.
- `ExecStart = "${pkgs.pia}/bin/pia <connect|portforward|watchdog>"`.
- The header comment keeps the architecture sketch, drops the "build-verified
  only" note, and names `packages/pia` as where the logic lives.

## Errors and logging

- Same exit semantics as today: any failure exits 1. A failed `connect` keeps
  `pia.service` down; a failed `portforward` is retried by the refresh timer or
  the next activation.
- One deliberate change: the token and server-list requests time out after 30 s
  (curl had none, so a hung PIA API could hang `pia-connect` indefinitely).
- Never logged: the password, token, payload, signature, private key. A failed
  call logs the endpoint name, HTTP status or transport error, and PIA's
  `status` field, never the request URL with its query string.
- The informational lines stay as they are (`requesting auth token`,
  `selected region …`, `binding port N`, `port unchanged (N); rebind kept alive`,
  `forwarded port changed A -> B; dispatching consumers`).

## Testing

Unit tests, run by `cargo test` in the package build:

- `creds`: export prefix, both quote styles, comments, each missing key.
- `select_region`: `auto`, exact id, unknown id, region without port forwarding.
- `server_list` parsing of a fixture with the trailing signature line.
- `render_wg_conf`: exact text against today's output, including an empty DNS list.
- `State`: round-trip with unknown fields, the connect merge preserving PF fields, atomic write mode.
- `needs_signature`: missing fields, expiry within a day, beyond a day, unparseable timestamp, `Z` suffix.
- `decode_payload` on a constructed payload.
- `latest_handshake`: multiple peers, empty output, zero handshake.
- Response structs against fixtures in `tests/fixtures/` (`addKey`, `getSignature`, `bindPort`, a non-OK status).

Live probe: an `#[ignore]`d test that builds the pinned client for a server from the
live list and requests `https://<cn>:1337/addKey` with no parameters. Success
means any HTTP response; a TLS or certificate error fails it. Run by hand with
`cargo test -- --ignored`. It is the first implementation task, because the
choice of rustls depends on it.

## Rollout and verification

1. `nix build .#nixosConfigurations.galactica.config.system.build.toplevel`.
2. `just deploy galactica`.
3. `systemctl restart pia.service` on galactica, so `pia-connect` and
   `pia-portforward` run the new binary against the existing `state.json`.
4. Check: `/run/pia/forwarded-port` holds the same port as before; the journal
   shows `port unchanged`; Transmission reports the peer port open; the next
   `pia-portforward-refresh` run succeeds; `systemctl start pia-watchdog` exits
   cleanly with no restart on a healthy tunnel.
5. Rollback is a `git revert` and a deploy; the state file format is unchanged.
