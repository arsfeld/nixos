//! Which environment turns the voice on.

use std::collections::HashMap;

use claude_board_bridge::config::{VoiceEnv, voice_settings_from_env};

const NAMES: [&str; 4] = ["BRIDGE_STT_URL", "BRIDGE_TTS_URL", "BRIDGE_HERMES_URL", "BRIDGE_HERMES_KEY_FILE"];

fn env(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let m: HashMap<String, String> = vars.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    move |k| m.get(k).cloned()
}

fn key_file(name: &str, content: &str) -> String {
    let p = std::env::temp_dir().join(format!("cbb-{}-{name}", std::process::id()));
    std::fs::write(&p, content).unwrap();
    p.to_str().unwrap().to_string()
}

fn all(key: &str) -> Vec<(&'static str, String)> {
    vec![
        (NAMES[0], "http://stt".into()),
        (NAMES[1], "http://tts".into()),
        (NAMES[2], "http://hermes".into()),
        (NAMES[3], key.into()),
    ]
}

fn run(vars: &[(&str, String)]) -> Result<VoiceEnv, String> {
    let v: Vec<(&str, &str)> = vars.iter().map(|(k, v)| (*k, v.as_str())).collect();
    voice_settings_from_env(env(&v))
}

#[test]
fn voice_is_off_when_any_setting_is_missing() {
    let key = key_file("off", "secret\n");
    for (i, name) in NAMES.iter().enumerate() {
        let mut vars = all(&key);
        vars.remove(i);
        match run(&vars).unwrap() {
            VoiceEnv::Off { missing } => assert_eq!(missing, vec![*name]),
            VoiceEnv::On(_) => panic!("voice on without {name}"),
        }
    }
    // Empty counts as unset.
    let mut vars = all(&key);
    vars[0].1 = "  ".into();
    assert!(matches!(run(&vars).unwrap(), VoiceEnv::Off { .. }));
}

#[test]
fn voice_is_on_when_all_four_are_set() {
    let key = key_file("on", "secret\n");
    let mut vars = all(&key);
    vars.push(("BRIDGE_REPLY_TIMEOUT_SECS", "7".into()));
    match run(&vars).unwrap() {
        VoiceEnv::On(s) => {
            assert_eq!(s.stt_url, "http://stt");
            assert_eq!(s.tts_url, "http://tts");
            assert_eq!(s.hermes_url, "http://hermes");
            assert_eq!(s.hermes_key, "secret");
            assert_eq!(s.session, "creature");
            assert_eq!(s.reply_timeout_secs, 7);
        }
        VoiceEnv::Off { missing } => panic!("off, missing {missing:?}"),
    }
}

#[test]
fn unreadable_or_empty_key_file_is_an_error() {
    let gone = std::env::temp_dir().join(format!("cbb-{}-does-not-exist", std::process::id()));
    let e = run(&all(gone.to_str().unwrap())).err().expect("unreadable");
    assert!(e.contains("BRIDGE_HERMES_KEY_FILE"), "{e}");
    let empty = key_file("empty", " \n");
    let e = run(&all(&empty)).err().expect("empty");
    assert!(e.contains("BRIDGE_HERMES_KEY_FILE") && e.contains("empty"), "{e}");
}

#[test]
fn mcp_off_without_listen() {
    use claude_board_bridge::config::mcp_settings_from_env;
    assert!(mcp_settings_from_env(env(&[])).unwrap().is_none());
    assert!(mcp_settings_from_env(env(&[("BRIDGE_MCP_LISTEN", "  ")])).unwrap().is_none());
}

#[test]
fn mcp_listen_without_token_file_has_no_token() {
    use claude_board_bridge::config::mcp_settings_from_env;
    let s = mcp_settings_from_env(env(&[("BRIDGE_MCP_LISTEN", "127.0.0.1:8591")])).unwrap().unwrap();
    assert_eq!(s.listen, "127.0.0.1:8591");
    assert!(s.token.is_none());
}

#[test]
fn mcp_token_file_is_read_and_trimmed() {
    use claude_board_bridge::config::mcp_settings_from_env;
    let p = key_file("mcp-ok", "tok\n");
    let s = mcp_settings_from_env(env(&[("BRIDGE_MCP_LISTEN", "127.0.0.1:1"), ("BRIDGE_MCP_TOKEN_FILE", &p)])).unwrap().unwrap();
    assert_eq!(s.token.as_deref(), Some("tok"));
}

#[test]
fn mcp_token_file_set_but_empty_is_an_error() {
    use claude_board_bridge::config::mcp_settings_from_env;
    let p = key_file("mcp-empty", "\n");
    let e = mcp_settings_from_env(env(&[("BRIDGE_MCP_LISTEN", "127.0.0.1:1"), ("BRIDGE_MCP_TOKEN_FILE", &p)])).err().unwrap();
    assert!(e.contains("BRIDGE_MCP_TOKEN_FILE") && e.contains(&p));
}

#[test]
fn mcp_token_file_unreadable_is_an_error() {
    use claude_board_bridge::config::mcp_settings_from_env;
    let e = mcp_settings_from_env(env(&[("BRIDGE_MCP_LISTEN", "127.0.0.1:1"), ("BRIDGE_MCP_TOKEN_FILE", "/nonexistent/tok")])).err().unwrap();
    assert!(e.contains("BRIDGE_MCP_TOKEN_FILE") && e.contains("/nonexistent/tok"));
}
