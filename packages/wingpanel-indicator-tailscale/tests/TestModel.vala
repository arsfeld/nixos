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
