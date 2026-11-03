//! Lenient deserializers for the shapes Stash, stash-boxes, the code database and the LLM send.
//! Each one maps "absent" spellings (missing, `null`, `""`) to `None` once, here, so the
//! code reading a record never has to re-check them.

use serde::{Deserialize, Deserializer};

/// A JSON scalar as it may arrive where a string is meant.
#[derive(Deserialize)]
#[serde(untagged)]
enum Scalar {
    S(String),
    I(i64),
    U(u64),
    F(f64),
    // A boolean, array or object where a string belongs: it carries no usable value, but
    // must not fail the whole record (an LLM's reply is the usual source).
    Other(serde::de::IgnoredAny),
}

impl Scalar {
    fn into_string(self) -> Option<String> {
        match self {
            Scalar::S(s) if s.is_empty() => None,
            Scalar::S(s) => Some(s),
            Scalar::I(i) => Some(i.to_string()),
            Scalar::U(u) => Some(u.to_string()),
            Scalar::F(f) => Some(f.to_string()),
            Scalar::Other(_) => None,
        }
    }
}

/// An id, sent as a string or a number.
pub fn id<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Scalar::deserialize(d)?
        .into_string()
        .ok_or_else(|| serde::de::Error::custom("empty id"))
}

/// An optional id: missing, `null` or `""` is `None`.
pub fn opt_id<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    nonempty(d)
}

/// A string field: missing, `null` or `""` is `None`; a number becomes its decimal text.
pub fn nonempty<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Ok(Option::<Scalar>::deserialize(d)?.and_then(Scalar::into_string))
}

/// A number sent as a number or a numeric string; anything else is `None`.
pub fn lenient_f64<'de, D: Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
    Ok(match Option::<Scalar>::deserialize(d)? {
        Some(Scalar::I(i)) => Some(i as f64),
        Some(Scalar::U(u)) => Some(u as f64),
        Some(Scalar::F(f)) => Some(f),
        Some(Scalar::S(s)) => s.trim().parse().ok().filter(|f: &f64| f.is_finite()),
        Some(Scalar::Other(_)) | None => None,
    })
}

/// A list or object field where `null` means empty.
pub fn null_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

/// A list of strings, dropping `null`s, empties and non-strings (an LLM's `performers`).
/// A lone non-empty string counts as one name; any other shape yields none.
pub fn names<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<String>, D::Error> {
    use serde_json::Value;
    Ok(match Option::<Value>::deserialize(d)? {
        Some(Value::Array(items)) => items
            .into_iter()
            .filter_map(|v| match v {
                Value::String(s) if !s.is_empty() => Some(s),
                _ => None,
            })
            .collect(),
        Some(Value::String(s)) if !s.is_empty() => vec![s],
        _ => Vec::new(),
    })
}

/// Split a comma-separated alias string (a scraped performer's or studio's `aliases`).
pub fn csv(s: Option<&str>) -> Vec<String> {
    s.unwrap_or("")
        .split(',')
        .map(str::trim)
        .filter(|a| !a.is_empty())
        .map(str::to_string)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[derive(Deserialize, Debug, PartialEq)]
    struct R {
        #[serde(deserialize_with = "id")]
        id: String,
        #[serde(default, deserialize_with = "nonempty")]
        s: Option<String>,
        #[serde(default, deserialize_with = "lenient_f64")]
        f: Option<f64>,
        #[serde(default, deserialize_with = "null_default")]
        v: Vec<String>,
        #[serde(default, deserialize_with = "names")]
        n: Vec<String>,
    }

    fn r(v: serde_json::Value) -> R {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn ids_arrive_as_strings_or_numbers() {
        assert_eq!(r(json!({"id": "7"})).id, "7");
        assert_eq!(r(json!({"id": 7})).id, "7");
        assert!(serde_json::from_value::<R>(json!({"id": ""})).is_err());
    }

    #[test]
    fn absent_strings_are_none() {
        assert_eq!(r(json!({"id": 1})).s, None);
        assert_eq!(r(json!({"id": 1, "s": null})).s, None);
        assert_eq!(r(json!({"id": 1, "s": ""})).s, None);
        assert_eq!(r(json!({"id": 1, "s": "x"})).s.as_deref(), Some("x"));
        assert_eq!(r(json!({"id": 1, "s": 170})).s.as_deref(), Some("170"));
        assert_eq!(r(json!({"id": 1, "s": true})).s, None);
    }

    #[test]
    fn arrays_and_objects_where_scalars_belong_are_none() {
        let v = r(json!({"id": 1, "s": [1], "f": {"a": 1}}));
        assert_eq!((v.s, v.f), (None, None));
    }

    #[test]
    fn numbers_may_be_numeric_strings() {
        assert_eq!(r(json!({"id": 1, "f": 358})).f, Some(358.0));
        assert_eq!(r(json!({"id": 1, "f": 358.5})).f, Some(358.5));
        assert_eq!(r(json!({"id": 1, "f": " 358 "})).f, Some(358.0));
        assert_eq!(r(json!({"id": 1, "f": "abc"})).f, None);
        assert_eq!(r(json!({"id": 1, "f": ""})).f, None);
        assert_eq!(r(json!({"id": 1, "f": null})).f, None);
    }

    #[test]
    fn null_lists_are_empty() {
        assert!(r(json!({"id": 1, "v": null})).v.is_empty());
        assert_eq!(r(json!({"id": 1, "v": ["a"]})).v, ["a"]);
    }

    #[test]
    fn names_keep_nonempty_strings_only() {
        assert_eq!(
            r(json!({"id": 1, "n": ["A", "", null, 3, "B"]})).n,
            ["A", "B"]
        );
        assert!(r(json!({"id": 1, "n": null})).n.is_empty());
        assert_eq!(r(json!({"id": 1, "n": "X"})).n, ["X"]);
        assert!(r(json!({"id": 1, "n": ""})).n.is_empty());
        assert!(r(json!({"id": 1, "n": {"a": 1}})).n.is_empty());
    }

    #[test]
    fn csv_splits_and_trims() {
        assert_eq!(csv(Some(" a, b ,,c ")), ["a", "b", "c"]);
        assert!(csv(None).is_empty());
    }
}
