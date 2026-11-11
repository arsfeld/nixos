//! Which environment turns the voice on. Kept apart from `main` so it can be tested.

/// Everything the voice needs, read from the environment.
pub struct VoiceSettings {
    pub stt_url: String,
    pub tts_url: String,
    pub hermes_url: String,
    /// The contents of `BRIDGE_HERMES_KEY_FILE`, trimmed. Never print it.
    pub hermes_key: String,
    pub session: String,
    pub reply_timeout_secs: u64,
}

pub enum VoiceEnv {
    /// At least one of the four required settings is unset or empty; they are named here.
    Off { missing: Vec<&'static str> },
    On(VoiceSettings),
}

const REQUIRED: [&str; 4] = ["BRIDGE_STT_URL", "BRIDGE_TTS_URL", "BRIDGE_HERMES_URL", "BRIDGE_HERMES_KEY_FILE"];

/// Voice is on only when all four of `BRIDGE_STT_URL`, `BRIDGE_TTS_URL`, `BRIDGE_HERMES_URL` and
/// `BRIDGE_HERMES_KEY_FILE` are set. When they are, an unreadable or empty key file is an error
/// (the message names the variable and path, never the key).
pub fn voice_settings_from_env(get: impl Fn(&str) -> Option<String>) -> Result<VoiceEnv, String> {
    let set = |name: &str| get(name).map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
    let missing: Vec<&'static str> = REQUIRED.into_iter().filter(|n| set(n).is_none()).collect();
    if !missing.is_empty() {
        return Ok(VoiceEnv::Off { missing });
    }
    let path = set("BRIDGE_HERMES_KEY_FILE").expect("checked above");
    let key = std::fs::read_to_string(&path)
        .map_err(|e| format!("BRIDGE_HERMES_KEY_FILE: cannot read {path}: {e}"))?
        .trim()
        .to_string();
    if key.is_empty() {
        return Err(format!("BRIDGE_HERMES_KEY_FILE: {path} is empty"));
    }
    Ok(VoiceEnv::On(VoiceSettings {
        stt_url: set("BRIDGE_STT_URL").expect("checked above"),
        tts_url: set("BRIDGE_TTS_URL").expect("checked above"),
        hermes_url: set("BRIDGE_HERMES_URL").expect("checked above"),
        hermes_key: key,
        session: set("BRIDGE_HERMES_SESSION").unwrap_or_else(|| "creature".into()),
        reply_timeout_secs: set("BRIDGE_REPLY_TIMEOUT_SECS").and_then(|v| v.parse().ok()).unwrap_or(60),
    }))
}

/// The MCP endpoint's settings.
pub struct McpSettings {
    pub listen: String,
    /// The contents of `BRIDGE_MCP_TOKEN_FILE`, trimmed. Never print it.
    pub token: Option<String>,
}

/// The MCP endpoint is on only when `BRIDGE_MCP_LISTEN` is set. `BRIDGE_MCP_TOKEN_FILE`, when set,
/// must be readable and non-empty (the message names the variable and path, never the token).
pub fn mcp_settings_from_env(get: impl Fn(&str) -> Option<String>) -> Result<Option<McpSettings>, String> {
    let set = |name: &str| get(name).map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
    let Some(listen) = set("BRIDGE_MCP_LISTEN") else {
        return Ok(None);
    };
    let token = match set("BRIDGE_MCP_TOKEN_FILE") {
        None => None,
        Some(path) => {
            let t = std::fs::read_to_string(&path)
                .map_err(|e| format!("BRIDGE_MCP_TOKEN_FILE: cannot read {path}: {e}"))?
                .trim()
                .to_string();
            if t.is_empty() {
                return Err(format!("BRIDGE_MCP_TOKEN_FILE: {path} is empty"));
            }
            Some(t)
        }
    };
    Ok(Some(McpSettings { listen, token }))
}

/// Home Assistant, for the weather forecast tool.
pub struct HaSettings {
    pub url: String,
    /// The contents of `BRIDGE_HA_TOKEN_FILE`, trimmed. Never print it.
    pub token: String,
    pub weather_entity: String,
}

/// Home Assistant is used only when both `BRIDGE_HA_URL` and `BRIDGE_HA_TOKEN_FILE` are set; the
/// token file must then be readable and non-empty (the message names the variable and path, never
/// the token). `BRIDGE_HA_WEATHER_ENTITY` defaults to `weather.forecast_home`.
pub fn ha_settings_from_env(get: impl Fn(&str) -> Option<String>) -> Result<Option<HaSettings>, String> {
    let set = |name: &str| get(name).map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
    let (Some(url), Some(path)) = (set("BRIDGE_HA_URL"), set("BRIDGE_HA_TOKEN_FILE")) else {
        return Ok(None);
    };
    let token = std::fs::read_to_string(&path)
        .map_err(|e| format!("BRIDGE_HA_TOKEN_FILE: cannot read {path}: {e}"))?
        .trim()
        .to_string();
    if token.is_empty() {
        return Err(format!("BRIDGE_HA_TOKEN_FILE: {path} is empty"));
    }
    Ok(Some(HaSettings {
        url,
        token,
        weather_entity: set("BRIDGE_HA_WEATHER_ENTITY").unwrap_or_else(|| "weather.forecast_home".into()),
    }))
}
