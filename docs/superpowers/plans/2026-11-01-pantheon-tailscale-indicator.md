# Pantheon Tailscale Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native Wingpanel indicator on every Tailscale+Pantheon host (raider, blackbird) that always shows tailscaled's state and lets the desktop user switch Tailscale on/off and pick an exit node without sudo.

**Architecture:** A Vala Wingpanel plugin in `packages/wingpanel-indicator-tailscale/` talks HTTP to `/run/tailscale/tailscaled.sock` with libsoup 3: a long-lived `watch-ipn-bus` stream pushes state, `GET /status` fills the popover on open, `PATCH /prefs` writes. All JSON interpretation is in pure, unit-tested `Model.vala`. A feature module adds the plugin and `--operator=arosenfeld` (tailscaled refuses unprivileged writes with 403 otherwise).

**Tech Stack:** Vala 0.56, meson, GTK 3, Granite 6 (`pantheon.granite`), Wingpanel 8 (`pantheon.wingpanel`), libsoup 3.8, json-glib 1.10, NixOS VM tests.

Spec: `docs/superpowers/specs/2026-11-01-pantheon-tailscale-indicator-design.md`.
Reference implementation to copy patterns from: `packages/wingpanel-indicator-gamemode/`, `modules/desktop/pantheon-gamemode.nix`, `tests/pantheon-gamemode-test.nix`.

## Global Constraints

- Commit straight to `master`. No branches, no worktrees.
- Conventional commits: `<type>(<scope>): <subject>`, scope `modules` here. Never mention Claude.
- New files are invisible to `nix build` until `git add`ed (`git add -N` is enough).
- Never evaluate or build more than one host toplevel at a time; never touch `cylon-link`.
- Code name `tailscale`; log domain `io.elementary.wingpanel.tailscale`; plugin `libtailscale-indicator.so`; package attribute `wingpanel-indicator-tailscale` (auto-loaded from `packages/<name>/package.nix`).
- Socket `/run/tailscale/tailscaled.sock`; every request URL `http://local-tailscaled.sock/localapi/v0/<endpoint>` (tailscaled checks the Host header).
- IPN bus mask `22` (NotifyInitialState 2 | NotifyInitialPrefs 4 | NotifyNoPrivateKeys 16).
- Operator user is `arosenfeld` (hardcoded in `modules/base/users.nix` too).
- Log lines are `message ()` (not `info`, hidden by default) and stable: `Tailscale: <Model.describe>` and `Tailscale status: <n> exit node candidate(s)` / `Tailscale status: unavailable`. The VM test asserts on them.
- The indicator must never log at `warning` or `critical` in normal operation (tailscaled down, bad JSON, failed writes are `debug`); the VM test fails on any.
- Code style: match `packages/wingpanel-indicator-gamemode/` — block comment per file and per non-obvious method, 4-space Vala indent.

---

### Task 1: Package skeleton and the pure model

**Files:**
- Create: `packages/wingpanel-indicator-tailscale/package.nix`
- Create: `packages/wingpanel-indicator-tailscale/meson.build`
- Create: `packages/wingpanel-indicator-tailscale/src/Model.vala`
- Test: `packages/wingpanel-indicator-tailscale/tests/TestModel.vala`

**Interfaces:**
- Produces (namespace `TailscaleIndicator`):
  - `enum Backend { UNREACHABLE, NEEDS_LOGIN, STOPPED, STARTING, RUNNING; string to_label () }`
  - `class State : Object { Backend backend; bool want_running; string exit_node_id }` (properties, notify on set)
  - `class ExitNode : Object { string id; string name; bool online }` with ctor `ExitNode (string id, string name, bool online)`
  - `class Status : Object { string? ipv4 (property); string[] health; ExitNode[] exit_nodes (public fields) }`
  - `Model.backend_from_ipn (int64) : Backend`
  - `Model.apply_notify (State, Json.Object) : void`
  - `Model.parse_status (Json.Object) : Status`
  - `Model.exit_node_name (string id, ExitNode[] nodes) : string`
  - `Model.describe (State, string? exit_name) : string`
  - `Model.icon_name (State) : string`
  - `Model.status_line (State, string? ipv4) : string`
  - `Model.running_body (bool) : string`, `Model.exit_node_body (string id) : string`
  - `Model.write_error_text (uint status) : string`

- [ ] **Step 1: Write the test file**

`packages/wingpanel-indicator-tailscale/tests/TestModel.vala`:

```vala
/*
 * Unit tests for Model.vala, run by `meson test` in the package's checkPhase.
 * The JSON is shaped after tailscaled 1.104.1's replies on raider, cut down to
 * the members Model reads plus a few it must ignore.
 */
using TailscaleIndicator;

const string NOTIFY_RUNNING = """{"Version":"1.104.1","SessionID":"x","ErrMessage":null,"State":6,"Prefs":{"ControlURL":"https://controlplane.tailscale.com","WantRunning":true,"ExitNodeID":"","LoggedOut":false}}""";
const string NOTIFY_EXIT = """{"Prefs":{"WantRunning":true,"ExitNodeID":"nbaJt4JzNB21CNTRL"}}""";
const string NOTIFY_STATE_ONLY = """{"State":4}""";
const string NOTIFY_MISTYPED = """{"State":"6","Prefs":{"WantRunning":"yes","ExitNodeID":7}}""";

const string STATUS = """{
  "Version":"1.104.1","BackendState":"Running","Health":["some warning"],
  "Self":{"ID":"nSELF","HostName":"raider","TailscaleIPs":["fd7a:115c:a1e0::1a01:3e6d","100.111.62.70"],"Online":true,"ExitNodeOption":false},
  "Peer":{
    "nodekey:aa":{"ID":"nbaJt4JzNB21CNTRL","HostName":"basestar","Online":true,"ExitNode":false,"ExitNodeOption":true},
    "nodekey:bb":{"ID":"nOFF","HostName":"alpha","Online":false,"ExitNodeOption":true},
    "nodekey:cc":{"ID":"nNOPE","HostName":"galactica","Online":true,"ExitNodeOption":false},
    "nodekey:dd":{"HostName":"no-id","Online":true,"ExitNodeOption":true}
  }}""";
const string STATUS_LOGGED_OUT = """{"BackendState":"NeedsLogin","Self":null,"Peer":null,"Health":null}""";

Json.Object parse (string text) {
    var parser = new Json.Parser ();
    try {
        parser.load_from_data (text);
    } catch (Error e) {
        error ("parse: %s", e.message);
    }
    return parser.get_root ().get_object ();
}

State running (string exit_id) {
    var state = new State ();
    state.backend = Backend.RUNNING;
    state.want_running = true;
    state.exit_node_id = exit_id;
    return state;
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/model/backend-from-ipn", () => {
        assert (Model.backend_from_ipn (0) == Backend.UNREACHABLE);
        assert (Model.backend_from_ipn (1) == Backend.UNREACHABLE);
        assert (Model.backend_from_ipn (2) == Backend.NEEDS_LOGIN);
        assert (Model.backend_from_ipn (3) == Backend.NEEDS_LOGIN);
        assert (Model.backend_from_ipn (4) == Backend.STOPPED);
        assert (Model.backend_from_ipn (5) == Backend.STARTING);
        assert (Model.backend_from_ipn (6) == Backend.RUNNING);
        assert (Model.backend_from_ipn (99) == Backend.UNREACHABLE);
    });

    Test.add_func ("/model/apply-notify", () => {
        var state = new State ();
        Model.apply_notify (state, parse (NOTIFY_RUNNING));
        assert (state.backend == Backend.RUNNING);
        assert (state.want_running);
        assert_cmpstr (state.exit_node_id, CompareOperator.EQ, "");

        // Prefs without State: backend stays, exit node follows.
        Model.apply_notify (state, parse (NOTIFY_EXIT));
        assert (state.backend == Backend.RUNNING);
        assert_cmpstr (state.exit_node_id, CompareOperator.EQ, "nbaJt4JzNB21CNTRL");

        // State without Prefs: prefs stay.
        Model.apply_notify (state, parse (NOTIFY_STATE_ONLY));
        assert (state.backend == Backend.STOPPED);
        assert (state.want_running);
        assert_cmpstr (state.exit_node_id, CompareOperator.EQ, "nbaJt4JzNB21CNTRL");
    });

    Test.add_func ("/model/apply-notify-mistyped", () => {
        var state = running ("nX");
        Model.apply_notify (state, parse (NOTIFY_MISTYPED));
        assert (state.backend == Backend.RUNNING);
        assert (state.want_running);
        // A Prefs object whose ExitNodeID is not a string reads as no exit node.
        assert_cmpstr (state.exit_node_id, CompareOperator.EQ, "");
    });

    Test.add_func ("/model/parse-status", () => {
        var status = Model.parse_status (parse (STATUS));
        assert_cmpstr (status.ipv4, CompareOperator.EQ, "100.111.62.70");
        assert (status.health.length == 1);
        assert_cmpstr (status.health[0], CompareOperator.EQ, "some warning");
        // Only ExitNodeOption peers with an ID, sorted by name.
        assert (status.exit_nodes.length == 2);
        assert_cmpstr (status.exit_nodes[0].name, CompareOperator.EQ, "alpha");
        assert (!status.exit_nodes[0].online);
        assert_cmpstr (status.exit_nodes[1].name, CompareOperator.EQ, "basestar");
        assert_cmpstr (status.exit_nodes[1].id, CompareOperator.EQ, "nbaJt4JzNB21CNTRL");
        assert (status.exit_nodes[1].online);
    });

    Test.add_func ("/model/parse-status-logged-out", () => {
        var status = Model.parse_status (parse (STATUS_LOGGED_OUT));
        assert (status.ipv4 == null);
        assert (status.health.length == 0);
        assert (status.exit_nodes.length == 0);
    });

    Test.add_func ("/model/exit-node-name", () => {
        var nodes = Model.parse_status (parse (STATUS)).exit_nodes;
        assert_cmpstr (Model.exit_node_name ("nbaJt4JzNB21CNTRL", nodes), CompareOperator.EQ, "basestar");
        assert_cmpstr (Model.exit_node_name ("nGONE", nodes), CompareOperator.EQ, "nGONE");
    });

    Test.add_func ("/model/describe", () => {
        assert_cmpstr (Model.describe (running (""), null), CompareOperator.EQ, "Running");
        assert_cmpstr (Model.describe (running ("nX"), "basestar"), CompareOperator.EQ, "Running, exit node basestar");
        assert_cmpstr (Model.describe (running ("nX"), null), CompareOperator.EQ, "Running, exit node nX");

        var state = new State ();
        assert_cmpstr (Model.describe (state, null), CompareOperator.EQ, "unreachable");
        state.backend = Backend.NEEDS_LOGIN;
        assert_cmpstr (Model.describe (state, null), CompareOperator.EQ, "NeedsLogin, switched off");
        state.want_running = true;
        assert_cmpstr (Model.describe (state, null), CompareOperator.EQ, "NeedsLogin");
        state.backend = Backend.STOPPED;
        state.want_running = false;
        assert_cmpstr (Model.describe (state, null), CompareOperator.EQ, "Stopped");
    });

    Test.add_func ("/model/icon-name", () => {
        assert_cmpstr (Model.icon_name (running ("")), CompareOperator.EQ, "network-vpn-symbolic");
        assert_cmpstr (Model.icon_name (running ("nX")), CompareOperator.EQ, "tailscale-exit-node-symbolic");
        var state = new State ();
        assert_cmpstr (Model.icon_name (state), CompareOperator.EQ, "network-vpn-disconnected-symbolic");
        state.backend = Backend.STARTING;
        assert_cmpstr (Model.icon_name (state), CompareOperator.EQ, "network-vpn-acquiring-symbolic");
        state.backend = Backend.STOPPED;
        assert_cmpstr (Model.icon_name (state), CompareOperator.EQ, "network-vpn-disabled-symbolic");
        state.backend = Backend.NEEDS_LOGIN;
        assert_cmpstr (Model.icon_name (state), CompareOperator.EQ, "network-vpn-no-route-symbolic");
    });

    Test.add_func ("/model/status-line", () => {
        assert_cmpstr (Model.status_line (running (""), "100.1.2.3"), CompareOperator.EQ, "Connected · 100.1.2.3");
        assert_cmpstr (Model.status_line (running (""), null), CompareOperator.EQ, "Connected");
        var state = new State ();
        assert_cmpstr (Model.status_line (state, null), CompareOperator.EQ, "tailscaled not running");
        state.backend = Backend.STOPPED;
        assert_cmpstr (Model.status_line (state, null), CompareOperator.EQ, "Off");
        state.backend = Backend.STARTING;
        assert_cmpstr (Model.status_line (state, null), CompareOperator.EQ, "Starting…");
        state.backend = Backend.NEEDS_LOGIN;
        assert_cmpstr (Model.status_line (state, null), CompareOperator.EQ, "Needs login");
    });

    Test.add_func ("/model/bodies", () => {
        assert_cmpstr (Model.running_body (false), CompareOperator.EQ, """{"WantRunningSet":true,"WantRunning":false}""");
        assert_cmpstr (Model.running_body (true), CompareOperator.EQ, """{"WantRunningSet":true,"WantRunning":true}""");
        assert_cmpstr (Model.exit_node_body (""), CompareOperator.EQ, """{"ExitNodeIDSet":true,"ExitNodeID":""}""");
        assert_cmpstr (Model.exit_node_body ("nbaJt4JzNB21CNTRL"), CompareOperator.EQ, """{"ExitNodeIDSet":true,"ExitNodeID":"nbaJt4JzNB21CNTRL"}""");
    });

    Test.add_func ("/model/write-error-text", () => {
        assert_cmpstr (Model.write_error_text (403), CompareOperator.EQ, "Not permitted (403): is --operator set?");
        assert_cmpstr (Model.write_error_text (0), CompareOperator.EQ, "tailscaled not reachable");
        assert_cmpstr (Model.write_error_text (500), CompareOperator.EQ, "Request failed (500)");
    });

    Test.run ();
}
```

- [ ] **Step 2: Write `meson.build` (tests only for now) and `package.nix`**

`packages/wingpanel-indicator-tailscale/meson.build`:

```meson
project('wingpanel-indicator-tailscale', 'vala', 'c', version: '0.1.0')

add_project_arguments('-DG_LOG_DOMAIN="io.elementary.wingpanel.tailscale"', language: 'c')

glib_dep = dependency('glib-2.0')
gobject_dep = dependency('gobject-2.0')
json_dep = dependency('json-glib-1.0')

test('model', executable(
    'test-model',
    'src/Model.vala',
    'tests/TestModel.vala',
    dependencies: [glib_dep, gobject_dep, json_dep],
))
```

`packages/wingpanel-indicator-tailscale/package.nix`:

```nix
# Wingpanel indicator for Tailscale: an icon for tailscaled's state, always
# shown, and a popover with an on/off switch and an exit-node picker.
# Added to Pantheon by modules/desktop/pantheon-tailscale.nix.
# Design: docs/superpowers/specs/2026-11-01-pantheon-tailscale-indicator-design.md
{pkgs, ...}:
pkgs.stdenv.mkDerivation {
  pname = "wingpanel-indicator-tailscale";
  version = "0.1.0";

  # Only the sources, so editing this file or CLAUDE.md does not rebuild it.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [./meson.build ./src ./tests];
  };

  nativeBuildInputs = with pkgs; [meson ninja pkg-config vala];
  buildInputs = with pkgs; [glib gtk3 json-glib libgee libsoup_3 pantheon.granite pantheon.wingpanel];

  # Runs tests/TestModel.vala.
  doCheck = true;

  meta = {
    description = "Tailscale indicator for Wingpanel";
    license = pkgs.lib.licenses.gpl3Plus;
    platforms = pkgs.lib.platforms.linux;
  };
}
```

- [ ] **Step 3: Run the tests to verify they fail (no Model.vala yet)**

```bash
cd /home/arosenfeld/Code/nixos
git add -N packages/wingpanel-indicator-tailscale
B=/tmp/claude-1000/ts-indicator-build
nix develop .#nixosConfigurations.raider.pkgs.wingpanel-indicator-tailscale -c bash -c \
  "cd packages/wingpanel-indicator-tailscale && rm -rf $B && meson setup $B && meson test -C $B --print-errorlogs"
```

Expected: FAIL — meson setup or compile errors because `src/Model.vala` does not exist.

- [ ] **Step 4: Write `src/Model.vala`**

```vala
/*
 * Pure translation of tailscaled's LocalAPI JSON into what the indicator shows.
 * Nothing here touches the socket, so tests/TestModel.vala covers all of it.
 *
 * Every lookup tolerates missing, null or mistyped members. This code runs
 * inside Wingpanel, so a LocalAPI shape change after a nixpkgs bump must
 * degrade the indicator, never crash the panel.
 */
namespace TailscaleIndicator {
    public enum Backend {
        UNREACHABLE,
        NEEDS_LOGIN,
        STOPPED,
        STARTING,
        RUNNING;

        /* As tailscaled names its states; "unreachable" covers everything else. */
        public string to_label () {
            switch (this) {
                case NEEDS_LOGIN:
                    return "NeedsLogin";
                case STOPPED:
                    return "Stopped";
                case STARTING:
                    return "Starting";
                case RUNNING:
                    return "Running";
                default:
                    return "unreachable";
            }
        }
    }

    /* What the IPN bus has said so far. Every set notifies; the indicator follows. */
    public class State : Object {
        public Backend backend { get; set; default = Backend.UNREACHABLE; }
        public bool want_running { get; set; default = false; }
        public string exit_node_id { get; set; default = ""; }
    }

    public class ExitNode : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public bool online { get; construct; }

        public ExitNode (string id, string name, bool online) {
            Object (id: id, name: name, online: online);
        }
    }

    /* One /localapi/v0/status reply, reduced to what the popover shows. */
    public class Status : Object {
        public string? ipv4 { get; set; default = null; }
        public string[] health = {};
        public ExitNode[] exit_nodes = {};
    }

    namespace Model {
        /*
         * ipn.State: 0 NoState, 1 InUseOtherUser, 2 NeedsLogin,
         * 3 NeedsMachineAuth, 4 Stopped, 5 Starting, 6 Running.
         */
        public Backend backend_from_ipn (int64 state) {
            switch (state) {
                case 2:
                case 3:
                    return Backend.NEEDS_LOGIN;
                case 4:
                    return Backend.STOPPED;
                case 5:
                    return Backend.STARTING;
                case 6:
                    return Backend.RUNNING;
                default:
                    return Backend.UNREACHABLE;
            }
        }

        /*
         * Folds one IPN bus Notify into state. A member the Notify lacks leaves
         * that part of state alone. Notifications are held until every field is
         * set, so a listener never sees half of one Notify.
         */
        public void apply_notify (State state, Json.Object notify) {
            state.freeze_notify ();
            var ipn_state = member (notify, "State");
            if (ipn_state != null && ipn_state.get_value_type () == typeof (int64)) {
                state.backend = backend_from_ipn (ipn_state.get_int ());
            }
            var prefs = object_member (notify, "Prefs");
            if (prefs != null) {
                var want = member (prefs, "WantRunning");
                if (want != null && want.get_value_type () == typeof (bool)) {
                    state.want_running = want.get_boolean ();
                }
                state.exit_node_id = string_member (prefs, "ExitNodeID") ?? "";
            }
            state.thaw_notify ();
        }

        public Status parse_status (Json.Object root) {
            var status = new Status ();
            var self = object_member (root, "Self");
            if (self != null) {
                status.ipv4 = first_ipv4 (array_member (self, "TailscaleIPs"));
            }

            var health = array_member (root, "Health");
            if (health != null) {
                foreach (unowned Json.Node node in health.get_elements ()) {
                    if (node.get_value_type () == typeof (string)) {
                        status.health += node.get_string ();
                    }
                }
            }

            var candidates = new GenericArray<ExitNode> ();
            var peers = object_member (root, "Peer");
            if (peers != null) {
                foreach (unowned string key in peers.get_members ()) {
                    var peer = object_member (peers, key);
                    if (peer == null || !bool_member (peer, "ExitNodeOption")) {
                        continue;
                    }
                    var id = string_member (peer, "ID");
                    if (id == null || id == "") {
                        continue;
                    }
                    candidates.add (new ExitNode (id, string_member (peer, "HostName") ?? id, bool_member (peer, "Online")));
                }
            }
            candidates.sort ((a, b) => strcmp (a.name, b.name));
            foreach (var node in candidates) {
                status.exit_nodes += node;
            }
            return status;
        }

        /* The candidate's host name, or the raw id when no candidate has it. */
        public string exit_node_name (string id, ExitNode[] nodes) {
            foreach (var node in nodes) {
                if (node.id == id) {
                    return node.name;
                }
            }
            return id;
        }

        /*
         * The text after "Tailscale: " in the state log line, asserted by the VM
         * test. "switched off" is reported apart from the backend because a node
         * that never logged in stays NeedsLogin after WantRunning goes false.
         */
        public string describe (State state, string? exit_name) {
            var text = state.backend.to_label ();
            if (state.backend == Backend.UNREACHABLE) {
                return text;
            }
            if (!state.want_running && state.backend != Backend.STOPPED) {
                text += ", switched off";
            }
            if (state.exit_node_id != "") {
                text += ", exit node " + (exit_name ?? state.exit_node_id);
            }
            return text;
        }

        public string icon_name (State state) {
            switch (state.backend) {
                case Backend.RUNNING:
                    return state.exit_node_id != "" ? "tailscale-exit-node-symbolic" : "network-vpn-symbolic";
                case Backend.STARTING:
                    return "network-vpn-acquiring-symbolic";
                case Backend.STOPPED:
                    return "network-vpn-disabled-symbolic";
                case Backend.NEEDS_LOGIN:
                    return "network-vpn-no-route-symbolic";
                default:
                    return "network-vpn-disconnected-symbolic";
            }
        }

        public string status_line (State state, string? ipv4) {
            switch (state.backend) {
                case Backend.RUNNING:
                    return ipv4 != null ? "Connected · " + ipv4 : "Connected";
                case Backend.STARTING:
                    return "Starting…";
                case Backend.STOPPED:
                    return "Off";
                case Backend.NEEDS_LOGIN:
                    return "Needs login";
                default:
                    return "tailscaled not running";
            }
        }

        /* PATCH /prefs bodies: ipn.MaskedPrefs, where only fields flagged <Name>Set apply. */
        public string running_body (bool on) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("WantRunningSet");
            builder.add_boolean_value (true);
            builder.set_member_name ("WantRunning");
            builder.add_boolean_value (on);
            builder.end_object ();
            return Json.to_string (builder.get_root (), false);
        }

        public string exit_node_body (string id) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("ExitNodeIDSet");
            builder.add_boolean_value (true);
            builder.set_member_name ("ExitNodeID");
            builder.add_string_value (id);
            builder.end_object ();
            return Json.to_string (builder.get_root (), false);
        }

        /* status is the HTTP status, or 0 when tailscaled could not be reached. */
        public string write_error_text (uint status) {
            if (status == 403) {
                return "Not permitted (403): is --operator set?";
            }
            if (status == 0) {
                return "tailscaled not reachable";
            }
            return "Request failed (%u)".printf (status);
        }

        private string? first_ipv4 (Json.Array? ips) {
            if (ips == null) {
                return null;
            }
            foreach (unowned Json.Node node in ips.get_elements ()) {
                if (node.get_value_type () == typeof (string) && !node.get_string ().contains (":")) {
                    return node.get_string ();
                }
            }
            return null;
        }

        private Json.Node? member (Json.Object obj, string name) {
            return obj.has_member (name) ? obj.get_member (name) : null;
        }

        private Json.Object? object_member (Json.Object obj, string name) {
            var node = member (obj, name);
            return (node != null && node.get_node_type () == Json.NodeType.OBJECT) ? node.get_object () : null;
        }

        private Json.Array? array_member (Json.Object obj, string name) {
            var node = member (obj, name);
            return (node != null && node.get_node_type () == Json.NodeType.ARRAY) ? node.get_array () : null;
        }

        private string? string_member (Json.Object obj, string name) {
            var node = member (obj, name);
            return (node != null && node.get_value_type () == typeof (string)) ? node.get_string () : null;
        }

        private bool bool_member (Json.Object obj, string name) {
            var node = member (obj, name);
            return node != null && node.get_value_type () == typeof (bool) && node.get_boolean ();
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Same command as Step 3. Expected: `1/1 model OK`. If a Vala/json-glib binding detail differs from the code above (e.g. `get_value_type` on a null node), fix `Model.vala`, not the tests, unless the test itself asserts something the spec does not require.

- [ ] **Step 6: Commit**

```bash
git add packages/wingpanel-indicator-tailscale
git commit -m "feat(modules): tailscale indicator model with unit tests"
```

---

### Task 2: LocalAPI client, indicator UI and exit-node icon

**Files:**
- Create: `packages/wingpanel-indicator-tailscale/src/LocalApi.vala`
- Create: `packages/wingpanel-indicator-tailscale/src/Indicator.vala`
- Create: `packages/wingpanel-indicator-tailscale/src/tailscale.gresource.xml`
- Create: `packages/wingpanel-indicator-tailscale/src/icons/tailscale-exit-node-symbolic.svg`
- Modify: `packages/wingpanel-indicator-tailscale/meson.build` (append the shared module)

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces: `TailscaleIndicator.LocalApi (State state)` with `async Status? status ()`, `async uint set_running (bool on)`, `async uint set_exit_node (string id)`; `libtailscale-indicator.so` exporting `get_indicator`; code name `tailscale`; the log lines in Global Constraints.

- [ ] **Step 1: Write `src/LocalApi.vala`**

```vala
/*
 * tailscaled's LocalAPI over its unix socket: the IPN bus stream that keeps
 * `state` current, /status, and PATCH /prefs. All of it is async, so the
 * panel's main loop never waits on tailscaled.
 *
 * Writes succeed only for root and tailscaled's --operator user, which
 * modules/desktop/pantheon-tailscale.nix makes the desktop user; anyone else
 * gets 403.
 */
public class TailscaleIndicator.LocalApi : Object {
    private const string SOCKET = "/run/tailscale/tailscaled.sock";
    // tailscaled checks the Host header; the name is a convention, never resolved.
    private const string BASE = "http://local-tailscaled.sock/localapi/v0/";
    // NotifyInitialState | NotifyInitialPrefs | NotifyNoPrivateKeys.
    private const int WATCH_MASK = 2 | 4 | 16;
    private const uint MAX_BACKOFF_S = 30;

    public State state { get; construct; }

    private Soup.Session session;

    public LocalApi (State state) {
        Object (state: state);
    }

    construct {
        // timeout 0: the IPN bus can stay silent for hours, and libsoup's
        // default 60 s I/O timeout would cut it every minute. Four connections
        // per host so /status and a write never queue behind the stream.
        session = new Soup.Session.with_options (
            "remote-connectable", new UnixSocketAddress (SOCKET),
            "timeout", 0,
            "idle-timeout", 0,
            "max-conns-per-host", 4
        );
        watch.begin ();
    }

    /*
     * Follows the IPN bus for the life of the panel. When the stream ends or
     * fails (tailscaled stopped or restarting), state goes unreachable and the
     * stream reopens after 1 s, doubling to 30 s, reset by the first line read.
     */
    private async void watch () {
        uint backoff_s = 1;
        while (true) {
            try {
                var msg = new Soup.Message ("GET", BASE + "watch-ipn-bus?mask=%d".printf (WATCH_MASK));
                var stream = yield session.send_async (msg, Priority.DEFAULT, null);
                if (msg.status_code != Soup.Status.OK) {
                    throw new IOError.FAILED ("HTTP %u", msg.status_code);
                }
                var lines = new DataInputStream (stream);
                string? line;
                while ((line = yield lines.read_line_async (Priority.DEFAULT, null)) != null) {
                    backoff_s = 1;
                    apply_line (line);
                }
            } catch (Error e) {
                debug ("IPN bus: %s", e.message);
            }
            state.backend = Backend.UNREACHABLE;
            yield sleep (backoff_s);
            backoff_s = uint.min (backoff_s * 2, MAX_BACKOFF_S);
        }
    }

    private void apply_line (string line) {
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (line);
        } catch (Error e) {
            debug ("IPN bus: unparseable line: %s", e.message);
            return;
        }
        var root = parser.get_root ();
        if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
            Model.apply_notify (state, root.get_object ());
        }
    }

    private async void sleep (uint seconds) {
        Timeout.add_seconds (seconds, sleep.callback);
        yield;
    }

    /* Null when tailscaled is unreachable or its reply is not a JSON object. */
    public async Status? status () {
        var msg = new Soup.Message ("GET", BASE + "status");
        try {
            var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
            if (msg.status_code != Soup.Status.OK) {
                debug ("/status: HTTP %u", msg.status_code);
                return null;
            }
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return null;
            }
            return Model.parse_status (root.get_object ());
        } catch (Error e) {
            debug ("/status: %s", e.message);
            return null;
        }
    }

    /* Each returns the HTTP status, or 0 when tailscaled could not be reached. */
    public async uint set_running (bool on) {
        return yield patch_prefs (Model.running_body (on));
    }

    public async uint set_exit_node (string id) {
        return yield patch_prefs (Model.exit_node_body (id));
    }

    private async uint patch_prefs (string body) {
        var msg = new Soup.Message ("PATCH", BASE + "prefs");
        msg.set_request_body_from_bytes ("application/json", new Bytes (body.data));
        try {
            yield session.send_and_read_async (msg, Priority.DEFAULT, null);
        } catch (Error e) {
            debug ("PATCH /prefs: %s", e.message);
            return 0;
        }
        return msg.status_code;
    }
}
```

- [ ] **Step 2: Write `src/Indicator.vala`**

```vala
/*
 * Tailscale in Wingpanel: an icon for tailscaled's state, always shown, and a
 * popover with an on/off switch, the node's IPv4, an exit-node picker and any
 * health warnings.
 *
 * Every change of state logs one line ("Tailscale: <Model.describe>") and every
 * /status fetch logs "Tailscale status: <n> exit node candidate(s)" or
 * "Tailscale status: unavailable"; the VM test
 * (tests/pantheon-tailscale-test.nix) asserts on them, so keep them stable.
 *
 * Controls show only what the IPN bus reports: a write never moves them, so a
 * refused one snaps back when the popover is resynced.
 */
public class TailscaleIndicator.Indicator : Wingpanel.Indicator {
    private const string ICONS = "/io/elementary/wingpanel/tailscale/icons";

    private State state;
    private LocalApi api;
    // The last /status: exit-node names and the IPv4. Empty until the first fetch.
    private Status status = new Status ();
    private string last_logged = "";
    private Backend last_backend = Backend.UNREACHABLE;
    private string last_exit = "";

    private Gtk.Image? icon = null;
    private Gtk.Box? popover = null;
    private Granite.SwitchModelButton? toggle = null;
    private Gtk.Label? error_label = null;
    private Gtk.Label? status_label = null;
    private Gtk.Box? exit_box = null;
    private Gtk.Box? health_box = null;
    // Set while widgets are moved to match tailscaled, so their handlers write nothing.
    private bool syncing = false;

    public Indicator () {
        Object (code_name: "tailscale");
    }

    construct {
        Gtk.IconTheme.get_default ().add_resource_path (ICONS);
        state = new State ();
        state.notify.connect (on_state_changed);
        api = new LocalApi (state);
        visible = true;
    }

    /*
     * Refetches /status when Tailscale comes up or the exit node changes, so
     * the log line and icon tooltip can name the exit node without the popover.
     */
    private void on_state_changed () {
        if ((state.backend == Backend.RUNNING && last_backend != Backend.RUNNING) || state.exit_node_id != last_exit) {
            refresh.begin ();
        }
        last_backend = state.backend;
        last_exit = state.exit_node_id;
        update ();
    }

    private void update () {
        var line = Model.describe (state, exit_name ());
        if (line != last_logged) {
            last_logged = line;
            message ("Tailscale: %s", line);
        }
        if (icon != null) {
            icon.icon_name = Model.icon_name (state);
            icon.tooltip_text = "Tailscale: " + Model.status_line (state, status.ipv4);
        }
        sync_popover ();
    }

    private string? exit_name () {
        return state.exit_node_id == "" ? null : Model.exit_node_name (state.exit_node_id, status.exit_nodes);
    }

    public override Gtk.Widget get_display_widget () {
        if (icon == null) {
            icon = new Gtk.Image.from_icon_name (Model.icon_name (state), Gtk.IconSize.LARGE_TOOLBAR) {
                tooltip_text = "Tailscale"
            };
        }
        return icon;
    }

    public override Gtk.Widget? get_widget () {
        if (popover == null) {
            toggle = new Granite.SwitchModelButton ("Tailscale");
            toggle.get_style_context ().add_class (Granite.STYLE_CLASS_H4_LABEL);
            toggle.notify["active"].connect (() => {
                if (!syncing) {
                    write.begin (true, toggle.active, "");
                }
            });

            error_label = new Gtk.Label (null) {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                wrap = true,
                max_width_chars = 32,
                no_show_all = true
            };
            error_label.get_style_context ().add_class (Gtk.STYLE_CLASS_ERROR);

            status_label = new Gtk.Label (null) {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                margin_bottom = 3,
                selectable = true
            };
            status_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);

            exit_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            health_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                margin_bottom = 3
            };

            popover = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                width_request = 250
            };
            popover.add (toggle);
            popover.add (error_label);
            popover.add (status_label);
            popover.add (exit_box);
            popover.add (health_box);
            popover.show_all ();
            sync_popover ();
        }
        return popover;
    }

    public override void opened () {
        refresh.begin ();
    }

    public override void closed () {
        if (error_label != null) {
            error_label.hide ();
        }
    }

    private async void refresh () {
        var fetched = yield api.status ();
        if (fetched == null) {
            message ("Tailscale status: unavailable");
            status = new Status ();
        } else {
            status = fetched;
            message ("Tailscale status: %d exit node candidate(s)", status.exit_nodes.length);
        }
        update ();
    }

    /* running: whether this write is the switch (on) or the exit node (exit_id). */
    private async void write (bool running, bool on, string exit_id) {
        uint code;
        if (running) {
            code = yield api.set_running (on);
        } else {
            code = yield api.set_exit_node (exit_id);
        }
        if (error_label == null) {
            return;
        }
        if (code >= 200 && code < 300) {
            error_label.hide ();
        } else {
            error_label.label = Model.write_error_text (code);
            error_label.show ();
            sync_popover ();
        }
    }

    /* Rebuilt from state and the last /status; never writes. */
    private void sync_popover () {
        if (popover == null) {
            return;
        }
        syncing = true;
        var reachable = state.backend != Backend.UNREACHABLE;
        toggle.sensitive = reachable;
        toggle.active = reachable && state.want_running;
        status_label.label = Model.status_line (state, status.ipv4);

        exit_box.foreach ((child) => child.destroy ());
        if (state.backend == Backend.RUNNING && status.exit_nodes.length > 0) {
            exit_box.add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
                margin_top = 3,
                margin_bottom = 3
            });
            var header = new Gtk.Label ("Exit node") {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12
            };
            header.get_style_context ().add_class (Granite.STYLE_CLASS_H4_LABEL);
            exit_box.add (header);
            var group = exit_row (null, "", "None", true);
            foreach (var node in status.exit_nodes) {
                exit_row (group, node.id, node.online ? node.name : node.name + " (offline)", node.online);
            }
        }
        exit_box.show_all ();

        health_box.foreach ((child) => child.destroy ());
        foreach (unowned string text in status.health) {
            var label = new Gtk.Label (text) {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                margin_top = 3,
                wrap = true,
                max_width_chars = 32
            };
            label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
            health_box.add (label);
        }
        health_box.show_all ();
        syncing = false;
    }

    private Gtk.RadioButton exit_row (Gtk.RadioButton? group, string id, string label, bool sensitive) {
        var row = new Gtk.RadioButton.with_label_from_widget (group, label) {
            sensitive = sensitive,
            margin_start = 12,
            margin_end = 12,
            margin_top = 3,
            margin_bottom = 3
        };
        row.active = state.exit_node_id == id;
        // The handler's own argument, not `row`: capturing `row` would make the
        // button own a closure that owns the button, and it could never be freed.
        row.toggled.connect ((button) => {
            if (!syncing && button.active) {
                write.begin (false, false, id);
            }
        });
        exit_box.add (row);
        return row;
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    // Nothing to control from the login screen.
    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }
    return new TailscaleIndicator.Indicator ();
}
```

- [ ] **Step 3: Write the icon and its resource file**

`src/icons/tailscale-exit-node-symbolic.svg` (a padlock, the theme's VPN idiom, with an outbound arrow; 16×16, one fill colour so GTK recolours it as symbolic):

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path fill="#474747" d="M5 1a3 3 0 0 0-3 3v2H1v8h8V6H8V4a3 3 0 0 0-3-3zm0 1.5A1.5 1.5 0 0 1 6.5 4v2h-3V4A1.5 1.5 0 0 1 5 2.5z"/>
  <path fill="#474747" d="M11 1h4v4l-1.5-1.5L11 6 10 5l2.5-2.5z"/>
</svg>
```

`src/tailscale.gresource.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gresources>
  <!-- Gtk.IconTheme.add_resource_path treats this prefix as a hicolor tree. -->
  <gresource prefix="/io/elementary/wingpanel/tailscale/icons">
    <file alias="scalable/status/tailscale-exit-node-symbolic.svg">icons/tailscale-exit-node-symbolic.svg</file>
  </gresource>
</gresources>
```

- [ ] **Step 4: Append the plugin to `meson.build`**

Add to the end of `packages/wingpanel-indicator-tailscale/meson.build`:

```meson
wingpanel_dep = dependency('wingpanel')

# Linked into the plugin; its generated constructor registers it on load.
resources = import('gnome').compile_resources(
    'tailscale-resources',
    'src/tailscale.gresource.xml',
    source_dir: 'src',
)

shared_module(
    'tailscale-indicator',
    'src/Model.vala',
    'src/LocalApi.vala',
    'src/Indicator.vala',
    resources,
    dependencies: [
        glib_dep,
        gobject_dep,
        json_dep,
        dependency('gio-2.0'),
        dependency('gio-unix-2.0'),
        dependency('libsoup-3.0'),
        dependency('gtk+-3.0'),
        dependency('granite'),
        wingpanel_dep,
    ],
    install: true,
    install_dir: wingpanel_dep.get_variable(
        pkgconfig: 'indicatorsdir',
        pkgconfig_define: ['libdir', get_option('prefix') / get_option('libdir')],
    ),
)
```

- [ ] **Step 5: Build the package and check the plugin**

```bash
cd /home/arosenfeld/Code/nixos
git add -N packages/wingpanel-indicator-tailscale
out=$(nix build --no-link --print-out-paths .#nixosConfigurations.raider.pkgs.wingpanel-indicator-tailscale -L)
ls $out/lib/wingpanel/
nm -D $out/lib/wingpanel/libtailscale-indicator.so | grep ' T get_indicator'
nix shell nixpkgs#glib.bin -c gresource list $out/lib/wingpanel/libtailscale-indicator.so
```

Expected: `libtailscale-indicator.so` listed; `get_indicator` exported; the resource list contains `/io/elementary/wingpanel/tailscale/icons/scalable/status/tailscale-exit-node-symbolic.svg`. The build must have no Vala warnings beyond what the gamemode indicator emits; fix any about unhandled errors or unowned misuse. `checkPhase` still passes `model`.

- [ ] **Step 6: Commit**

```bash
git add packages/wingpanel-indicator-tailscale
git commit -m "feat(modules): tailscale wingpanel indicator plugin"
```

---

### Task 3: Feature module, desktop wiring and VM test

**Files:**
- Create: `modules/desktop/pantheon-tailscale.nix`
- Modify: `modules/desktop/desktop.nix:14` (import the feature next to `features.pantheon-gamemode`)
- Create: `tests/pantheon-tailscale-test.nix`
- Modify: `modules/flake/checks.nix` (add `pantheon-tailscale-test` after `pantheon-gamemode-test`)

**Interfaces:**
- Consumes: `packages/wingpanel-indicator-tailscale/package.nix` (Task 1/2); the log lines and code name from Task 2.
- Produces: feature `flake.modules.nixos.pantheon-tailscale`; check `checks.x86_64-linux.pantheon-tailscale-test`.

- [ ] **Step 1: Write the module**

`modules/desktop/pantheon-tailscale.nix`:

```nix
# Tailscale in Pantheon's Wingpanel: an icon for tailscaled's state, always
# shown, and a popover with an on/off switch and an exit-node picker.
# Package: packages/wingpanel-indicator-tailscale.
# Design: docs/superpowers/specs/2026-11-01-pantheon-tailscale-indicator-design.md
#
# Gated on the two upstream options rather than constellation.*, so the VM test
# (tests/pantheon-tailscale-test.nix) can import this module alone; callPackage
# rather than the flake overlay's attribute for the same reason.
{
  flake.modules.nixos.pantheon-tailscale = {
    key = "modules/desktop/pantheon-tailscale";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: {
        config = lib.mkIf (config.services.tailscale.enable && config.services.desktopManager.pantheon.enable) {
          services.desktopManager.pantheon.extraWingpanelIndicators = [
            (pkgs.callPackage ../../packages/wingpanel-indicator-tailscale/package.nix {})
          ];
          # tailscaled lets only root and its operator change prefs, answering
          # 403 to anyone else, and the popover's switch and exit-node picker are
          # such changes. Merges with base's --ssh; tailscaled-set reapplies the
          # list every time tailscaled starts.
          services.tailscale.extraSetFlags = ["--operator=arosenfeld"];
        };
      })
    ];
  };
}
```

- [ ] **Step 2: Import it from `desktop.nix`**

In `modules/desktop/desktop.nix`, change:

```nix
      features.pantheon-dock
      features.pantheon-gamemode
```

to:

```nix
      features.pantheon-dock
      features.pantheon-gamemode
      features.pantheon-tailscale
```

- [ ] **Step 3: Write the VM test**

`tests/pantheon-tailscale-test.nix`:

```nix
# Boots Pantheon with the Tailscale indicator (modules/desktop/pantheon-tailscale.nix)
# and a tailscaled that has no control server, so it waits at NeedsLogin. Drives
# it through the paths that need no tailnet: the popover's /status fetch,
# writes through PATCH /prefs (the exact request the switch sends) as the
# operator and as a user who is not, and a tailscaled stop and start. The
# indicator logs each change; this asserts on those lines. Exit-node selection
# needs a control server and is covered by the unit tests and by acceptance on
# raider. Modelled on pantheon-gamemode-test.
{pkgs, ...}: let
  wingpanelAction = pkgs.writeShellScriptBin "wingpanel-action" ''
    exec ${pkgs.glib.bin}/bin/gdbus call --session --dest org.elementary.wingpanel \
      --object-path /org/elementary/wingpanel --method org.gtk.Actions.Activate \
      "$1-indicator" "[<'tailscale'>]" '{}'
  '';
  # Fails (curl -f) on anything but 2xx, so a 403 fails the command.
  wantRunning = pkgs.writeShellScriptBin "tailscale-want-running" ''
    exec ${pkgs.curl}/bin/curl -sf -X PATCH --unix-socket /run/tailscale/tailscaled.sock \
      -H 'Host: local-tailscaled.sock' -d "{\"WantRunningSet\":true,\"WantRunning\":$1}" \
      http://local-tailscaled.sock/localapi/v0/prefs
  '';
in {
  name = "pantheon-tailscale";
  enableOCR = true;

  nodes.machine = {...}: {
    imports = [
      (import ../modules/desktop/pantheon-tailscale.nix).flake.modules.nixos.pantheon-tailscale
    ];

    # Workaround ".gala-wrapped invoked oom-killer" (as upstream's test).
    virtualisation.memorySize = 2047;

    # The module grants --operator to arosenfeld, so the session user is that
    # user; bob is the control who is not the operator.
    users.users.arosenfeld = {
      isNormalUser = true;
      uid = 1000;
      password = "foobar";
    };
    users.users.bob = {
      isNormalUser = true;
      uid = 1001;
    };

    services.xserver.enable = true;
    services.desktopManager.pantheon.enable = true;
    services.displayManager = {
      defaultSession = "pantheon-wayland";
      autoLogin = {
        enable = true;
        user = "arosenfeld";
      };
    };

    services.tailscale.enable = true;
    environment.systemPackages = [wingpanelAction wantRunning];
  };

  testScript = {nodes, ...}: let
    user = nodes.machine.users.users.arosenfeld;
    bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString user.uid}/bus";
    panel = "pgrep -f '(^|/)io\\.elementary\\.wingpanel$'";
    log = "journalctl -b -t io.elementary.wingpanel";
  in ''
    LOG = "${log}"

    def as_user(cmd):
        return machine.succeed(f"su - arosenfeld -c '${bus} {cmd}'")

    # Lines can repeat (unreachable at startup, again after a stop), so each
    # step waits for one more matching line than there was before it.
    def count(pattern):
        return int(machine.succeed("%s | grep -cE '%s' || true" % (LOG, pattern)).strip())

    def wait_for_more(pattern, before, timeout=90):
        machine.wait_until_succeeds(
            "test $(%s | grep -cE '%s') -gt %d" % (LOG, pattern, before), timeout=timeout
        )

    machine.wait_for_unit("display-manager.service")
    machine.wait_for_file("/run/user/${toString user.uid}/wayland-0")

    with subtest("Wingpanel loads the indicator, which follows tailscaled to NeedsLogin"):
        machine.wait_until_succeeds("${panel}")
        machine.wait_until_succeeds(
            "su - arosenfeld -c '${bus} gdbus call --session --dest org.elementary.wingpanel "
            "--object-path /org/elementary/wingpanel --method org.gtk.Actions.DescribeAll' | grep -q tailscale"
        )
        panel_pid = machine.succeed("${panel}").strip()
        machine.wait_until_succeeds("%s | grep -q 'Tailscale: NeedsLogin$'" % LOG, timeout=90)

    with subtest("Opening the popover fetches /status and shows the state"):
        before = count("Tailscale status: ")
        as_user("wingpanel-action open")
        wait_for_more("Tailscale status: 0 exit node candidate", before)
        machine.wait_for_text("Needs login")
        machine.screenshot("tailscale_popover")
        as_user("wingpanel-action close")

    with subtest("Only the operator may write prefs"):
        machine.wait_until_succeeds("tailscale debug prefs | grep -q '\"OperatorUser\": \"arosenfeld\"'")
        machine.fail("su - bob -c 'tailscale-want-running false'")
        before = count("Tailscale: (Stopped|NeedsLogin, switched off)$")
        as_user("tailscale-want-running false")
        wait_for_more("Tailscale: (Stopped|NeedsLogin, switched off)$", before)
        before = count("Tailscale: NeedsLogin$")
        as_user("tailscale-want-running true")
        wait_for_more("Tailscale: NeedsLogin$", before)

    with subtest("tailscaled stopping and starting is followed"):
        before = count("Tailscale: unreachable$")
        machine.succeed("systemctl stop tailscaled")
        wait_for_more("Tailscale: unreachable$", before)
        before = count("Tailscale: NeedsLogin$")
        machine.succeed("systemctl start tailscaled")
        wait_for_more("Tailscale: NeedsLogin$", before)

    with subtest("The indicator logged no warning and the panel never restarted"):
        # Positive control: the domain filter does match the indicator's messages.
        machine.succeed("journalctl -b -q GLIB_DOMAIN=io.elementary.wingpanel.tailscale | grep -q 'Tailscale: NeedsLogin'")
        machine.fail("journalctl -b -q GLIB_DOMAIN=io.elementary.wingpanel.tailscale -p warning | grep .")
        assert machine.succeed("${panel}").strip() == panel_pid, "wingpanel restarted"
  '';
}
```

- [ ] **Step 4: Expose the check**

In `modules/flake/checks.nix`, after the `pantheon-gamemode-test = …;` entry, add:

```nix
        pantheon-tailscale-test = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
          import ../../tests/pantheon-tailscale-test.nix
        );
```

- [ ] **Step 5: Format and run the VM test**

```bash
cd /home/arosenfeld/Code/nixos
git add -N modules/desktop/pantheon-tailscale.nix tests/pantheon-tailscale-test.nix
nix develop -c just fmt
nice nix build .#checks.x86_64-linux.pantheon-tailscale-test -L
```

Expected: all five subtests pass. If tailscaled's fresh state is not `NeedsLogin` (e.g. it stays `NoState`, logged as `unreachable`), investigate with `tailscale status --json` in the VM (`nix run .#checks.x86_64-linux.pantheon-tailscale-test.driverInteractive`) and adapt the *test's* expectation and this plan's spec note — not the Model mapping — then rerun. Do not weaken the operator/403 subtest or the no-warning subtest.

- [ ] **Step 6: Check both hosts pick it up (one at a time)**

```bash
nice nix eval --json .#nixosConfigurations.raider.config.services.tailscale.extraSetFlags
nice nix eval --json .#nixosConfigurations.blackbird.config.services.tailscale.extraSetFlags
nice nix eval --json .#nixosConfigurations.galactica.config.services.tailscale.extraSetFlags
nice nix build --no-link .#nixosConfigurations.raider.config.system.build.toplevel
```

Expected: raider and blackbird `["--ssh","--operator=arosenfeld"]` (order may differ); galactica `["--ssh"]` only; raider's toplevel builds.

- [ ] **Step 7: Commit**

```bash
git add modules/desktop/pantheon-tailscale.nix modules/desktop/desktop.nix tests/pantheon-tailscale-test.nix modules/flake/checks.nix
git commit -m "feat(modules): wire the tailscale indicator into pantheon hosts"
```

---

### Task 4: Visual loop on raider, docs

**Files:**
- Modify: `just/pantheon.just` (the `panel-run` recipe, ~lines 57-100)
- Create: `packages/wingpanel-indicator-tailscale/CLAUDE.md`
- Modify: `CLAUDE.md` (features table row and host-local note)

**Interfaces:**
- Consumes: package attribute `wingpanel-indicator-tailscale`, `.so` name `libtailscale-indicator.so`.
- Produces: `just pantheon::panel-run [indicator] [log] [env…]`, where `indicator` defaults to `gamemode` so existing use is unchanged.

- [ ] **Step 1: Generalise `panel-run`**

Replace the recipe's header comment, signature and the lines that hardcode gamemode:

```just
# Replace the session's panel with one that loads this checkout's build of
# INDICATOR (wingpanel-indicator-INDICATOR, libINDICATOR-indicator.so) in place
# of the deployed one, passing any VAR=value environment through (e.g.
# G_MESSAGES_DEBUG=all). Logs go to LOG.
[positional-arguments]
panel-run indicator="gamemode" log="/tmp/io.elementary.wingpanel.log" *env:
    #!/usr/bin/env bash
    set -euo pipefail
    name="$1"
    log="$2"
    shift 2
    extra=("$@")
    indicator=$(nix build --no-link --print-out-paths "{{ justfile_directory() }}#nixosConfigurations.raider.pkgs.wingpanel-indicator-$name")
    so="lib$name-indicator.so"
```

and in the loop/link lines below, replace the literal `libgamemode-indicator.so` with `"$so"`:

```bash
    for f in "$current"/*.so; do
        [ "$(basename "$f")" = "$so" ] || ln -s "$f" "$dir/"
    done
    ln -s "$indicator/lib/wingpanel/$so" "$dir/"
```

Leave the rest of the recipe as is. Verify `just --list pantheon` parses: `nix develop -c just --list pantheon`.

- [ ] **Step 2: Write `packages/wingpanel-indicator-tailscale/CLAUDE.md`**

```markdown
# The Tailscale Wingpanel indicator

Design: `docs/superpowers/specs/2026-11-01-pantheon-tailscale-indicator-design.md`.
Wired in by `modules/desktop/pantheon-tailscale.nix` wherever Tailscale and Pantheon
are both on, together with `--operator=arosenfeld`, without which every write is a 403.

- `src/Model.vala` is pure and unit-tested (`tests/TestModel.vala`, run in `checkPhase`);
  put any new JSON reading or wording there with a test, not in `Indicator.vala`.
- The log lines in `Indicator.vala` are asserted by `tests/pantheon-tailscale-test.nix`
  (`nix build .#checks.x86_64-linux.pantheon-tailscale-test -L`). Change both together.
- Never log at warning or above for tailscaled being down, bad JSON or a refused write;
  the VM test fails on any warning from this log domain.
- The LocalAPI is not a stable public API. After a nixpkgs bump that moves tailscale's
  minor version, re-capture `/localapi/v0/status` and one `watch-ipn-bus?mask=22` line
  and check the members `Model.vala` reads still exist.

## Looking at it on raider

    just pantheon::panel-run tailscale             # this checkout's indicator, live
    until grep -q 'Tailscale: ' /tmp/io.elementary.wingpanel.log; do sleep 0.5; done; sleep 1
    gdbus call --session --dest org.elementary.wingpanel --object-path /org/elementary/wingpanel \
      --method org.gtk.Actions.Activate open-indicator "[<'tailscale'>]" '{}'
    sleep 2; just pantheon::shot out.png 2240 0 1200 500

Everything about `shot` (locked or blanked screens, why it is the only capture that
works) is in `modules/desktop/pantheon-dock/CLAUDE.md`. Afterwards
`pkill -f '(^|/)io\.elementary\.wingpanel$'` and gala respawns the stock panel.
```

- [ ] **Step 3: Update the root `CLAUDE.md`**

In the Features table, after the `desktop` row, the `desktop` purpose text says it imports `pantheon-dock` and `pantheon-gamemode`; change it to:

```
| `desktop` | `modules/desktop/desktop.nix` | Desktop environment (`variant` selects GNOME etc.); imports `pantheon-dock`, `pantheon-gamemode` and `pantheon-tailscale` (Wingpanel Tailscale indicator; grants `--operator=arosenfeld`) |
```

- [ ] **Step 4: Visual check on raider**

Run the loop from Step 2 in raider's live session (this replaces the panel; gala respawns the stock one afterwards). Before deploy, raider has no operator grant, so:
1. Screenshot the popover in the Running state: switch on, `Connected · 100.111.62.70`, an `Exit node` section with `None` selected and `basestar`.
2. Click is not available; instead trigger a refused write by running, as the user,
   `curl -s -o /dev/null -w '%{http_code}\n' -X PATCH --unix-socket /run/tailscale/tailscaled.sock -H 'Host: local-tailscaled.sock' -d '{"WantRunningSet":true,"WantRunning":true}' http://local-tailscaled.sock/localapi/v0/prefs`
   and confirm it prints `403` (that is the path the popover's error line reports).
3. Read `/tmp/io.elementary.wingpanel.log`: expect `Tailscale: Running` and `Tailscale status: 1 exit node candidate(s)`, and no `WARNING`/`CRITICAL` from `io.elementary.wingpanel.tailscale`.
4. Restore the stock panel.

Report the screenshot path(s) under the session scratchpad. If the layout is wrong (clipped text, the header not aligned with rows, icon not recoloured as symbolic), fix `Indicator.vala` or the SVG and repeat.

- [ ] **Step 5: Commit**

```bash
git add just/pantheon.just packages/wingpanel-indicator-tailscale/CLAUDE.md CLAUDE.md
git commit -m "docs(modules): tailscale indicator visual loop; panel-run takes the indicator name"
```

---

### Task 5: Deploy raider and accept (controller, not a subagent)

- [ ] **Step 1:** `just deploy raider`, then `tailscale debug prefs | grep OperatorUser` shows `arosenfeld`.
- [ ] **Step 2:** `just pantheon::panel-run tailscale` (the stock panel only picks up the new plugin at next login).
- [ ] **Step 3:** As the user, PATCH `{"ExitNodeIDSet":true,"ExitNodeID":"nbaJt4JzNB21CNTRL"}` (the popover's exact request): within a second the log shows `Tailscale: Running, exit node basestar`, `curl -s ifconfig.me` prints `168.138.71.109`; screenshot the popover and the panel icon.
- [ ] **Step 4:** PATCH `{"ExitNodeIDSet":true,"ExitNodeID":""}`, then switch off and on with `WantRunning`; screenshot the Off state; `systemctl --failed` clean; restore the stock panel.
