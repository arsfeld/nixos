//! One mail per settled change: the deploy, if there was one, and every unit
//! that failed since the last report and is still failed.
//!
//! Fed by two producers. `email@<unit>` appends a line to
//! `/run/unit-failures/<unit>` each time that unit fails; the deploy
//! activation snippet writes the generation it replaced to
//! `/run/deploy-mail/from`. Both then queue this service. Starting it while it
//! already runs merges into the running job, so it loops until nothing
//! reportable is left after a pass.
//!
//! Mail about steady state, not transitions. A deploy's switch-to-configuration
//! stops and restarts many units at once, and plenty fail along the way (a
//! dependency stopped under them, a restart racing its socket) before its start
//! phase brings them back. Boot is the same. So each pass first waits until no
//! activation runs and boot is over, then a minute for Restart= units.
//!
//! Usage: system-report <send-email-event> <from> <to>

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// A unit is reported at most once an hour.
const COOLDOWN_SECS: u64 = 3600;
const LOG_LINES: &str = "40";
/// send-email-event takes the body as one argv string, and Linux caps a
/// single argument at 128 KiB.
const BODY_MAX: usize = 100_000;
const MAX_WAIT: Duration = Duration::from_secs(1800);
const POLL: Duration = Duration::from_secs(5);
const GRACE: Duration = Duration::from_secs(60);

struct Paths {
    spool: PathBuf,
    sent: PathBuf,
    deploy: PathBuf,
}

impl Paths {
    fn new(spool: &Path, deploy: &Path) -> Self {
        Paths {
            spool: spool.to_owned(),
            sent: spool.join(".sent"),
            deploy: deploy.to_owned(),
        }
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn output(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

fn succeeds(cmd: &str, args: &[&str]) -> bool {
    Command::new(cmd)
        .args(args)
        .output()
        .is_ok_and(|o| o.status.success())
}

/// Never take /run/nixos/switch-to-configuration.lock to detect an
/// activation: switch-to-configuration grabs it non-blocking and aborts if
/// anyone holds it, even briefly.
fn activating() -> bool {
    succeeds(
        "systemctl",
        &[
            "is-active",
            "--quiet",
            "nixos-rebuild-switch-to-configuration.service",
        ],
    ) || succeeds("pgrep", &["-f", "bin/switch-to-configuration"])
        || output("systemctl", &["is-system-running"]).trim() == "starting"
}

fn wait_for_steady_state() {
    let mut waited = Duration::ZERO;
    while waited < MAX_WAIT && activating() {
        sleep(POLL);
        waited += POLL;
    }
    sleep(GRACE);
}

fn parse_failed(list_units: &str) -> Vec<String> {
    list_units
        .lines()
        .filter_map(|l| l.split_whitespace().next())
        .map(str::to_owned)
        .collect()
}

fn cooling(p: &Paths, unit: &str, now: u64) -> bool {
    fs::read_to_string(p.sent.join(unit))
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .is_some_and(|t| now.saturating_sub(t) < COOLDOWN_SECS)
}

fn take_deploy(p: &Paths) -> Option<String> {
    let old = fs::read_to_string(&p.deploy).ok()?;
    let _ = fs::remove_file(&p.deploy);
    let old = old.trim();
    Some(if old.is_empty() {
        "unknown".into()
    } else {
        old.into()
    })
}

fn spooled(p: &Paths) -> Vec<(String, PathBuf)> {
    let Ok(dir) = fs::read_dir(&p.spool) else {
        return Vec::new();
    };
    dir.flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path()))
        .collect()
}

/// Spooled units still failed and out of cooldown, with their failure
/// counts. A unit that recovered is dropped. One still cooling keeps its
/// spool file, so its count carries into its next report.
fn take_failures(p: &Paths, failed_now: &BTreeSet<String>, now: u64) -> BTreeMap<String, usize> {
    let mut report = BTreeMap::new();
    for (unit, path) in spooled(p) {
        if !failed_now.contains(&unit) {
            let _ = fs::remove_file(&path);
        } else if !cooling(p, &unit, now) {
            let count = fs::read_to_string(&path).map_or(0, |s| s.lines().count());
            report.insert(unit, count.max(1));
            let _ = fs::remove_file(&path);
        }
    }
    report
}

fn more_to_report(p: &Paths, now: u64) -> bool {
    p.deploy.exists() || spooled(p).iter().any(|(u, _)| !cooling(p, u, now))
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn pre(s: &str) -> String {
    format!("<pre>{}</pre>", escape(s))
}

/// send-email-event makes the subject `[<host>] <event> <ISO date>`; this
/// keeps the event part short enough for a mail client's subject column.
const SUBJECT_MAX: usize = 80;

/// As many of `units` as fit in `budget` characters, then `+N more`. The
/// first name is always kept, so the subject never says only a count.
fn name_list(units: &[&str], budget: usize) -> String {
    let render = |k: usize| {
        let mut s = units[..k].join(", ");
        if k < units.len() {
            s += &format!(", +{} more", units.len() - k);
        }
        s
    };
    (2..=units.len())
        .rev()
        .map(render)
        .find(|s| s.len() <= budget)
        .unwrap_or_else(|| render(units.len().min(1)))
}

/// `units` is what the mail is about: every failed unit after a deploy, the
/// newly reported ones otherwise.
fn subject(deploy: bool, units: &[&str]) -> String {
    let prefix = if deploy { "deployed, " } else { "" };
    match units {
        [] => "deployed".into(),
        [one] => format!("{prefix}{one} failed"),
        many => {
            let head = format!("{prefix}{} failed: ", many.len());
            let names = name_list(many, SUBJECT_MAX.saturating_sub(head.len()));
            format!("{head}{names}")
        }
    }
}

struct Deploy {
    from: String,
    to: String,
    version: String,
}

/// `section` renders one unit; it is a parameter so tests need no systemd.
fn body(
    deploy: Option<&Deploy>,
    report: &BTreeMap<String, usize>,
    failed_now: &[String],
    section: impl Fn(&str, usize) -> String,
) -> String {
    let mut out = String::new();
    if let Some(d) = deploy {
        let failed = if failed_now.is_empty() {
            "none".into()
        } else {
            failed_now.join(", ")
        };
        out += &pre(&format!(
            "From: {}\nTo:   {}\nNixOS {}\n\nFailed units: {failed}",
            d.from.trim_start_matches("/nix/store/"),
            d.to.trim_start_matches("/nix/store/"),
            d.version,
        ));
    } else {
        let others: Vec<&str> = failed_now
            .iter()
            .filter(|u| !report.contains_key(*u))
            .map(String::as_str)
            .collect();
        if !others.is_empty() {
            out += &pre(&format!("Also failed now: {}", others.join(", ")));
        }
    }
    let units: Vec<(&String, &usize)> = report.iter().collect();
    for (i, (unit, count)) in units.iter().enumerate() {
        let s = section(unit, **count);
        if out.len() + s.len() > BODY_MAX {
            let rest: Vec<&str> = units[i..].iter().map(|(u, _)| u.as_str()).collect();
            out += &pre(&format!("Truncated; not shown: {}", rest.join(", ")));
            break;
        }
        out += &s;
    }
    out
}

fn unit_section(unit: &str, count: usize) -> String {
    let status = output(
        "systemctl",
        &["status", "--full", "--no-pager", "--lines=0", unit],
    );
    let logs = output(
        "journalctl",
        &["-u", unit, "-b", "--no-pager", "-n", LOG_LINES],
    );
    let times = if count == 1 {
        "once".into()
    } else {
        format!("{count} times")
    };
    format!(
        "<h3>{}</h3><p>Failed {times} since the last report.</p>{}{}",
        escape(unit),
        pre(&status),
        pre(&logs)
    )
}

fn current_deploy(from: String) -> Deploy {
    let to = fs::canonicalize("/run/current-system")
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "?".into());
    let version = fs::read_to_string(Path::new(&to).join("nixos-version"))
        .map(|s| s.trim().to_owned())
        .unwrap_or_else(|_| "?".into());
    Deploy { from, to, version }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [send, from, to] = args.as_slice() else {
        eprintln!("usage: system-report <send-email-event> <from> <to>");
        return ExitCode::from(2);
    };
    let p = Paths::new(
        Path::new("/run/unit-failures"),
        Path::new("/run/deploy-mail/from"),
    );

    loop {
        wait_for_steady_state();
        let failed_now = parse_failed(&output(
            "systemctl",
            &[
                "list-units",
                "--state=failed",
                "--plain",
                "--no-legend",
                "--no-pager",
            ],
        ));
        let failed_set: BTreeSet<String> = failed_now.iter().cloned().collect();
        let deploy = take_deploy(&p).map(current_deploy);
        let report = take_failures(&p, &failed_set, now());

        if deploy.is_some() || !report.is_empty() {
            let units: Vec<&str> = if deploy.is_some() {
                failed_now.iter().map(String::as_str).collect()
            } else {
                report.keys().map(String::as_str).collect()
            };
            let event = subject(deploy.is_some(), &units);
            let text = body(deploy.as_ref(), &report, &failed_now, unit_section);
            let sent = Command::new(send)
                .args(["--email-from", from, "--email-to", to, &event, &text])
                .status()
                .is_ok_and(|s| s.success());
            if !sent {
                eprintln!("send-email-event failed for: {event}");
                return ExitCode::FAILURE;
            }
            let _ = fs::create_dir_all(&p.sent);
            let stamp = now().to_string();
            for unit in report.keys() {
                let _ = fs::write(p.sent.join(unit), &stamp);
            }
        }
        if !more_to_report(&p, now()) {
            return ExitCode::SUCCESS;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> Paths {
        let dir = std::env::temp_dir().join(format!("system-report-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("spool")).unwrap();
        Paths::new(&dir.join("spool"), &dir.join("from"))
    }

    fn failed(units: &[&str]) -> BTreeSet<String> {
        units.iter().map(|u| u.to_string()).collect()
    }

    #[test]
    fn parses_failed_units() {
        let out = "foo.service loaded failed failed Foo\nbar.timer loaded failed failed Bar\n";
        assert_eq!(parse_failed(out), ["foo.service", "bar.timer"]);
        assert!(parse_failed("").is_empty());
    }

    #[test]
    fn counts_failures_and_drops_recovered_units() {
        let p = scratch("count");
        fs::write(p.spool.join("foo.service"), "\n\n\n").unwrap();
        fs::write(p.spool.join("bar.service"), "\n").unwrap();
        let report = take_failures(&p, &failed(&["foo.service"]), 10_000);
        assert_eq!(
            report.into_iter().collect::<Vec<_>>(),
            [("foo.service".into(), 3)]
        );
        assert!(spooled(&p).is_empty(), "both spool files are consumed");
    }

    #[test]
    fn cooling_unit_stays_spooled_and_does_not_loop() {
        let p = scratch("cool");
        fs::create_dir_all(&p.sent).unwrap();
        fs::write(p.sent.join("foo.service"), "10000").unwrap();
        fs::write(p.spool.join("foo.service"), "\n").unwrap();
        let now = 10_000 + COOLDOWN_SECS - 1;
        assert!(take_failures(&p, &failed(&["foo.service"]), now).is_empty());
        assert_eq!(spooled(&p).len(), 1);
        assert!(!more_to_report(&p, now));
        assert!(more_to_report(&p, now + 1));
        assert_eq!(
            take_failures(&p, &failed(&["foo.service"]), now + 1).len(),
            1
        );
    }

    #[test]
    fn deploy_marker_is_consumed_once() {
        let p = scratch("deploy");
        fs::write(&p.deploy, "/nix/store/abc-old\n").unwrap();
        assert!(more_to_report(&p, 0));
        assert_eq!(take_deploy(&p).as_deref(), Some("/nix/store/abc-old"));
        assert_eq!(take_deploy(&p), None);
        assert!(!more_to_report(&p, 0));
    }

    #[test]
    fn subjects() {
        assert_eq!(subject(true, &[]), "deployed");
        assert_eq!(subject(true, &["a.service"]), "deployed, a.service failed");
        assert_eq!(
            subject(true, &["a.service", "b.timer"]),
            "deployed, 2 failed: a.service, b.timer"
        );
        assert_eq!(subject(false, &["foo.service"]), "foo.service failed");
        assert_eq!(
            subject(false, &["a.service", "b.service"]),
            "2 failed: a.service, b.service"
        );
    }

    #[test]
    fn subject_fits_as_many_names_as_it_can() {
        let units: Vec<String> = (0..20).map(|i| format!("unit-{i:02}.service")).collect();
        let units: Vec<&str> = units.iter().map(String::as_str).collect();
        let s = subject(false, &units);
        assert!(s.len() <= SUBJECT_MAX, "{s}");
        assert!(s.starts_with("20 failed: unit-00.service, unit-01.service"), "{s}");
        assert!(s.ends_with(" more"), "{s}");
        let shown = s.matches(".service").count();
        assert!(s.ends_with(&format!("+{} more", 20 - shown)), "{s}");
    }

    #[test]
    fn subject_keeps_one_name_however_long() {
        let long = "x".repeat(SUBJECT_MAX * 2);
        let s = subject(false, &[&long, "b.service"]);
        assert_eq!(s, format!("2 failed: {long}, +1 more"));
    }

    #[test]
    fn body_lists_deploy_and_escapes() {
        let d = Deploy {
            from: "/nix/store/a-old".into(),
            to: "/nix/store/b-new".into(),
            version: "26.05".into(),
        };
        let report = BTreeMap::from([("x<y>.service".to_string(), 2)]);
        let b = body(Some(&d), &report, &["x<y>.service".into()], |u, n| {
            format!("[{}:{n}]", escape(u))
        });
        assert!(b.contains("From: a-old\nTo:   b-new\nNixOS 26.05"));
        assert!(b.contains("Failed units: x&lt;y&gt;.service"));
        assert!(b.contains("[x&lt;y&gt;.service:2]"));
    }

    #[test]
    fn body_names_other_failed_units_without_deploy() {
        let report = BTreeMap::from([("a.service".to_string(), 1)]);
        let b = body(
            None,
            &report,
            &["a.service".into(), "old.service".into()],
            |_, _| String::new(),
        );
        assert!(b.contains("Also failed now: old.service"));
    }

    #[test]
    fn body_truncates_and_names_the_rest() {
        let report: BTreeMap<String, usize> =
            (0..5).map(|i| (format!("u{i}.service"), 1)).collect();
        let b = body(None, &report, &[], |_, _| "x".repeat(BODY_MAX / 3));
        assert!(b.contains("Truncated; not shown: u3.service, u4.service"));
        assert!(b.len() < BODY_MAX + 200);
    }
}
