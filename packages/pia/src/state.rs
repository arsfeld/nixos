//! `/var/lib/pia/state.json`: what `connect` hands to `portforward`, and the
//! port-forward signature cache. Field names match the file the Python version wrote.

use std::path::Path;

use std::os::unix::fs::PermissionsExt;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Serialize, Deserialize, Default, Debug, Clone, PartialEq)]
pub struct State {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pf_gateway: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pf_hostname: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dns_servers: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub applied_port: Option<u16>,
    /// Fields this version does not know, kept so the file round-trips.
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl State {
    pub fn is_empty(&self) -> bool {
        *self == State::default()
    }
}

/// Reads the state file; a missing file is an empty state.
pub fn load(path: &Path) -> Result<State> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).with_context(|| format!("parsing {}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(State::default()),
        Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
    }
}

/// Writes `<path>.tmp`, sets its mode, then renames it over `path`.
pub fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = Path::new(&tmp);
    std::fs::write(tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::set_permissions(tmp, std::fs::Permissions::from_mode(mode))?;
    std::fs::rename(tmp, path).with_context(|| format!("replacing {}", path.display()))
}

/// Saves the state, readable by root only.
pub fn save(path: &Path, s: &State) -> Result<()> {
    write_atomic(path, &serde_json::to_vec(s)?, 0o600)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(dir: &tempfile::TempDir, json: &str) -> std::path::PathBuf {
        let p = dir.path().join("state.json");
        std::fs::write(&p, json).unwrap();
        p
    }

    #[test]
    fn loads_python_written_state() {
        let dir = tempfile::tempdir().unwrap();
        let j = r#"{"token":"t","pf_gateway":"10.1.2.1","pf_hostname":"montreal421","dns_servers":["10.0.0.243"],
                   "payload":"cGF5","signature":"sig","expires_at":"2027-01-10T12:00:00.123456789Z","port":51234,"applied_port":51234}"#;
        let s = load(&file(&dir, j)).unwrap();
        assert_eq!(s.port, Some(51234));
        assert_eq!(s.applied_port, Some(51234));
        assert_eq!(s.dns_servers, Some(vec!["10.0.0.243".to_string()]));
        assert!(s.extra.is_empty());
    }

    #[test]
    fn missing_file_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load(&dir.path().join("nope.json")).unwrap().is_empty());
    }

    #[test]
    fn unknown_fields_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let p = file(&dir, r#"{"future":1,"token":"t"}"#);
        save(&p, &load(&p).unwrap()).unwrap();
        let s = load(&p).unwrap();
        assert_eq!(s.extra["future"], 1);
        assert_eq!(s.token.as_deref(), Some("t"));
        assert!(!s.is_empty());
    }

    #[test]
    fn absent_applied_port_is_none() {
        let dir = tempfile::tempdir().unwrap();
        let p = file(&dir, r#"{"token":"t"}"#);
        let s = load(&p).unwrap();
        assert_eq!(s.applied_port, None);
        save(&p, &s).unwrap();
        assert!(!std::fs::read_to_string(&p).unwrap().contains("applied_port"));
    }

    #[test]
    fn save_is_0600_and_leaves_no_tmp() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("state.json");
        save(&p, &State { token: Some("t".into()), ..Default::default() }).unwrap();
        assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(!dir.path().join("state.json.tmp").exists());
    }
}
