/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * AppCenter's installs, updates and removals in progress, from the
 * JobChanged signal and GetJobs method that the local AppCenter patch adds
 * (modules/constellation/pantheon-dock/appcenter/progress.patch). Plain
 * GDBus rather than a proxy interface, so upstream's AppCenterDBus stays
 * untouched and a malformed message can be rejected instead of crashing.
 */

public class Dock.AppCenterJobs : Object {
    private const string NAME = "io.elementary.appcenter";
    private const string PATH = "/io/elementary/appcenter";
    private const string IFACE = "io.elementary.appcenter";
    private const string JOB_TYPE = "(ssssud)";

    public enum State { IDLE, INSTALLING, UPDATING, REMOVING }

    public class Job : Object {
        public string component_id;
        public string desktop_id;
        public string name;
        public string icon;
        public State state;
        public double progress;

        public Job (string component_id, string desktop_id, string name, string icon, State state, double progress) {
            this.component_id = component_id;
            this.desktop_id = desktop_id;
            this.name = name;
            this.icon = icon;
            this.state = state;
            this.progress = progress;
        }

        public string status_text () {
            switch (state) {
                case INSTALLING: return _("Installing");
                case UPDATING: return _("Updating");
                case REMOVING: return _("Removing");
                default: return "";
            }
        }

        public static Job? from_variant (Variant value) {
            if (!value.is_of_type (new VariantType (JOB_TYPE))) {
                warning ("Ignoring malformed AppCenter job: %s", value.print (true));
                return null;
            }
            string component_id, desktop_id, name, icon;
            uint state;
            double progress;
            value.get (JOB_TYPE, out component_id, out desktop_id, out name, out icon, out state, out progress);
            if (state > State.REMOVING) {
                warning ("Ignoring malformed AppCenter job: state %u", state);
                return null;
            }
            return new Job (component_id, desktop_id, name, icon, (State) state, progress);
        }
    }

    private static AppCenterJobs? instance;
    public static unowned AppCenterJobs get_default () {
        if (instance == null) {
            instance = new AppCenterJobs ();
        }
        return instance;
    }

    /* A job started, moved or ended (state IDLE). */
    public signal void changed (Job job);

    public uint count { get { return jobs.size (); } }

    // By component id: a runtime update has no desktop id.
    private HashTable<string, Job> jobs = new HashTable<string, Job> (str_hash, str_equal);
    private bool started = false;
    private DBusConnection? connection;
    private uint subscription = 0;

    public GenericArray<Job> get_all () {
        var all = new GenericArray<Job> ();
        jobs.foreach ((id, job) => all.add (job));
        return all;
    }

    public Job? for_desktop_id (string desktop_id) {
        return jobs.find ((id, job) => job.desktop_id == desktop_id);
    }

    public double mean_progress () {
        if (jobs.size () == 0) {
            return -1;
        }
        double sum = 0;
        jobs.foreach ((id, job) => sum += job.progress);
        return sum / jobs.size ();
    }

    public void apply (Job job) {
        if (job.state == IDLE) {
            jobs.remove (job.component_id);
        } else {
            jobs[job.component_id] = job;
        }
        changed (job);
    }

    /* Ends every job: AppCenter went away mid-job, and nothing else will. */
    public void clear () {
        foreach (var job in get_all ()) {
            apply (new Job (job.component_id, job.desktop_id, job.name, job.icon, IDLE, 1));
        }
    }

    /* Follows AppCenter on the session bus. Idempotent; the unit tests never call it. */
    public void start () {
        if (started) {
            return;
        }
        started = true;
        start_fake_job ();
        // No AUTO_START: AppCenter's own --silent daemon is already running in a
        // Pantheon session, and the dock must not be what starts it.
        Bus.watch_name (BusType.SESSION, NAME, BusNameWatcherFlags.NONE, on_appeared, on_vanished);
    }

    private void on_appeared (DBusConnection connection, string name, string owner) {
        this.connection = connection;
        // Matched on the unique name: GDBus compares a signal's sender to the
        // unique name the message carries, not to the well-known one.
        subscription = connection.signal_subscribe (owner, IFACE, "JobChanged", PATH, null, NONE, on_job_signal);
        connection.call.begin (owner, PATH, IFACE, "GetJobs", null, new VariantType ("(a" + JOB_TYPE + ")"),
                               NONE, -1, null, on_get_jobs);
    }

    private void on_get_jobs (Object? obj, AsyncResult res) {
        try {
            var reply = ((DBusConnection) obj).call.end (res);
            var list = reply.get_child_value (0);
            for (size_t i = 0; i < list.n_children (); i++) {
                var job = Job.from_variant (list.get_child_value (i));
                if (job != null) {
                    apply (job);
                }
            }
        } catch (Error e) {
            // An AppCenter without the local patch: no progress, nothing else changes.
            debug ("AppCenter has no GetJobs (%s); showing no app progress", e.message);
        }
    }

    private void on_vanished (DBusConnection? connection, string name) {
        if (this.connection != null && subscription != 0) {
            this.connection.signal_unsubscribe (subscription);
        }
        subscription = 0;
        this.connection = null;
        clear ();
    }

    private void on_job_signal (DBusConnection connection, string? sender, string path, string iface,
                                string signal_name, Variant parameters) {
        var job = Job.from_variant (parameters);
        if (job != null) {
            apply (job);
        }
    }

    // Test hook: DOCK_STACKS_FAKE_JOB=<desktop-id>:<state>:<progress> injects one
    // job at startup, without AppCenter. An unknown desktop id is a new install.
    private void start_fake_job () {
        var fake = Environment.get_variable ("DOCK_STACKS_FAKE_JOB");
        if (fake == null) {
            return;
        }
        var parts = fake.split (":");
        if (parts.length != 3) {
            warning ("DOCK_STACKS_FAKE_JOB: expected <desktop-id>:<state>:<progress>, got '%s'", fake);
            return;
        }
        var name = parts[0].has_suffix (".desktop") ? parts[0].substring (0, parts[0].length - 8) : parts[0];
        apply (new Job ("fake." + parts[0], parts[0], name, "", (State) int.parse (parts[1]), double.parse (parts[2])));
    }
}
