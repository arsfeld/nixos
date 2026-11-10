//! The `weather_forecast` tool against a stub Home Assistant.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::{RawQuery, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::post;
use claude_board_bridge::config::ha_settings_from_env;
use claude_board_bridge::mcp::weather::WeatherForecast;
use claude_board_bridge::mcp::{Tool, ToolOutcome};
use serde_json::{Value, json};

#[derive(Default)]
struct Seen {
    auth: Option<String>,
    query: Option<String>,
    body: Option<Value>,
}

type Shared = Arc<Mutex<Seen>>;

async fn serve(app: Router) -> String {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(l, app).await.unwrap() });
    format!("http://{addr}")
}

/// A stub HA answering `get_forecasts` with `forecast` for `weather.forecast_home`.
async fn stub(forecast: Value) -> (String, Shared) {
    let seen: Shared = Arc::default();
    let app = Router::new()
        .route(
            "/api/services/weather/get_forecasts",
            post(move |State(s): State<Shared>, headers: HeaderMap, RawQuery(q): RawQuery, body: String| {
                let forecast = forecast.clone();
                async move {
                    let mut seen = s.lock().unwrap();
                    seen.auth = headers.get("authorization").and_then(|v| v.to_str().ok()).map(String::from);
                    seen.query = q;
                    seen.body = serde_json::from_str(&body).ok();
                    axum::Json(json!({
                        "service_response": {"weather.forecast_home": {"forecast": forecast}},
                        "changed_states": [],
                    }))
                }
            }),
        )
        .with_state(seen.clone());
    (serve(app).await, seen)
}

fn tool(base: &str) -> WeatherForecast {
    WeatherForecast::new(base.to_string(), "ha-secret".into(), "weather.forecast_home".into())
}

fn text(o: ToolOutcome) -> String {
    match o {
        ToolOutcome::Text(t) => t,
        ToolOutcome::Error(e) => panic!("expected text, got error: {e}"),
    }
}

fn error(o: ToolOutcome) -> String {
    match o {
        ToolOutcome::Error(e) => e,
        ToolOutcome::Text(t) => panic!("expected an error, got text: {t}"),
    }
}

fn five_days() -> Value {
    json!([
        // Midnight Toronto, as HA's met.no integration reports it (UTC): a Tuesday.
        {"datetime": "2026-11-10T05:00:00+00:00", "condition": "partlycloudy", "temperature": 7.4, "templow": 1.6, "precipitation_probability": 20},
        {"datetime": "2026-11-11T05:00:00+00:00", "condition": "rainy", "temperature": 9.0, "templow": 4.2, "precipitation_probability": 80},
        {"datetime": "2026-11-12T05:00:00+00:00", "condition": "snowy", "temperature": -0.6, "templow": -5.0, "precipitation_probability": 60},
        {"datetime": "2026-11-13T05:00:00+00:00", "condition": "sunny", "temperature": 3.0, "templow": -2.0, "precipitation_probability": 0},
        {"datetime": "2026-11-14T05:00:00+00:00", "condition": "cloudy", "temperature": 4.0, "templow": 0.0, "precipitation_probability": 10},
    ])
}

#[tokio::test]
async fn three_days_formatted() {
    let (base, seen) = stub(five_days()).await;
    let out = text(tool(&base).call(json!({"days": 3})).await);
    assert_eq!(
        out,
        "Tuesday: partly cloudy, high 7°, low 2°, 20% rain\n\
         Wednesday: rainy, high 9°, low 4°, 80% rain\n\
         Thursday: snowy, high -1°, low -5°, 60% rain"
    );
    let seen = seen.lock().unwrap();
    assert_eq!(seen.auth.as_deref(), Some("Bearer ha-secret"));
    assert_eq!(seen.query.as_deref(), Some("return_response"));
    assert_eq!(seen.body, Some(json!({"entity_id": "weather.forecast_home", "type": "daily"})));
}

#[tokio::test]
async fn days_out_of_range_is_an_error() {
    let (base, seen) = stub(five_days()).await;
    for days in [json!(0), json!(6), json!(-1), json!("three"), json!(2.5)] {
        let e = error(tool(&base).call(json!({"days": days})).await);
        assert!(e.contains("1 to 5"), "{e}");
    }
    assert!(seen.lock().unwrap().body.is_none(), "an invalid request must not reach HA");
}

#[tokio::test]
async fn ha_down_is_unavailable_text() {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", l.local_addr().unwrap());
    drop(l);
    let e = error(tool(&base).call(json!({"days": 2})).await);
    assert!(e.contains("unavailable"), "{e}");
    assert!(!e.contains("ha-secret"));

    // A refusal (a bad token, say) is unavailable too, and never echoes the token.
    let app = Router::new()
        .route("/api/services/weather/get_forecasts", post(|| async { StatusCode::UNAUTHORIZED.into_response() }));
    let base = serve(app).await;
    let e = error(tool(&base).call(json!({"days": 2})).await);
    assert!(e.contains("unavailable"), "{e}");
    assert!(!e.contains("ha-secret"));
}

#[tokio::test]
async fn missing_fields_are_skipped_not_fatal() {
    let (base, _) = stub(json!([
        {"datetime": "2026-11-10T05:00:00+00:00", "condition": "sunny", "temperature": 5},
        {"condition": "rainy", "temperature": 9.0},
        {"datetime": "2026-11-12T05:00:00+00:00", "templow": -3.0, "precipitation_probability": null},
        {"datetime": "not a date", "condition": "cloudy"},
        {"datetime": "2026-11-14", "condition": "fog", "temperature": 2.0, "templow": 0.0, "precipitation_probability": 5},
    ]))
    .await;
    let out = text(tool(&base).call(json!({"days": 5})).await);
    assert_eq!(
        out,
        "Tuesday: sunny, high 5°\n\
         Thursday: low -3°\n\
         Saturday: fog, high 2°, low 0°, 5% rain"
    );
}

#[tokio::test]
async fn an_empty_forecast_is_an_error() {
    let (base, _) = stub(json!([])).await;
    let e = error(tool(&base).call(json!({"days": 3})).await);
    assert!(e.contains("No forecast"), "{e}");
}

fn env(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let m: HashMap<String, String> = vars.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    move |k| m.get(k).cloned()
}

fn token_file(name: &str, content: &str) -> String {
    let p = std::env::temp_dir().join(format!("cbb-weather-{}-{name}", std::process::id()));
    std::fs::write(&p, content).unwrap();
    p.to_str().unwrap().to_string()
}

#[test]
fn ha_settings_need_both_url_and_token() {
    let tok = token_file("both", "ha-secret\n");
    assert!(ha_settings_from_env(env(&[])).unwrap().is_none());
    assert!(ha_settings_from_env(env(&[("BRIDGE_HA_URL", "http://ha")])).unwrap().is_none());
    assert!(ha_settings_from_env(env(&[("BRIDGE_HA_TOKEN_FILE", &tok)])).unwrap().is_none());
    let s = ha_settings_from_env(env(&[("BRIDGE_HA_URL", "http://ha"), ("BRIDGE_HA_TOKEN_FILE", &tok)]))
        .unwrap()
        .unwrap();
    assert_eq!(s.url, "http://ha");
    assert_eq!(s.token, "ha-secret");
    assert_eq!(s.weather_entity, "weather.forecast_home");
    let s = ha_settings_from_env(env(&[
        ("BRIDGE_HA_URL", "http://ha"),
        ("BRIDGE_HA_TOKEN_FILE", &tok),
        ("BRIDGE_HA_WEATHER_ENTITY", "weather.other"),
    ]))
    .unwrap()
    .unwrap();
    assert_eq!(s.weather_entity, "weather.other");
}

#[test]
fn an_unreadable_or_empty_ha_token_is_an_error() {
    let empty = token_file("empty", " \n");
    let e = ha_settings_from_env(env(&[("BRIDGE_HA_URL", "http://ha"), ("BRIDGE_HA_TOKEN_FILE", &empty)]))
        .err()
        .unwrap();
    assert!(e.contains("BRIDGE_HA_TOKEN_FILE") && e.contains(&empty), "{e}");
    let e = ha_settings_from_env(env(&[("BRIDGE_HA_URL", "http://ha"), ("BRIDGE_HA_TOKEN_FILE", "/nonexistent/ha")]))
        .err()
        .unwrap();
    assert!(e.contains("BRIDGE_HA_TOKEN_FILE") && e.contains("/nonexistent/ha"), "{e}");
}
