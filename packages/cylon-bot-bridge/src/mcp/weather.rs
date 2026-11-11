//! `weather_forecast`: the daily forecast from Home Assistant's weather entity, one line per day.
//! Home Assistant is loopback plain HTTP; its token is never logged or echoed.

use std::sync::Arc;
use std::time::Duration;

use futures_util::FutureExt;
use futures_util::future::BoxFuture;
use serde_json::{Value, json};

use super::{Tool, ToolDef, ToolOutcome};
use crate::config::HaSettings;
use crate::timers::TZ;

const MAX_DAYS: u64 = 5;
const DEFAULT_DAYS: u64 = 3;
const TIMEOUT: Duration = Duration::from_secs(10);
const UNAVAILABLE: &str = "The weather forecast is unavailable right now: Home Assistant did not answer.";

pub fn tools(ha: HaSettings) -> Vec<Arc<dyn Tool>> {
    vec![Arc::new(WeatherForecast::new(ha.url, ha.token, ha.weather_entity))]
}

pub struct WeatherForecast {
    url: String,
    token: String,
    entity: String,
    client: reqwest::Client,
}

impl WeatherForecast {
    pub fn new(url: String, token: String, entity: String) -> Self {
        let client = reqwest::Client::builder().timeout(TIMEOUT).build().expect("reqwest client");
        Self { url: url.trim_end_matches('/').to_string(), token, entity, client }
    }
}

impl Tool for WeatherForecast {
    fn def(&self) -> ToolDef {
        ToolDef {
            name: "weather_forecast",
            description: "The daily weather forecast for home (Toronto), one line per day starting today: \
                condition, high and low in degrees Celsius, and chance of rain.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "days": {"type": "integer", "minimum": 1, "maximum": MAX_DAYS, "description": "How many days, 1 to 5 (default 3)"},
                },
            }),
        }
    }

    fn call(&self, args: Value) -> BoxFuture<'static, ToolOutcome> {
        let days = match args.get("days").filter(|v| !v.is_null()) {
            None => DEFAULT_DAYS,
            Some(v) => match v.as_u64() {
                Some(d @ 1..=MAX_DAYS) => d,
                _ => return async { ToolOutcome::Error("days must be a whole number from 1 to 5.".into()) }.boxed(),
            },
        };
        let req = self
            .client
            .post(format!("{}/api/services/weather/get_forecasts?return_response", self.url))
            .bearer_auth(&self.token)
            .json(&json!({"entity_id": self.entity, "type": "daily"}));
        let entity = self.entity.clone();
        async move {
            let body: Value = match req.send().await {
                Ok(r) if r.status().is_success() => match r.json().await {
                    Ok(v) => v,
                    Err(_) => return ToolOutcome::Error(UNAVAILABLE.into()),
                },
                _ => return ToolOutcome::Error(UNAVAILABLE.into()),
            };
            let forecast = body["service_response"][entity.as_str()]["forecast"].as_array().cloned().unwrap_or_default();
            let lines: Vec<String> = forecast.iter().take(days as usize).filter_map(day_line).collect();
            if lines.is_empty() {
                return ToolOutcome::Error("No forecast available from Home Assistant.".into());
            }
            ToolOutcome::Text(lines.join("\n"))
        }
        .boxed()
    }
}

/// `"<Weekday>: <condition>, high <t>°, low <t>°, <p>% rain"`, leaving out any part HA did not
/// send. A day without a readable date is skipped.
fn day_line(day: &Value) -> Option<String> {
    let weekday = weekday(day.get("datetime")?.as_str()?)?;
    let mut parts = vec![];
    if let Some(c) = day.get("condition").and_then(Value::as_str) {
        parts.push(condition_words(c));
    }
    if let Some(t) = day.get("temperature").and_then(Value::as_f64) {
        parts.push(format!("high {}°", degrees(t)));
    }
    if let Some(t) = day.get("templow").and_then(Value::as_f64) {
        parts.push(format!("low {}°", degrees(t)));
    }
    if let Some(p) = day.get("precipitation_probability").and_then(Value::as_f64) {
        parts.push(format!("{}% rain", p.round() as i64));
    }
    Some(if parts.is_empty() { weekday } else { format!("{weekday}: {}", parts.join(", ")) })
}

/// The weekday in Toronto: HA sends a timestamp with an offset (often midnight local, in UTC), or
/// a plain date.
fn weekday(s: &str) -> Option<String> {
    if let Ok(ts) = s.parse::<jiff::Timestamp>() {
        let tz = jiff::tz::TimeZone::get(TZ).ok()?;
        return Some(ts.to_zoned(tz).strftime("%A").to_string());
    }
    s.parse::<jiff::civil::Date>().ok().map(|d| d.strftime("%A").to_string())
}

/// Rounded to a whole degree.
fn degrees(t: f64) -> i64 {
    t.round() as i64
}

/// HA's condition names, as words that read aloud well.
fn condition_words(c: &str) -> String {
    match c {
        "clear-night" => "clear".into(),
        "partlycloudy" => "partly cloudy".into(),
        "lightning" => "thunderstorms".into(),
        "lightning-rainy" => "thunderstorms with rain".into(),
        "snowy-rainy" => "rain and snow".into(),
        "windy-variant" => "windy and cloudy".into(),
        "exceptional" => "exceptional weather".into(),
        other => other.replace('-', " "),
    }
}
