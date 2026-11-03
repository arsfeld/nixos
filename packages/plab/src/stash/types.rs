//! The records plab reads from and writes to Stash and the stash-boxes behind it.
//! Field names are the GraphQL ones. Absent values are normalized by `super::de` on the way
//! in, so `Option<String>` here always means "present and non-empty".

use std::collections::HashSet;

use anyhow::Context;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};

use super::de;

/// A link to another record by id (a scene's performers and tags).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Ref {
    #[serde(deserialize_with = "de::id")]
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct StudioRef {
    #[serde(deserialize_with = "de::id")]
    pub id: String,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Deserialize, Serialize)]
pub struct StashId {
    pub endpoint: String,
    pub stash_id: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct VideoFile {
    pub path: String,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub duration: Option<f64>,
}

/// A library scene (`SCENE_FIELDS`).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Scene {
    #[serde(deserialize_with = "de::id")]
    pub id: String,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub code: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub details: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub director: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub date: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub urls: Vec<String>,
    #[serde(default)]
    pub studio: Option<StudioRef>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub performers: Vec<Ref>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub tags: Vec<Ref>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub stash_ids: Vec<StashId>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub files: Vec<VideoFile>,
}

impl Scene {
    pub fn first_path(&self) -> Option<&str> {
        self.files.first().map(|f| f.path.as_str())
    }

    /// The first file's path and duration; an error when the scene has none.
    pub fn first_file(&self) -> anyhow::Result<(&str, f64)> {
        let f = self
            .files
            .first()
            .with_context(|| format!("scene {} has no file", self.id))?;
        let duration = f.duration.context("file has no duration")?;
        Ok((&f.path, duration))
    }

    /// Has a title, studio or performers: what `bare_scenes` leaves out.
    pub fn is_filled(&self) -> bool {
        self.title.is_some() || self.studio.is_some() || !self.performers.is_empty()
    }

    pub fn has_tag(&self, id: &str) -> bool {
        self.tags.iter().any(|t| t.id == id)
    }

    pub fn studio_name(&self) -> Option<&str> {
        self.studio.as_ref()?.name.as_deref()
    }
}

/// A scraped studio (`SCRAPED_FIELDS`' `studio { ... }`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct ScrapedStudio {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub urls: Vec<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub image: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub details: Option<String>,
    /// One comma-separated string, as stash-box sends it; see `de::csv`.
    #[serde(default, deserialize_with = "de::nonempty")]
    pub aliases: Option<String>,
    #[serde(default, deserialize_with = "de::opt_id")]
    pub remote_site_id: Option<String>,
    #[serde(default)]
    pub parent: Option<Box<ScrapedStudio>>,
}

/// A scraped performer. Every attribute is text on the wire, numbers included.
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct ScrapedPerformer {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub disambiguation: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub gender: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub urls: Vec<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub birthdate: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub death_date: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub ethnicity: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub country: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub eye_color: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub hair_color: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub height: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub weight: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub measurements: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub career_start: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub career_end: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub tattoos: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub piercings: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub aliases: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub details: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub images: Vec<String>,
    #[serde(default, deserialize_with = "de::opt_id")]
    pub remote_site_id: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct ScrapedTag {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "de::opt_id")]
    pub stored_id: Option<String>,
}

/// A scraped scene: a stash-box search hit, a URL scrape, or a code-database / FC2 record
/// put in the same shape.
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct Candidate {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub code: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub details: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub director: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub date: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub image: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub urls: Vec<String>,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub duration: Option<f64>,
    #[serde(default, deserialize_with = "de::opt_id")]
    pub remote_site_id: Option<String>,
    #[serde(default)]
    pub studio: Option<ScrapedStudio>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub performers: Vec<ScrapedPerformer>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub tags: Vec<ScrapedTag>,
}

impl Candidate {
    /// The duration, when known. Stash-boxes send 0 for "unknown".
    pub fn known_duration(&self) -> Option<f64> {
        self.duration.filter(|d| *d != 0.0)
    }

    pub fn studio_name(&self) -> Option<&str> {
        self.studio.as_ref()?.name.as_deref()
    }
}

fn is_empty<T>(v: &[T]) -> bool {
    v.is_empty()
}

/// SceneUpdateInput. Only the fields set are sent; Stash leaves the rest alone.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct SceneUpdate {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub director: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub urls: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub studio_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub performer_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stash_ids: Option<Vec<StashId>>,
}

impl SceneUpdate {
    pub fn new(id: &str) -> SceneUpdate {
        SceneUpdate {
            id: id.to_string(),
            ..SceneUpdate::default()
        }
    }

    /// Sets anything besides the id.
    pub fn has_changes(&self) -> bool {
        *self != SceneUpdate::new(&self.id)
    }
}

/// GenderEnum. Parsed from a scraped performer's free text; anything else is not sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Gender {
    Male,
    Female,
    TransgenderMale,
    TransgenderFemale,
    Intersex,
    NonBinary,
}

/// "transgender female", "Non-Binary", "MALE" -> the enum spelling.
fn enum_key(s: &str) -> String {
    s.to_uppercase().replace([' ', '-'], "_")
}

impl std::str::FromStr for Gender {
    type Err = ();
    fn from_str(s: &str) -> Result<Gender, ()> {
        Ok(match enum_key(s).as_str() {
            "MALE" => Gender::Male,
            "FEMALE" => Gender::Female,
            "TRANSGENDER_MALE" => Gender::TransgenderMale,
            "TRANSGENDER_FEMALE" => Gender::TransgenderFemale,
            "INTERSEX" => Gender::Intersex,
            "NON_BINARY" => Gender::NonBinary,
            _ => return Err(()),
        })
    }
}

/// PerformerCreateInput; unset fields are not sent.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct PerformerCreate {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disambiguation: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gender: Option<Gender>,
    #[serde(skip_serializing_if = "is_empty")]
    pub urls: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub birthdate: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub death_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ethnicity: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub country: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub eye_color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hair_color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height_cm: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub weight: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub measurements: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub career_start: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub career_end: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tattoos: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub piercings: Option<String>,
    #[serde(skip_serializing_if = "is_empty")]
    pub alias_list: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(skip_serializing_if = "is_empty")]
    pub stash_ids: Vec<StashId>,
}

impl PerformerCreate {
    /// Just a name: a performer known only from a filename.
    pub fn named(name: &str) -> PerformerCreate {
        PerformerCreate {
            name: name.to_string(),
            ..PerformerCreate::default()
        }
    }
}

/// StudioCreateInput; unset fields are not sent.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct StudioCreate {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    #[serde(skip_serializing_if = "is_empty")]
    pub urls: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(skip_serializing_if = "is_empty")]
    pub aliases: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    #[serde(skip_serializing_if = "is_empty")]
    pub stash_ids: Vec<StashId>,
}

impl StudioCreate {
    pub fn named(name: &str) -> StudioCreate {
        StudioCreate {
            name: name.to_string(),
            ..StudioCreate::default()
        }
    }
}

/// What `apply` resolved a scrape's studio, performers and tags to in this Stash.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Resolved {
    pub studio_id: Option<String>,
    pub performer_ids: Vec<String>,
    pub tag_ids: Vec<String>,
    pub stash_ids: Vec<StashId>,
}

/// A performer or studio found by name (`performers_like`, `studios_like`). Performers
/// carry `alias_list`, studios `aliases`; both are lists here.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct NamedRecord {
    #[serde(deserialize_with = "de::id")]
    pub id: String,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, alias = "alias_list", deserialize_with = "de::null_default")]
    pub aliases: Vec<String>,
}

/// One scene's fingerprint match (`scrapeMultiScenes { title duration }`).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct FingerprintMatch {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub duration: Option<f64>,
}

/// One of Stash's saved task-option blobs (scan, generate, identify). plab never reads
/// inside one beyond `Defaults`' two accessors: it adds a few keys and sends it back to the
/// same server, so it stays JSON. Nulls are dropped on the way in, since the blob is
/// replayed as a job input.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct JobOptions(pub Map<String, Value>);

impl<'de> Deserialize<'de> for JobOptions {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(
            match strip_nulls(Option::<Value>::deserialize(d)?.unwrap_or(Value::Null)) {
                Value::Object(m) => JobOptions(m),
                _ => JobOptions::default(),
            },
        )
    }
}

fn strip_nulls(v: Value) -> Value {
    match v {
        Value::Object(o) => Value::Object(
            o.into_iter()
                .filter(|(_, x)| !x.is_null())
                .map(|(k, x)| (k, strip_nulls(x)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.into_iter().map(strip_nulls).collect()),
        other => other,
    }
}

impl JobOptions {
    /// This blob with `extra` keys set, as a job input.
    pub fn with<'a>(&self, extra: impl IntoIterator<Item = (&'a str, Value)>) -> Value {
        let mut m = self.0.clone();
        for (k, v) in extra {
            m.insert(k.to_string(), v);
        }
        Value::Object(m)
    }
}

/// `configuration.defaults`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
#[serde(default)]
pub struct Defaults {
    pub scan: JobOptions,
    pub generate: JobOptions,
    pub identify: JobOptions,
}

impl Defaults {
    /// The tags Stash's identify adds to scenes it skipped, which a fill must not copy.
    pub fn skip_tags(&self) -> HashSet<String> {
        let opts = self.identify.0.get("options");
        ["skipMultipleMatchTag", "skipSingleNamePerformerTag"]
            .into_iter()
            .filter_map(|k| opts?.get(k)?.as_str())
            .filter(|t| !t.is_empty())
            .map(str::to_string)
            .collect()
    }

    /// The stash-box endpoints Stash's identify consults, in its order.
    pub fn identify_boxes(&self) -> Vec<String> {
        self.identify
            .0
            .get("sources")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|s| s.pointer("/source/stash_box_endpoint")?.as_str())
            .map(str::to_string)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn scene_reads_stash_shape() {
        let s: Scene = serde_json::from_value(json!({
            "id": "5", "title": "", "studio": null, "performers": [{"id": "1"}],
            "tags": [{"id": 9}], "stash_ids": null,
            "files": [{"path": "/media/Vault/a.mp4", "duration": 348.2}],
        }))
        .unwrap();
        assert_eq!(s.title, None);
        assert!(s.is_filled());
        assert!(s.has_tag("9"));
        assert_eq!(s.first_file().unwrap(), ("/media/Vault/a.mp4", 348.2));
    }

    #[test]
    fn scene_without_files_has_no_first_file() {
        let s: Scene = serde_json::from_value(json!({"id": "5"})).unwrap();
        assert!(!s.is_filled());
        assert!(
            s.first_file()
                .unwrap_err()
                .to_string()
                .contains("scene 5 has no file")
        );
    }

    #[test]
    fn candidate_zero_duration_is_unknown() {
        let c: Candidate = serde_json::from_value(json!({"duration": 0})).unwrap();
        assert_eq!(c.known_duration(), None);
        let c: Candidate = serde_json::from_value(json!({"duration": "1249"})).unwrap();
        assert_eq!(c.known_duration(), Some(1249.0));
    }

    #[test]
    fn named_record_reads_either_alias_field() {
        let p: NamedRecord =
            serde_json::from_value(json!({"id": "1", "name": "A", "alias_list": ["B"]})).unwrap();
        let s: NamedRecord =
            serde_json::from_value(json!({"id": "2", "name": "S", "aliases": ["T"]})).unwrap();
        assert_eq!(
            (p.aliases, s.aliases),
            (vec!["B".to_string()], vec!["T".to_string()])
        );
    }

    #[test]
    fn defaults_strip_nulls_and_expose_identify_settings() {
        let d: Defaults = serde_json::from_value(json!({
            "scan": {"rescan": null, "scanGenerateCovers": true},
            "identify": {
                "sources": [{"source": {"stash_box_endpoint": "https://stashdb.org/graphql"}},
                            {"source": {"scraper_id": "x"}}],
                "options": {"skipMultipleMatchTag": "7", "skipSingleNamePerformerTag": ""},
            },
        }))
        .unwrap();
        assert_eq!(
            d.scan.0,
            json!({"scanGenerateCovers": true})
                .as_object()
                .unwrap()
                .clone()
        );
        assert_eq!(d.identify_boxes(), ["https://stashdb.org/graphql"]);
        assert_eq!(d.skip_tags(), HashSet::from(["7".to_string()]));
        assert_eq!(
            d.scan.with([("paths", json!(["/a"]))]),
            json!({"scanGenerateCovers": true, "paths": ["/a"]})
        );
    }

    #[test]
    fn scene_update_sends_only_what_is_set() {
        let mut up = SceneUpdate::new("5");
        assert!(!up.has_changes());
        assert_eq!(serde_json::to_value(&up).unwrap(), json!({"id": "5"}));
        up.cover_image = Some("data:x".into());
        assert!(up.has_changes());
        assert_eq!(
            serde_json::to_value(&up).unwrap(),
            json!({"id": "5", "cover_image": "data:x"})
        );
    }

    #[test]
    fn enums_parse_free_text() {
        assert_eq!("transgender female".parse(), Ok(Gender::TransgenderFemale));
        assert_eq!("Non-Binary".parse(), Ok(Gender::NonBinary));
        assert_eq!("robot".parse::<Gender>(), Err(()));
        assert_eq!(
            serde_json::to_value(Gender::NonBinary).unwrap(),
            json!("NON_BINARY")
        );
    }

    #[test]
    fn creates_drop_empty_fields() {
        assert_eq!(
            serde_json::to_value(PerformerCreate::named("A")).unwrap(),
            json!({"name": "A"})
        );
        assert_eq!(
            serde_json::to_value(StudioCreate::named("S")).unwrap(),
            json!({"name": "S"})
        );
    }
}
