//! OpenRouter calls: the production classifier (Jev decisions), filename parse and title
//! translation (chat, JSON mode), and Jev candidate choice.

use std::collections::HashMap;
use std::sync::Mutex;

use anyhow::{Context, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::db::Production;
use crate::http;
use crate::stash::de;

pub const CHAT_PATH: &str = "/api/v1/chat/completions";
pub const DECISIONS_PATH: &str = "/api/alpha/decisions";
pub const OPENROUTER: &str = "https://openrouter.ai";

/// The prompts and the classifier's criteria live in the `plab-site` secret (`site.rs`).
fn prompts() -> &'static crate::site::Prompts {
    &crate::site::get().prompts
}

/// Appended to the parse prompt when the scene's download is known.
const TITLE_NOTE: &str = r#"The input is JSON: "release_title" is the title the release was
published under, and describes the whole download; "file" is this scene's path, which picks
it out when the download holds several scenes; "studio", when present, is the studio the
download is known to be from. Prefer the release title for names and dates, and the file
path to tell scenes of one download apart."#;

fn criteria_value() -> Value {
    Value::Object(
        prompts()
            .criteria
            .iter()
            .map(|c| (c.key.clone(), Value::String(c.description.clone())))
            .collect(),
    )
}

pub struct OpenRouter {
    http: reqwest::Client,
    base: String,
    key: String,
    parse_model: String,
    jev_model: String,
    /// By original title, so the parts of a multi-part FC2 article (one title) get one
    /// English title rather than a fresh rewording each.
    translations: Mutex<HashMap<String, String>>,
}

impl OpenRouter {
    pub fn new(base: &str, key: String, parse_model: String, jev_model: String) -> OpenRouter {
        OpenRouter {
            http: http::client(120),
            base: base.trim_end_matches('/').to_string(),
            key,
            parse_model,
            jev_model,
            translations: Mutex::new(HashMap::new()),
        }
    }

    async fn post(&self, path: &str, body: &Value) -> anyhow::Result<Value> {
        http::post_json(
            &self.http,
            &format!("{}{path}", self.base),
            body,
            &[("Authorization", format!("Bearer {}", self.key))],
        )
        .await
    }

    /// A chat completion with a caller-built body (the assistant's tool loop), the raw reply.
    pub async fn chat(&self, body: &Value) -> anyhow::Result<Value> {
        self.post(CHAT_PATH, body).await
    }

    /// A chat completion in JSON mode, parsed to a `T`; one re-ask on a reply that is not
    /// one. HTTP errors are not retried.
    async fn chat_json<T: serde::de::DeserializeOwned>(
        &self,
        prompt: &str,
        text: &str,
    ) -> anyhow::Result<T> {
        let body = json!({
            "model": self.parse_model,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": text},
            ],
        });
        for attempt in 0..2 {
            let d = self.post(CHAT_PATH, &body).await?;
            let out = reply_object::<T>(&d);
            match out {
                Ok(out) => return Ok(out),
                Err(e) if attempt == 1 => tracing::debug!("malformed reply for {text:?}: {e}"),
                Err(_) => {}
            }
        }
        bail!("malformed reply for {text:?}")
    }
}

/// The chat reply's content as a `T`. Read through a `Value` first: serde would take a JSON
/// array for a struct's fields.
fn reply_object<T: serde::de::DeserializeOwned>(d: &Value) -> Result<T, String> {
    let content = d
        .pointer("/choices/0/message/content")
        .and_then(Value::as_str)
        .ok_or("no message content")?;
    let v: Value = serde_json::from_str(content).map_err(|e| e.to_string())?;
    if !v.is_object() {
        return Err("reply is not a JSON object".into());
    }
    serde_json::from_value(v).map_err(|e| e.to_string())
}

/// The LLM's reading of a file path (the parse prompt's JSON).
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct Parse {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub studio: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::names")]
    pub performers: Vec<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub date: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub time: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub series: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub clip_id: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub query: Option<String>,
}

impl Parse {
    /// A scene title, or None if there's nothing usable.
    ///
    /// The parsed title unchanged when there is one. Otherwise, for a filename with no real
    /// title, a "Creator – date" style fallback: base is the series, studio, or first
    /// performer (in that order); suffix is date+time, date, a clip_id, or -- only when
    /// base came from a series -- the first performer's name. No suffix means no title: a
    /// bare creator name on its own isn't worth writing.
    pub fn display_title(&self) -> Option<String> {
        if let Some(t) = &self.title {
            return Some(t.clone());
        }
        let first = self.performers.first();
        let base = self.series.as_ref().or(self.studio.as_ref()).or(first)?;
        let suffix = match (&self.date, &self.time) {
            (Some(d), Some(t)) => format!("{d} {t}"),
            (Some(d), None) => d.clone(),
            _ => match (&self.clip_id, &self.series, first) {
                (Some(c), _, _) => c.clone(),
                (None, Some(_), Some(p)) => p.clone(),
                _ => return None,
            },
        };
        Some(format!("{base} \u{2013} {suffix}"))
    }

    /// Worth writing as a guess: a title, a studio or performers.
    pub fn has_content(&self) -> bool {
        self.display_title().is_some() || self.studio.is_some() || !self.performers.is_empty()
    }
}

/// One Jev decision: which candidate (if any) a file is.
#[derive(Debug, Clone, PartialEq)]
pub struct JevRequest {
    pub file_path: String,
    pub file_duration_seconds: i64,
    pub filename_parse: Parse,
    pub instructions: &'static str,
    /// `c0`, `c1`, … then `none`, each with its description, in order.
    pub criteria: Vec<(String, String)>,
}

impl JevRequest {
    /// The decisions API's `state` and `questions`.
    pub fn body(&self) -> (Value, Value) {
        let criteria: serde_json::Map<String, Value> = self
            .criteria
            .iter()
            .map(|(k, v)| (k.clone(), v.clone().into()))
            .collect();
        (
            json!({
                "file_path": self.file_path,
                "file_duration_seconds": self.file_duration_seconds,
                "filename_parse": self.filename_parse,
            }),
            json!({"match": {"type": "choice", "instructions": self.instructions, "criteria": criteria}}),
        )
    }
}

pub trait Classify: Send + Sync {
    fn classify(
        &self,
        title: &str,
        category: &str,
    ) -> impl std::future::Future<Output = anyhow::Result<Production>> + Send;
}

/// A Jev decision's answer.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
pub struct ChoiceAnswer {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub choice: Option<String>,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub confidence: Option<f64>,
}

pub trait Llm: Send + Sync {
    fn parse(&self, path: &str) -> impl std::future::Future<Output = anyhow::Result<Parse>> + Send;
    /// `parse`, for a file whose download is known: its release title and, when known,
    /// its studio.
    fn parse_with_title(
        &self,
        path: &str,
        title: &str,
        studio: Option<&str>,
    ) -> impl std::future::Future<Output = anyhow::Result<Parse>> + Send;
    fn translate_title(
        &self,
        title: &str,
    ) -> impl std::future::Future<Output = anyhow::Result<String>> + Send;
    /// One Jev decision: `answers.match` of the decisions reply.
    fn choose(
        &self,
        req: &JevRequest,
    ) -> impl std::future::Future<Output = anyhow::Result<ChoiceAnswer>> + Send;
}

impl Classify for OpenRouter {
    async fn classify(&self, title: &str, category: &str) -> anyhow::Result<Production> {
        let d = self
            .post(
                DECISIONS_PATH,
                &json!({
                    "model": self.jev_model,
                    "state": {"title": title, "category": category},
                    "questions": {"production": {
                        "type": "choice",
                        "instructions": prompts().classify,
                        "criteria": criteria_value(),
                    }},
                }),
            )
            .await?;
        let answer = d
            .pointer("/answers/production")
            .context("no production answer")?;
        let answer = ChoiceAnswer::deserialize(answer).context("unreadable production answer")?;
        match answer.choice.as_deref() {
            Some(c) if prompts().criteria.iter().any(|k| k.key == c) => Ok(Production {
                class: c.to_string(),
                confidence: answer.confidence,
            }),
            choice => bail!("unexpected production choice: {choice:?}"),
        }
    }
}

impl Llm for OpenRouter {
    async fn parse(&self, path: &str) -> anyhow::Result<Parse> {
        self.chat_json(&prompts().parse, path).await
    }

    async fn parse_with_title(
        &self,
        path: &str,
        title: &str,
        studio: Option<&str>,
    ) -> anyhow::Result<Parse> {
        #[derive(Serialize)]
        struct Input<'a> {
            release_title: &'a str,
            file: &'a str,
            #[serde(skip_serializing_if = "Option::is_none")]
            studio: Option<&'a str>,
        }
        let input = serde_json::to_string(&Input {
            release_title: title,
            file: path,
            studio,
        })?;
        self.chat_json(&format!("{}\n\n{TITLE_NOTE}", prompts().parse), &input)
            .await
    }

    async fn translate_title(&self, title: &str) -> anyhow::Result<String> {
        if let Some(t) = self.translations.lock().unwrap().get(title) {
            return Ok(t.clone());
        }
        #[derive(Deserialize)]
        struct Reply {
            #[serde(default, deserialize_with = "de::nonempty")]
            title: Option<String>,
        }
        let out: Reply = self.chat_json(&prompts().translate, title).await?;
        let Some(t) = out
            .title
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
        else {
            bail!("no translation for {title:?}");
        };
        self.translations
            .lock()
            .unwrap()
            .insert(title.to_string(), t.clone());
        Ok(t)
    }

    async fn choose(&self, req: &JevRequest) -> anyhow::Result<ChoiceAnswer> {
        let (state, questions) = req.body();
        let d = self
            .post(
                DECISIONS_PATH,
                &json!({"model": self.jev_model, "state": state, "questions": questions}),
            )
            .await?;
        let answer = d
            .pointer("/answers/match")
            .cloned()
            .context("no match answer")?;
        Ok(serde_json::from_value(answer)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{body_partial_json, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn parse(v: Value) -> Parse {
        serde_json::from_value(v).unwrap()
    }

    // DisplayTitleTest
    #[test]
    fn real_title_returned_unchanged() {
        assert_eq!(
            parse(json!({"title": "Night Magic", "studio": "Studio L", "date": "2024-01-01"}))
                .display_title(),
            Some("Night Magic".to_string())
        );
    }

    #[test]
    fn studio_and_date() {
        assert_eq!(
            parse(json!({"title": null, "studio": "StudioSample", "date": "2025-10-11"}))
                .display_title(),
            Some("StudioSample – 2025-10-11".to_string())
        );
    }

    #[test]
    fn studio_date_and_time() {
        assert_eq!(
            parse(
                json!({"title": null, "studio": "StudioMoon", "date": "2021-06-16", "time": "21:11"})
            )
            .display_title(),
            Some("StudioMoon – 2021-06-16 21:11".to_string())
        );
    }

    #[test]
    fn series_and_clip_id() {
        assert_eq!(
            parse(
                json!({"title": null, "series": "Series Name 2004", "studio": "StudioSample", "clip_id": "2508-02"})
            )
            .display_title(),
            Some("Series Name 2004 – 2508-02".to_string())
        );
    }

    #[test]
    fn series_and_performer() {
        assert_eq!(
            parse(
                json!({"title": null, "series": "Series Name 2004", "studio": "StudioSample", "performers": ["PerformerF"]})
            )
            .display_title(),
            Some("Series Name 2004 – PerformerF".to_string())
        );
    }

    #[test]
    fn nothing_to_build_with_is_none() {
        assert_eq!(
            parse(json!({"title": null, "studio": "X"})).display_title(),
            None
        );
    }

    #[test]
    fn performer_only_base() {
        assert_eq!(
            parse(json!({"title": null, "performers": ["Performer S"], "date": "2021-06-16"}))
                .display_title(),
            Some("Performer S – 2021-06-16".to_string())
        );
    }

    #[test]
    fn studio_and_clip_id_no_date() {
        assert_eq!(
            parse(json!({"title": null, "studio": "X", "clip_id": "abc-1"})).display_title(),
            Some("X – abc-1".to_string())
        );
    }

    #[test]
    fn studio_base_with_only_performers_is_none() {
        assert_eq!(
            parse(json!({"title": null, "studio": "X", "performers": ["Someone"]})).display_title(),
            None
        );
    }

    #[test]
    fn date_and_time_beat_clip_id() {
        assert_eq!(
            parse(
                json!({"title": null, "studio": "X", "date": "2024-01-01", "time": "10:00", "clip_id": "ignored"})
            )
            .display_title(),
            Some("X – 2024-01-01 10:00".to_string())
        );
    }

    fn chat_reply(content: &str) -> ResponseTemplate {
        ResponseTemplate::new(200)
            .set_body_json(json!({"choices": [{"message": {"content": content}}]}))
    }

    async fn client(server: &MockServer) -> OpenRouter {
        OpenRouter::new(
            &server.uri(),
            "sk-key".into(),
            "parse-model".into(),
            "jev-model".into(),
        )
    }

    async fn decisions(server: &MockServer, answer: Value) {
        Mock::given(method("POST"))
            .and(path(DECISIONS_PATH))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(json!({"answers": {"production": answer}})),
            )
            .mount(server)
            .await;
    }

    #[tokio::test]
    async fn chat_posts_the_body_as_is() {
        let server = wiremock::MockServer::start().await;
        wiremock::Mock::given(wiremock::matchers::path(CHAT_PATH))
            .and(wiremock::matchers::header("Authorization", "Bearer k"))
            .and(wiremock::matchers::body_json(serde_json::json!({"model": "m", "messages": []})))
            .respond_with(wiremock::ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": 1})))
            .expect(1)
            .mount(&server)
            .await;
        let or = OpenRouter::new(&server.uri(), "k".into(), "p".into(), "j".into());
        let r = or.chat(&serde_json::json!({"model": "m", "messages": []})).await.unwrap();
        assert_eq!(r["ok"], 1);
    }

    // ---- ported from plab test_classify.py ----

    #[tokio::test]
    async fn classify_request() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(DECISIONS_PATH))
            .and(header("Authorization", "Bearer sk-key"))
            .and(body_partial_json(json!({
                "model": "jev-model",
                "state": {"title": "[Site.com] Couple - Morning", "category": "Clips"},
                "questions": {"production": {
                    "type": "choice",
                    "instructions": "classify question",
                    "criteria": {"industrial": "industrial criterion",
                                 "pro_artistic": "pro_artistic criterion",
                                 "amateur": "amateur criterion"},
                }},
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(
                json!({"answers": {"production": {"choice": "amateur", "confidence": 0.9}}}),
            ))
            .expect(1)
            .mount(&server)
            .await;
        client(&server)
            .await
            .classify("[Site.com] Couple - Morning", "Clips")
            .await
            .unwrap();
    }

    #[test]
    fn criteria_keep_insertion_order() {
        let keys: Vec<_> = prompts().criteria.iter().map(|c| c.key.as_str()).collect();
        assert_eq!(keys, ["industrial", "pro_artistic", "amateur"]);
        let body = criteria_value().to_string();
        let (a, b, c) = (
            body.find("\"industrial\"").unwrap(),
            body.find("\"pro_artistic\"").unwrap(),
            body.find("\"amateur\"").unwrap(),
        );
        assert!(a < b && b < c);
    }

    #[tokio::test]
    async fn classify_model_is_the_jev_model() {
        // Python's test_model_override: the model comes from construction.
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(DECISIONS_PATH))
            .and(body_partial_json(json!({"model": "other/model"})))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(json!({"answers": {"production": {"choice": "industrial"}}})),
            )
            .expect(1)
            .mount(&server)
            .await;
        OpenRouter::new(&server.uri(), "k".into(), "p".into(), "other/model".into())
            .classify("t", "c")
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn classify_answer() {
        let server = MockServer::start().await;
        decisions(
            &server,
            json!({"choice": "pro_artistic", "confidence": 0.75}),
        )
        .await;
        let out = client(&server)
            .await
            .classify("[Site.com] A - B", "Clips")
            .await
            .unwrap();
        assert_eq!(
            out,
            Production {
                class: "pro_artistic".into(),
                confidence: Some(0.75)
            }
        );
    }

    #[tokio::test]
    async fn classify_non_numeric_confidence_is_none() {
        // Python kept any confidence value ("high"); Production.confidence is a float.
        let server = MockServer::start().await;
        decisions(
            &server,
            json!({"choice": "pro_artistic", "confidence": "high"}),
        )
        .await;
        let out = client(&server).await.classify("t", "c").await.unwrap();
        assert_eq!(
            out,
            Production {
                class: "pro_artistic".into(),
                confidence: None
            }
        );
    }

    #[tokio::test]
    async fn classify_missing_confidence_is_none() {
        let server = MockServer::start().await;
        decisions(&server, json!({"choice": "industrial"})).await;
        let out = client(&server).await.classify("t", "c").await.unwrap();
        assert_eq!(
            out,
            Production {
                class: "industrial".into(),
                confidence: None
            }
        );
    }

    #[tokio::test]
    async fn classify_unknown_choice_errors() {
        for (answer, shown) in [
            (json!({"choice": "none"}), r#"Some("none")"#),
            (json!({"choice": null}), "None"),
            (json!({}), "None"),
        ] {
            let server = MockServer::start().await;
            decisions(&server, answer).await;
            let err = client(&server).await.classify("t", "c").await.unwrap_err();
            assert_eq!(
                err.to_string(),
                format!("unexpected production choice: {shown}")
            );
        }
    }

    // ---- ported from stash-identify test_llm.py ----

    #[tokio::test]
    async fn same_title_translated_once() {
        // Two parts of one FC2 article share a title and must get the same English one.
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .and(body_partial_json(json!({"messages": [
                {"role": "system", "content": "translate prompt"},
                {"role": "user", "content": "金欠"},
            ]})))
            .respond_with(chat_reply(r#"{"title": " First "}"#))
            .expect(1)
            .mount(&server)
            .await;
        let c = client(&server).await;
        assert_eq!(c.translate_title("金欠").await.unwrap(), "First");
        assert_eq!(c.translate_title("金欠").await.unwrap(), "First");
    }

    #[tokio::test]
    async fn empty_translation_errors() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .respond_with(chat_reply(r#"{"title": ""}"#))
            .mount(&server)
            .await;
        assert!(client(&server).await.translate_title("金欠").await.is_err());
    }

    // ---- new coverage ----

    #[tokio::test]
    async fn parse_posts_json_mode_and_returns_object() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .and(header("Authorization", "Bearer sk-key"))
            .and(body_partial_json(json!({
                "model": "parse-model",
                "response_format": {"type": "json_object"},
                "messages": [
                    {"role": "system", "content": "parse prompt"},
                    {"role": "user", "content": "a/b.mp4"},
                ],
            })))
            .respond_with(chat_reply(r#"{"studio": "S", "query": "q"}"#))
            .expect(1)
            .mount(&server)
            .await;
        let v = client(&server).await.parse("a/b.mp4").await.unwrap();
        assert_eq!(
            v,
            Parse {
                studio: Some("S".into()),
                query: Some("q".into()),
                ..Parse::default()
            }
        );
    }

    #[tokio::test]
    async fn parse_with_title_sends_title_file_and_studio() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .and(body_partial_json(json!({
                "messages": [
                    {"role": "system", "content": format!("parse prompt\n\n{TITLE_NOTE}")},
                    {"role": "user", "content": r#"{"release_title":"[StudioA.com] Jane - Title [2026, 1080p]","file":"Studio A/Rel/a.mp4","studio":"Studio A"}"#},
                ],
            })))
            .respond_with(chat_reply(r#"{"studio": "Studio A", "query": "q"}"#))
            .expect(1)
            .mount(&server)
            .await;
        let v = client(&server)
            .await
            .parse_with_title(
                "Studio A/Rel/a.mp4",
                "[StudioA.com] Jane - Title [2026, 1080p]",
                Some("Studio A"),
            )
            .await
            .unwrap();
        assert_eq!(v.studio.as_deref(), Some("Studio A"));
    }

    #[tokio::test]
    async fn malformed_reply_is_asked_again_once() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .respond_with(chat_reply("not json"))
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .respond_with(chat_reply(r#"{"query": "q"}"#))
            .expect(1)
            .mount(&server)
            .await;
        let v = client(&server).await.parse("x").await.unwrap();
        assert_eq!(v.query.as_deref(), Some("q"));
    }

    #[tokio::test]
    async fn two_malformed_replies_error_without_a_third_ask() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .respond_with(chat_reply("[1]"))
            .expect(2)
            .mount(&server)
            .await;
        let err = client(&server).await.parse("x.mp4").await.unwrap_err();
        assert_eq!(err.to_string(), r#"malformed reply for "x.mp4""#);
    }

    #[tokio::test]
    async fn http_errors_are_not_retried() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .respond_with(ResponseTemplate::new(500))
            .expect(1)
            .mount(&server)
            .await;
        assert!(client(&server).await.parse("x").await.is_err());
    }

    #[tokio::test]
    async fn choose_posts_state_and_returns_the_match_answer() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(DECISIONS_PATH))
            .and(header("Authorization", "Bearer sk-key"))
            .and(body_partial_json(json!({
                "model": "jev-model",
                "state": {"file_path": "p", "file_duration_seconds": 60},
                "questions": {"match": {"type": "choice", "instructions": "pick"}},
            })))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(
                    json!({"answers": {"match": {"choice": "1", "confidence": 0.8}}}),
                ),
            )
            .expect(1)
            .mount(&server)
            .await;
        let req = JevRequest {
            file_path: "p".into(),
            file_duration_seconds: 60,
            filename_parse: Parse::default(),
            instructions: "pick",
            criteria: vec![("c0".into(), "one".into())],
        };
        let a = client(&server).await.choose(&req).await.unwrap();
        assert_eq!(
            a,
            ChoiceAnswer {
                choice: Some("1".into()),
                confidence: Some(0.8)
            }
        );
    }

    #[tokio::test]
    async fn a_sloppy_parse_reply_keeps_what_is_usable() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .respond_with(chat_reply(
                r#"{"studio": ["S"], "title": "T", "series": {"a": 1}, "query": 3}"#,
            ))
            .mount(&server)
            .await;
        let v = client(&server).await.parse("x.mp4").await.unwrap();
        assert_eq!(
            (v.studio, v.title, v.series, v.query),
            (None, Some("T".into()), None, Some("3".into()))
        );
    }
}
