use claude_board_bridge::voice::session::SessionId;

fn tmp(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("cb-session-{}-{name}", std::process::id()));
    let _ = std::fs::remove_file(&d);
    d
}

#[test]
fn load_without_a_file_uses_the_base() {
    assert_eq!(SessionId::load("creature".into(), None).current(), "creature");
    assert_eq!(SessionId::load("creature".into(), Some(tmp("absent"))).current(), "creature");
}

#[test]
fn reset_mints_base_dash_seconds_and_writes_it() {
    let p = tmp("reset");
    let s = SessionId::load("creature".into(), Some(p.clone()));
    assert_eq!(s.reset(1794326900), "creature-1794326900");
    assert_eq!(s.current(), "creature-1794326900");
    assert_eq!(std::fs::read_to_string(&p).unwrap().trim(), "creature-1794326900");
}

#[test]
fn a_new_instance_reads_the_saved_id() {
    let p = tmp("reload");
    SessionId::load("creature".into(), Some(p.clone())).reset(42);
    assert_eq!(SessionId::load("creature".into(), Some(p)).current(), "creature-42");
}

#[test]
fn an_empty_or_blank_file_falls_back_to_the_base() {
    let p = tmp("blank");
    std::fs::write(&p, "  \n").unwrap();
    assert_eq!(SessionId::load("creature".into(), Some(p.clone())).current(), "creature");
    std::fs::write(&p, "").unwrap();
    assert_eq!(SessionId::load("creature".into(), Some(p)).current(), "creature");
}

#[test]
fn an_unwritable_path_still_resets_in_memory() {
    let p = std::env::temp_dir().join("cb-no-such-dir-xyz").join("s");
    let s = SessionId::load("creature".into(), Some(p));
    assert_eq!(s.reset(7), "creature-7");
    assert_eq!(s.current(), "creature-7");
}
