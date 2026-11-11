//! Running the external tools (wg, ip, iptables, systemctl, the consumer hook).

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

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
}
