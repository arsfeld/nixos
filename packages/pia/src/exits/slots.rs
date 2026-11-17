//! An exit slot's choice: one region id per slot, kept in a file.

use super::regions::{id_for, Offered};
use anyhow::{Context, Result};
use std::path::Path;
use std::time::SystemTime;

#[derive(Debug, PartialEq)]
pub enum Action {
    Start,
    Restart,
    Stop,
}

#[derive(Debug, PartialEq)]
pub enum ChoiceError {
    UnknownSlot,
    UnknownOption,
    BadBody,
    Conflict,
}

/// The slot's region id and when it was written; absent or empty is Off.
pub fn read_region(path: &Path) -> Option<(String, SystemTime)> {
    let id = std::fs::read_to_string(path).ok()?.trim().to_string();
    if id.is_empty() {
        return None;
    }
    let mtime = std::fs::metadata(path).ok()?.modified().ok()?;
    Some((id, mtime))
}

pub fn choose(
    slot: u8,
    slots: u8,
    body: &str,
    offered: &[Offered],
    current: &[Option<String>],
) -> Result<(Option<String>, Action), ChoiceError> {
    if slot == 0 || slot > slots {
        return Err(ChoiceError::UnknownSlot);
    }
    let label = serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("option")?.as_str().map(str::to_string))
        .ok_or(ChoiceError::BadBody)?;
    let idx = usize::from(slot) - 1;
    let was_on = current.get(idx).is_some_and(|c| c.is_some());
    if label == "Off" {
        return Ok((None, Action::Stop));
    }
    let id = id_for(offered, &label).ok_or(ChoiceError::UnknownOption)?.id.clone();
    let taken = current
        .iter()
        .enumerate()
        .any(|(i, c)| i != idx && c.as_deref() == Some(id.as_str()));
    if taken {
        return Err(ChoiceError::Conflict);
    }
    Ok((Some(id), if was_on { Action::Restart } else { Action::Start }))
}

pub fn apply_region(path: &Path, region: Option<&str>) -> Result<()> {
    match region {
        Some(id) => {
            crate::state::write_atomic(path, id.as_bytes(), 0o644)?;
            // The kernel stamps files with a coarse clock that can lag `now`; stamp it exactly,
            // since the mtime is how a retry of the same region is told apart.
            std::fs::File::options()
                .write(true)
                .open(path)?
                .set_modified(SystemTime::now())
                .with_context(|| format!("stamping {}", path.display()))
        }
        None => match std::fs::remove_file(path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                Err(e).with_context(|| format!("removing {}", path.display()))
            }
            _ => Ok(()),
        },
    }
}

/// 1-based slots up to `slots` that hold a region.
pub fn slots_to_start(slots: u8, dir_files: &[Option<String>]) -> Vec<u8> {
    (1..=slots)
        .filter(|&n| dir_files.get(usize::from(n) - 1).is_some_and(|f| f.is_some()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn off() -> Vec<Offered> {
        ["br", "ca"]
            .iter()
            .map(|i| Offered { label: format!("L-{i}"), id: i.to_string(), country: "X".into() })
            .collect()
    }
    fn body(l: &str) -> String {
        format!("{{\"option\":\"{l}\"}}")
    }

    #[test]
    fn off_stops() {
        let r = choose(1, 2, &body("Off"), &off(), &[Some("br".into()), None]);
        assert_eq!(r, Ok((None, Action::Stop)));
    }
    #[test]
    fn region_on_off_slot_starts() {
        let r = choose(1, 2, &body("L-br"), &off(), &[None, None]);
        assert_eq!(r, Ok((Some("br".into()), Action::Start)));
    }
    #[test]
    fn region_on_running_slot_restarts() {
        let cur = [Some("br".into()), None];
        assert_eq!(choose(1, 2, &body("L-ca"), &off(), &cur), Ok((Some("ca".into()), Action::Restart)));
        assert_eq!(choose(1, 2, &body("L-br"), &off(), &cur), Ok((Some("br".into()), Action::Restart)));
    }
    #[test]
    fn same_region_in_other_slot_conflicts() {
        let cur = [Some("br".into()), None];
        assert_eq!(choose(2, 2, &body("L-br"), &off(), &cur), Err(ChoiceError::Conflict));
    }
    #[test]
    fn unknown_label_is_unknown_option() {
        assert_eq!(choose(1, 2, &body("Nope"), &off(), &[None, None]), Err(ChoiceError::UnknownOption));
    }
    #[test]
    fn slot_zero_and_above_count_unknown() {
        assert_eq!(choose(0, 2, &body("Off"), &off(), &[None, None]), Err(ChoiceError::UnknownSlot));
        assert_eq!(choose(3, 2, &body("Off"), &off(), &[None, None]), Err(ChoiceError::UnknownSlot));
    }
    #[test]
    fn malformed_body_is_bad_body() {
        for b in ["", "{}", "{\"option\":3}"] {
            assert_eq!(choose(1, 2, b, &off(), &[None, None]), Err(ChoiceError::BadBody), "{b}");
        }
    }
    #[test]
    fn apply_region_writes_and_removes() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("slot-1");
        assert!(read_region(&p).is_none());
        apply_region(&p, Some("br")).unwrap();
        assert_eq!(read_region(&p).unwrap().0, "br");
        apply_region(&p, None).unwrap();
        assert!(read_region(&p).is_none());
        apply_region(&p, None).unwrap();
    }
    #[test]
    fn rewrite_same_region_bumps_mtime() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("slot-1");
        apply_region(&p, Some("br")).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        let before = SystemTime::now();
        apply_region(&p, Some("br")).unwrap();
        assert!(read_region(&p).unwrap().1 >= before);
    }
    #[test]
    fn files_above_slot_count_ignored() {
        let f = [Some("a".to_string()), None, Some("c".to_string())];
        assert_eq!(slots_to_start(2, &f), vec![1]);
    }
}
