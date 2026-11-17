//! Running the external tools (wg, ip, iptables, systemctl, the consumer hook).

use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

fn name(prog: &Path) -> String {
    prog.file_name().map_or_else(|| prog.display().to_string(), |n| n.to_string_lossy().into_owned())
}

/// Runs `prog args`, failing with the program's name and stderr on a non-zero exit.
pub fn run(prog: &Path, args: &[&str]) -> Result<()> {
    stdout(prog, args, None).map(|_| ())
}

/// Runs `prog args` with optional stdin and returns its trimmed stdout.
pub fn stdout(prog: &Path, args: &[&str], input: Option<&str>) -> Result<String> {
    let mut child = Command::new(prog)
        .args(args)
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("running {}", name(prog)))?;
    if let Some(input) = input {
        child.stdin.take().expect("stdin is piped").write_all(input.as_bytes())?;
    }
    let out = child.wait_with_output()?;
    if !out.status.success() {
        bail!("{} exited with {}: {}", name(prog), out.status, String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Runs `prog args` with stdout and stderr going to ours (the journal), failing on a
/// non-zero exit.
pub fn run_inherit(prog: &Path, args: &[&str]) -> Result<()> {
    let status = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .status()
        .with_context(|| format!("running {}", name(prog)))?;
    if !status.success() {
        bail!("{} exited with {status}", name(prog));
    }
    Ok(())
}

/// Like [`stdout`] without stdin, but kills `prog` and fails once `limit` has passed. Its
/// output is drained on threads while it runs, so a large answer (`tailscale status
/// --json` lists every peer) cannot fill the pipe and stall it into the deadline.
pub fn stdout_within(prog: &Path, args: &[&str], limit: Duration) -> Result<String> {
    let mut child = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("running {}", name(prog)))?;
    let drain = |mut r: Box<dyn Read + Send>| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = r.read_to_end(&mut buf);
            buf
        })
    };
    let out = drain(Box::new(child.stdout.take().expect("stdout is piped")));
    let err = drain(Box::new(child.stderr.take().expect("stderr is piped")));
    let deadline = Instant::now() + limit;
    let status = loop {
        if let Some(s) = child.try_wait()? {
            break s;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            // The readers are left to finish on their own: a grandchild holding the
            // pipe open must not turn the deadline back into a hang.
            bail!("{} timed out after {}s", name(prog), limit.as_secs());
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let out = out.join().unwrap_or_default();
    let err = err.join().unwrap_or_default();
    if !status.success() {
        bail!("{} exited with {status}: {}", name(prog), String::from_utf8_lossy(&err).trim());
    }
    Ok(String::from_utf8_lossy(&out).trim().to_string())
}

/// True when `prog args` exits 0 within `limit`. Output is discarded.
pub fn succeeds_within(prog: &Path, args: &[&str], limit: Duration) -> bool {
    stdout_within(prog, args, limit).is_ok()
}

/// True when `prog args` exits 0. Output is discarded.
pub fn succeeds(prog: &Path, args: &[&str]) -> bool {
    Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_inherit_reports_exit_status() {
        run_inherit(Path::new("/bin/sh"), &["-c", "exit 0"]).unwrap();
        let e = run_inherit(Path::new("/bin/sh"), &["-c", "exit 3"]).unwrap_err().to_string();
        assert!(e.contains("sh") && e.contains('3'), "{e}");
    }

    #[test]
    fn stdout_within_returns_output() {
        let sh = Path::new("/bin/sh");
        let lim = Duration::from_secs(5);
        assert_eq!(stdout_within(sh, &["-c", "echo hi"], lim).unwrap(), "hi");
        assert!(stdout_within(sh, &["-c", "echo no >&2; exit 2"], lim).unwrap_err().to_string().contains("no"));
        assert!(succeeds_within(sh, &["-c", "exit 0"], lim));
        assert!(!succeeds_within(sh, &["-c", "exit 1"], lim));
    }

    #[test]
    fn stdout_within_drains_large_output() {
        // More than a pipe buffer (64 KiB): must not stall until the deadline.
        let out = stdout_within(Path::new("/bin/sh"), &["-c", "printf '%0300000d' 0"], Duration::from_secs(5));
        assert_eq!(out.unwrap().len(), 300_000);
    }

    #[test]
    fn stdout_within_kills_at_the_deadline() {
        let t = Instant::now();
        let e = stdout_within(Path::new("/bin/sh"), &["-c", "while :; do :; done"], Duration::from_millis(300)).unwrap_err();
        assert!(e.to_string().contains("timed out"), "{e}");
        assert!(t.elapsed() < Duration::from_secs(5));
    }
}
