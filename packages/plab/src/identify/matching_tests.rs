use super::*;
use crate::stash::StudioRef;
use serde_json::{Value, json};
use std::collections::HashSet;

const CODEDB: &str = "https://codes.example/graphql";
const STASHDB: &str = "https://stashdb.org/graphql";

fn cand_of(v: Value) -> Candidate {
    serde_json::from_value(v).expect("test candidate")
}

fn cand(title: &str, studio: &str, date: Option<&str>, duration: Option<f64>) -> Candidate {
    cand_of(json!({"title": title,
           "studio": if studio.is_empty() { Value::Null } else { json!({"name": studio}) },
           "date": date, "duration": duration}))
}

fn ep(e: &str, c: Candidate) -> Hit {
    Hit {
        endpoint: e.to_string(),
        scene: c,
    }
}

fn parse_of(v: Value) -> Parse {
    serde_json::from_value(v).expect("test parse")
}

fn scene_of(v: Value) -> Scene {
    serde_json::from_value(v).expect("test scene")
}

fn to_json<T: serde::Serialize>(v: &T) -> Value {
    serde_json::to_value(v).unwrap()
}

fn sid(endpoint: &str, id: &str) -> StashId {
    StashId {
        endpoint: endpoint.into(),
        stash_id: id.into(),
    }
}

// NormTest
#[test]
fn collapses_case_space_punctuation() {
    assert_eq!(norm(Some("Studio Name")), norm(Some("StudioName")));
    assert_eq!(norm(Some("CAN'T WAIT")), "cantwait");
    assert_eq!(norm(None), "");
}

// DurationTest
#[test]
fn within_tolerance() {
    assert!(duration_ok(&cand("a", "s", None, Some(358.0)), 348.0));
    assert!(!duration_ok(&cand("a", "s", None, Some(359.0)), 348.0));
}

#[test]
fn unknown_duration_never_qualifies() {
    assert!(!duration_ok(&cand("a", "s", None, None), 348.0));
}

// DedupeTest
#[test]
fn first_endpoint_wins_per_scene() {
    let out = dedupe(vec![
        ep(CODEDB, cand("Snowed In", "Other Studio", None, None)),
        ep(STASHDB, cand("SNOWED IN", "OtherStudio", None, None)),
        ep(STASHDB, cand("Other", "Other Studio", None, None)),
    ]);
    assert_eq!(
        out.iter().map(|h| h.endpoint.as_str()).collect::<Vec<_>>(),
        [CODEDB, STASHDB]
    );
    assert_eq!(out[1].scene.title.as_deref(), Some("Other"));
}

// DeterministicTest
fn det_parse() -> Parse {
    parse_of(json!({"studio": "StudioName", "date": "2024-12-24"}))
}

#[test]
fn studio_and_date_fire() {
    let c = ep(
        CODEDB,
        cand(
            "She's A Fine Title",
            "Studio Name",
            Some("2024-12-24"),
            Some(1200.0),
        ),
    );
    assert_eq!(
        deterministic_match(std::slice::from_ref(&c), &det_parse()),
        Some(c)
    );
}

#[test]
fn twins_across_endpoints_still_fire() {
    let a = ep(
        CODEDB,
        cand(
            "She's A Fine Title",
            "Studio Name",
            Some("2024-12-24"),
            None,
        ),
    );
    let b = ep(
        STASHDB,
        cand("She's a fine title", "StudioName", Some("2024-12-24"), None),
    );
    assert_eq!(deterministic_match(&[a.clone(), b], &det_parse()), Some(a));
}

#[test]
fn two_different_scenes_do_not_fire() {
    let a = ep(CODEDB, cand("One", "Studio Name", Some("2024-12-24"), None));
    let b = ep(CODEDB, cand("Two", "Studio Name", Some("2024-12-24"), None));
    assert_eq!(deterministic_match(&[a, b], &det_parse()), None);
}

#[test]
fn needs_both_studio_and_date() {
    let c = ep(CODEDB, cand("x", "Studio Name", Some("2024-12-24"), None));
    let cs = std::slice::from_ref(&c);
    assert_eq!(
        deterministic_match(cs, &parse_of(json!({"studio": "StudioName", "date": null}))),
        None
    );
    assert_eq!(
        deterministic_match(
            cs,
            &parse_of(json!({"studio": "Other", "date": "2024-12-24"}))
        ),
        None
    );
}

// TwinsTest
#[test]
fn finds_same_scene_on_other_endpoint() {
    let a = ep(
        STASHDB,
        cand("SNOWED IN", "Other Studio", None, Some(600.0)),
    );
    let b = ep(CODEDB, cand("Snowed In", "Other Studio", None, Some(601.0)));
    let c = ep(CODEDB, cand("Snowed In", "Other Studio", None, Some(900.0)));
    assert_eq!(twins(&a, &[b.clone(), a.clone(), c], 600.0), vec![b, a]);
}

// CreateInputTest
#[test]
fn performer_conversions() {
    let p: ScrapedPerformer = serde_json::from_value(
        json!({"name": "Vivian", "gender": "female", "height": "170", "weight": "55",
        "aliases": "Viv, V. ",
        "images": ["https://img/1.jpg", "https://img/2.jpg"], "remote_site_id": "abc",
        "country": "", "urls": []}),
    )
    .unwrap();
    let got = to_json(&performer_create_input(&p, CODEDB));
    assert_eq!(
        got,
        json!({"name": "Vivian", "gender": "FEMALE", "height_cm": 170, "weight": 55,
            "alias_list": ["Viv", "V."], "image": "https://img/1.jpg",
            "stash_ids": [{"endpoint": CODEDB, "stash_id": "abc"}]})
    );
    // key order is the struct's field order
    let keys: Vec<_> = got.as_object().unwrap().keys().cloned().collect();
    assert_eq!(
        keys,
        [
            "name",
            "gender",
            "height_cm",
            "weight",
            "alias_list",
            "image",
            "stash_ids"
        ]
    );
}

#[test]
fn studio_with_parent() {
    let s: ScrapedStudio = serde_json::from_value(
        json!({"name": "Studio L", "image": "https://logo", "aliases": null, "remote_site_id": "r1"}),
    )
    .unwrap();
    assert_eq!(
        to_json(&studio_create_input(&s, STASHDB, Some("7"))),
        json!({"name": "Studio L", "image": "https://logo", "parent_id": "7",
            "stash_ids": [{"endpoint": STASHDB, "stash_id": "r1"}]})
    );
}

// PickByNameTest
fn records() -> Vec<NamedRecord> {
    [
        json!({"id": "1019", "name": "Jane Example", "alias_list": ["Vivian", "Janie Example"]}),
        json!({"id": "842", "name": "Vivian Sample", "alias_list": []}),
    ]
    .into_iter()
    .map(|v| serde_json::from_value(v).expect("test record"))
    .collect()
}

#[test]
fn exact_name() {
    assert_eq!(
        pick_by_name(&records(), "vivian sample", true),
        Some("842".to_string())
    );
}

#[test]
fn single_name_alias_is_refused() {
    assert!(!alias_ok("Vivian"));
    assert_eq!(pick_by_name(&records(), "Vivian", alias_ok("Vivian")), None);
}

#[test]
fn multi_word_alias_is_allowed() {
    assert_eq!(
        pick_by_name(&records(), "Janie Example", alias_ok("Janie Example")),
        Some("1019".to_string())
    );
}

// UpdateTest
fn scene() -> Scene {
    scene_of(
        json!({"id": "5", "title": "", "code": "", "details": "", "director": "",
        "date": null, "urls": [], "studio": null, "performers": [],
        "tags": [{"id": "1398"}, {"id": "9"}],
        "stash_ids": [{"endpoint": STASHDB, "stash_id": "old"}]}),
    )
}

fn strs(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

#[test]
fn scrape_update_fills_empty_and_sets_cover() {
    let primary = cand_of(
        json!({"title": "T", "code": "C", "date": "2026-07-23", "urls": ["u"],
        "image": "data:image/jpeg;base64,xx", "details": null}),
    );
    let drop: HashSet<String> = ["1398".to_string()].into();
    let up = to_json(&scrape_update(
        &scene(),
        &primary,
        &Resolved {
            studio_id: Some("161".into()),
            performer_ids: strs(&["1", "2"]),
            tag_ids: strs(&["9", "20"]),
            stash_ids: vec![sid(CODEDB, "new"), sid(STASHDB, "old")],
        },
        &drop,
        false,
    ));
    assert_eq!(
        up,
        json!({"id": "5", "title": "T", "code": "C", "date": "2026-07-23", "urls": ["u"],
            "cover_image": "data:image/jpeg;base64,xx", "studio_id": "161",
            "performer_ids": ["1", "2"], "tag_ids": ["9", "20"],
            "stash_ids": [{"endpoint": STASHDB, "stash_id": "old"}, {"endpoint": CODEDB, "stash_id": "new"}]})
    );
    let keys: Vec<_> = up.as_object().unwrap().keys().cloned().collect();
    assert_eq!(
        keys,
        [
            "id",
            "title",
            "code",
            "date",
            "urls",
            "cover_image",
            "studio_id",
            "performer_ids",
            "tag_ids",
            "stash_ids"
        ]
    );
}

#[test]
fn scrape_update_never_overwrites() {
    let mut s = scene();
    s.title = Some("Mine".into());
    s.studio = Some(StudioRef {
        id: "3".into(),
        name: None,
    });
    let up = to_json(&scrape_update(
        &s,
        &cand_of(json!({"title": "T"})),
        &Resolved {
            studio_id: Some("161".into()),
            ..Resolved::default()
        },
        &HashSet::new(),
        false,
    ));
    assert!(up.get("title").is_none());
    assert!(up.get("studio_id").is_none());
}

#[test]
fn llm_update_tags_guess() {
    let up = to_json(&llm_update(
        &scene(),
        &parse_of(json!({"title": "Guess"})),
        Some("3"),
        &strs(&["4"]),
        "77",
    ));
    assert_eq!(
        up,
        json!({"id": "5", "title": "Guess", "studio_id": "3",
            "performer_ids": ["4"], "tag_ids": ["1398", "9", "77"]})
    );
}

#[test]
fn llm_update_fills_date() {
    let up = to_json(&llm_update(
        &scene(),
        &parse_of(json!({"title": "Guess", "date": "2026-01-02"})),
        None,
        &[],
        "77",
    ));
    assert_eq!(up["date"], "2026-01-02");
}

#[test]
fn llm_update_does_not_overwrite_existing_date() {
    let mut s = scene();
    s.date = Some("2020-01-01".into());
    let up = to_json(&llm_update(
        &s,
        &parse_of(json!({"title": "Guess", "date": "2026-01-02"})),
        None,
        &[],
        "77",
    ));
    assert!(up.get("date").is_none());
}

#[test]
fn llm_update_uses_display_title_fallback() {
    let up = to_json(&llm_update(
        &scene(),
        &parse_of(json!({"title": null, "studio": "X", "date": "2026-01-02"})),
        Some("3"),
        &[],
        "77",
    ));
    assert_eq!(up["title"], "X – 2026-01-02");
    assert_eq!(up["date"], "2026-01-02");
}

#[test]
fn llm_update_no_title_when_nothing_to_build_with() {
    let up = to_json(&llm_update(
        &scene(),
        &parse_of(json!({"title": null, "studio": "X"})),
        Some("3"),
        &[],
        "77",
    ));
    assert!(up.get("title").is_none());
}

// JevTest
#[test]
fn request_and_pick() {
    let cands = vec![
        ep(CODEDB, cand("A", "S", None, Some(100.0))),
        ep(STASHDB, cand("B", "S", None, Some(101.0))),
    ];
    let req = jev_request(
        "dir/file.mp4",
        100.4,
        &parse_of(json!({"studio": "S"})),
        &cands,
    );
    let (state, q) = req.body();
    assert_eq!(state["file_duration_seconds"], 100);
    assert_eq!(state["file_path"], "dir/file.mp4");
    assert_eq!(state["filename_parse"]["studio"], "S");
    let crit = q["match"]["criteria"].as_object().unwrap();
    assert_eq!(
        crit.keys().cloned().collect::<Vec<_>>(),
        ["c0", "c1", "none"]
    );
    assert_eq!(crit["c0"], summary(&cands[0].scene));
    assert_eq!(crit["none"], "None of the candidates is this exact scene.");
    assert_eq!(
        jev_pick(Some("c1"), &cands).unwrap(),
        Some(cands[1].clone())
    );
    assert_eq!(jev_pick(Some("none"), &cands).unwrap(), None);
    assert!(jev_pick(Some("c9"), &cands).is_err());
    assert!(jev_pick(Some("x"), &cands).is_err());
    assert!(jev_pick(None, &cands).is_err());
}

#[test]
fn jev_rounds_half_even() {
    let (state, _) = jev_request("p", 100.5, &Parse::default(), &[]).body();
    assert_eq!(state["file_duration_seconds"], 100);
    let (state, _) = jev_request("p", 101.5, &Parse::default(), &[]).body();
    assert_eq!(state["file_duration_seconds"], 102);
}

#[test]
fn summary_is_json_of_the_identifying_fields() {
    let c = cand_of(
        json!({"title": "A", "studio": {"name": "S"}, "performers": [{"name": "P"}],
        "date": "2024-01-02", "duration": 348}),
    );
    assert_eq!(
        summary(&c),
        r#"{"title":"A","studio":"S","performers":["P"],"date":"2024-01-02","code":null,"duration_seconds":348}"#
    );
    let c = cand_of(json!({"title": "It's", "duration": 0.0}));
    assert_eq!(
        summary(&c),
        r#"{"title":"It's","studio":null,"performers":[],"date":null,"code":null,"duration_seconds":null}"#
    );
}

// CodeTest
#[test]
fn real_codes() {
    for (path, code) in [
        ("ABCD-910.mp4", "ABCD-910"),
        ("WXYZ-796.H265.mp4", "WXYZ-796"),
        ("sub/dir/efgh-795.mp4", "EFGH-795"),
        ("IJKL-601-C.mp4", "IJKL-601"),
        ("MNO-843 remastered.mkv", "MNO-843"),
        ("dl.example@ABCD-910.mp4", "ABCD-910"),
    ] {
        assert_eq!(product_code(path).as_deref(), Some(code), "{path}");
    }
}

#[test]
fn fc2_codes() {
    for (path, code) in [
        ("FC2-PPV-1000001.mp4", "FC2-PPV-1000001"),
        ("FC2-PPV-1000002/FC2-PPV-1000002_1.mp4", "FC2-PPV-1000002"),
        ("dl.example@FC2-PPV-1000003.mp4", "FC2-PPV-1000003"),
        ("fc2ppv-200004.mp4", "FC2-PPV-200004"),
        ("FC2-1000005.mkv", "FC2-PPV-1000005"),
    ] {
        assert_eq!(product_code(path).as_deref(), Some(code), "{path}");
    }
}

#[test]
fn fc2_number_extracts() {
    assert_eq!(fc2_number("FC2-PPV-1000001").as_deref(), Some("1000001"));
    assert_eq!(fc2_number("ABCD-910"), None);
}

#[test]
fn non_code_names_from_the_library() {
    for path in [
        "abcd958_sd.wmv",
        "wxyz0720.mp4",
        "QRS026_s04_1080.mp4",
        "Studio A - Performer A, Performer B aka Performer C - Title (XY) OB643.mp4",
        "3.Titulo.2026.1080p.EN.Tag.Tag.Tag.studio.example.mp4",
        "some-title-here-540p.mp4",
        "18Studio - Performer D - First Title.mp4",
        "studioname.24.08.03.performer.a.and.performer.b.1080p.mp4",
    ] {
        assert_eq!(product_code(path), None, "{path}");
    }
}

// Fc2SceneTest
fn fc2_hit() -> Candidate {
    cand_of(
        json!({"title": "サンプル題名", "code": "FC2-PPV-1000006", "date": "2026-10-04",
        "details": null, "image": "data:img", "studio": {"name": "FC2"},
        "performers": [{"name": "サンプル販売者"}], "tags": [{"name": "タグ", "stored_id": "9"}],
        "urls": ["https://fc2.example/article/1000006/"]}),
    )
}

#[test]
fn seller_becomes_studio_under_fc2_ppv() {
    let hit = fc2_hit();
    let c = fc2_scene(&hit, "Sample Title");
    assert_eq!(
        c,
        cand_of(json!({"title": "Sample Title", "code": "FC2-PPV-1000006",
            "date": "2026-10-04", "details": "サンプル題名", "image": "data:img",
            "studio": {"name": "サンプル販売者", "parent": {"name": "FC2-PPV"}},
            "performers": [], "tags": [{"name": "タグ", "stored_id": "9"}],
            "urls": ["https://fc2.example/article/1000006/"]}))
    );
}

#[test]
fn no_seller_falls_back_to_fc2_ppv() {
    let mut hit = fc2_hit();
    hit.performers.clear();
    hit.details = Some("extra".into());
    let c = fc2_scene(&hit, "T");
    assert_eq!(
        c.studio,
        Some(
            cand_of(json!({"studio": {"name": "FC2-PPV"}}))
                .studio
                .unwrap()
        )
    );
    assert_eq!(c.details.as_deref(), Some("サンプル題名\n\nextra"));
}

// CodeKeyTest
#[test]
fn equivalent_spellings() {
    assert_eq!(code_key(Some("pqrs00402")), Some(("PQRS".to_string(), 402)));
    assert_eq!(code_key(Some("PQRS-402")), code_key(Some("pqrs-402")));
}

#[test]
fn different_codes_and_non_codes() {
    assert_ne!(code_key(Some("STUV-732")), code_key(Some("WXYZ-732")));
    assert_eq!(code_key(None), None);
    assert_eq!(code_key(Some("Snowed In")), None);
}

// SingleSceneTest
#[test]
fn agreeing_hits_give_the_first() {
    let a = cand("EFGH-795", "Studio I", None, None);
    let b = cand("efgh-795", "Studio I", None, None);
    assert_eq!(single_scene(vec![a.clone(), b]), Some(a));
}

#[test]
fn disagreeing_or_empty_give_none() {
    assert_eq!(
        single_scene(vec![
            cand("One", "S", None, None),
            cand("Two", "S", None, None)
        ]),
        None
    );
    assert_eq!(single_scene(vec![]), None);
}

// ScrapeUpdateOverwriteTest
fn codedb_scene() -> Candidate {
    let hit: crate::codedb::CodeHit = serde_json::from_value(json!({
        "external_id": "abcd-910", "slug": "studiok-abcd-910-some-title",
        "title": "ABCD-910 - Some Title", "date": "2026-03-03",
        "description": "d", "duration": 7800, "url": "https://codes.example/code/abcd-910/",
        "poster": "https://thumb/poster", "background": {"full": "https://cdn/bg"},
        "site": {"name": "StudioK"},
        "performers": [{"name": "Performer K", "image": "https://cdn/p1", "parent": {"name": "Performer K"}},
                       {"name": "Performer R.", "image": null, "parent": {"name": "Performer R Full"}}],
    }))
    .unwrap();
    hit.into()
}

fn guessed() -> Scene {
    scene_of(
        json!({"id": "20", "title": "StudioK* – ABCD-910", "code": "", "details": "",
        "director": "", "date": "2026-01-01", "urls": [], "studio": {"id": "s9"},
        "performers": [{"id": "p9"}], "tags": [{"id": "t-llm"}, {"id": "t2"}],
        "stash_ids": []}),
    )
}

#[test]
fn overwrite_replaces_guess_and_drops_llm_tag() {
    let primary = codedb_scene();
    let drop: HashSet<String> = ["t-llm".to_string()].into();
    let up = to_json(&scrape_update(
        &guessed(),
        &primary,
        &Resolved {
            studio_id: Some("s2".into()),
            performer_ids: strs(&["p1"]),
            ..Resolved::default()
        },
        &drop,
        true,
    ));
    assert_eq!(up["title"], "ABCD-910 - Some Title");
    assert_eq!(
        (&up["code"], &up["date"]),
        (&json!("ABCD-910"), &json!("2026-03-03"))
    );
    assert_eq!(up["studio_id"], "s2");
    assert_eq!(up["performer_ids"], json!(["p1"]));
    assert_eq!(up["tag_ids"], json!(["t2"]));
    assert_eq!(up["cover_image"], "https://cdn/bg");
}

#[test]
fn without_overwrite_existing_fields_stay() {
    let primary = codedb_scene();
    let up = to_json(&scrape_update(
        &guessed(),
        &primary,
        &Resolved {
            studio_id: Some("s2".into()),
            performer_ids: strs(&["p1"]),
            ..Resolved::default()
        },
        &HashSet::new(),
        false,
    ));
    assert!(up.get("title").is_none());
    assert!(up.get("studio_id").is_none());
    assert_eq!(up["performer_ids"], json!(["p9", "p1"]));
}

#[test]
fn studio_matches_by_name_alias_or_parent() {
    let c = |s: Value| cand_of(json!({"studio": s}));
    assert!(studio_matches(&c(json!({"name": "StudioA"})), "Studio A"));
    assert!(studio_matches(
        &c(json!({"name": "X", "aliases": "Foo, Studio-A"})),
        "Studio A"
    ));
    assert!(studio_matches(
        &c(json!({"name": "X", "parent": {"name": "studio a"}})),
        "Studio A"
    ));
    assert!(!studio_matches(&c(json!({"name": "Other"})), "Studio A"));
    assert!(!studio_matches(&c(Value::Null), "Studio A"));
    // A name with nothing alphanumeric matches nothing, not every punctuation-only studio.
    assert!(!studio_matches(&c(json!({"name": "--"})), "!"));
}
