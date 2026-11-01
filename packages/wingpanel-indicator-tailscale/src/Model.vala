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
         * Folds one IPN bus Notify into state. A top-level member the Notify
         * lacks (State, Prefs) leaves that part of state alone, but a Prefs
         * without ExitNodeID resets exit_node_id to "" (tailscaled always sends
         * ExitNodeID inside Prefs). Notifications are held until every field is
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

            // Vala cannot append to a public array field, so build locally.
            string[] lines = {};
            var health = array_member (root, "Health");
            if (health != null) {
                foreach (unowned Json.Node node in health.get_elements ()) {
                    if (node.get_value_type () == typeof (string)) {
                        lines += node.get_string ();
                    }
                }
            }
            status.health = lines;

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
            ExitNode[] sorted = {};
            foreach (var node in candidates) {
                sorted += node;
            }
            status.exit_nodes = sorted;
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

        /* Whether some candidate has this id. */
        public bool has_exit_node (string id, ExitNode[] nodes) {
            foreach (var node in nodes) {
                if (node.id == id) {
                    return true;
                }
            }
            return false;
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
