use super::*;
use crate::db::{DownloadRow, Listed, Listing, Production, Section, Topic};
use crate::provenance::{Failure, Status};
use crate::tracker::parse::Row;
use serde_json::{Value, json};

const COVER: &str = "https://i128.fastpic.org/big/2026/1004/19/cover.jpg";

fn row(id: u64, title: &str, seeders: u32) -> Row {
    Row {
        id,
        title: title.into(),
        forum: 1875,
        size: 2048,
        seeders,
        leechers: 1,
        completed: 0,
        added: 1000,
    }
}

fn listed(row: Row, class: Option<&str>, images: Option<&[&str]>) -> Listed {
    Listed {
        topic: Topic {
            row,
            images: images.map(|v| v.iter().map(|s| s.to_string()).collect()),
            production: class.map(|c| Production {
                class: c.into(),
                confidence: None,
            }),
        },
        filters: vec![],
        curated_reason: None,
    }
}

fn listing(topics: Vec<Listed>) -> Listing {
    Listing {
        updated: 900,
        filters: vec!["couples".into()],
        topics,
    }
}

fn reply(
    l: &Listing,
    added: &[u64],
    queued: &[u64],
    d: &Downloads,
    search: Option<SearchReply>,
) -> Value {
    let added = added.iter().copied().collect();
    let queued = queued.iter().copied().collect();
    let externals = Default::default();
    serde_json::to_value(list(
        l,
        &[],
        &crate::same::Owned::new(&[], &[]),
        &[],
        &added,
        &queued,
        5000,
        Section::Video,
        d,
        search,
        &externals,
    ))
    .unwrap()
}

fn list_with_externals(
    id: u64,
    externals: &std::collections::HashMap<u64, crate::db::External>,
) -> ListDto {
    let l = listing(vec![listed(row(id, "alpha", 3), None, None)]);
    list(
        &l,
        &[],
        &crate::same::Owned::new(&[], &[]),
        &[],
        &HashSet::new(),
        &HashSet::new(),
        5000,
        Section::Video,
        &Downloads::default(),
        None,
        externals,
    )
}

#[test]
fn a_card_says_what_kind_of_release_it_is() {
    let id = crate::db::EXTERNAL_BASE;
    let ext = |kind, files| {
        let mut m = std::collections::HashMap::new();
        m.insert(
            id,
            crate::db::External {
                id,
                indexer: "Album index A".into(),
                link: "https://files.example/a/AbC123".into(),
                info_url: Some("https://files.example/a/AbC123".into()),
                scene_id: None,
                kind,
                files,
                first_seen: 0,
            },
        );
        m
    };
    let album = list_with_externals(id, &ext(crate::db::Kind::Album, Some(3)));
    assert_eq!(
        (album.topics[0].kind, album.topics[0].files),
        ("album", Some(3))
    );
    let torrent = list_with_externals(id, &ext(crate::db::Kind::Torrent, None));
    assert_eq!(torrent.topics[0].kind, "torrent");
    let tracker = list_with_externals(5, &ext(crate::db::Kind::Album, Some(3)));
    assert_eq!(
        (tracker.topics[0].kind, tracker.topics[0].files),
        ("tracker", None)
    );
}

#[test]
fn an_external_card_carries_its_indexer_and_page() {
    let mut externals = std::collections::HashMap::new();
    let id = crate::db::EXTERNAL_BASE;
    externals.insert(
        id,
        crate::db::External {
            id,
            indexer: "Indexer A".into(),
            link: "http://p/1".into(),
            info_url: Some("http://a/1".into()),
            scene_id: None,
            kind: crate::db::Kind::Torrent,
            files: None,
            first_seen: 0,
        },
    );
    let dto = list_with_externals(id, &externals);
    assert_eq!(dto.topics[0].source.as_deref(), Some("Indexer A"));
    assert_eq!(dto.topics[0].link.as_deref(), Some("http://a/1"));
    let tracker = list_with_externals(5, &externals);
    assert_eq!(
        (
            tracker.topics[0].source.clone(),
            tracker.topics[0].link.clone()
        ),
        (None, None)
    );
}

#[test]
fn only_http_release_pages_become_links() {
    let id = crate::db::EXTERNAL_BASE;
    let link_for = |url: &str| {
        let mut externals = std::collections::HashMap::new();
        externals.insert(
            id,
            crate::db::External {
                id,
                indexer: "Indexer A".into(),
                link: "http://p/1".into(),
                info_url: Some(url.into()),
                scene_id: None,
                kind: crate::db::Kind::Torrent,
                files: None,
                first_seen: 0,
            },
        );
        list_with_externals(id, &externals).topics[0].link.clone()
    };
    assert_eq!(link_for("javascript:alert(1)"), None);
    assert_eq!(link_for("data:text/html,x"), None);
    assert_eq!(
        link_for("HTTPS://a.example/1").as_deref(),
        Some("HTTPS://a.example/1")
    );
}

fn ids(v: &Value) -> Vec<u64> {
    v["topics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["id"].as_u64().unwrap())
        .collect()
}

#[test]
fn topics_rank_by_production_weighted_seeders() {
    // industrial 40 × 0.25 = 10 < amateur 10 × 1.5 = 15 < unclassified 20 × 1.0
    let l = listing(vec![
        listed(row(1, "A", 40), Some("industrial"), None),
        listed(row(2, "B", 10), Some("amateur"), None),
        listed(row(3, "C", 20), None, None),
    ]);
    let v = reply(&l, &[], &[], &Downloads::default(), None);
    assert_eq!(ids(&v), [3, 2, 1]);
    assert_eq!(v["topics"][0]["production"], Value::Null);
    assert_eq!(v["topics"][1]["production"], "amateur");
    assert_eq!(v["topics"][2]["production"], "industrial");
}

#[test]
fn artistic_is_the_name_of_pro_artistic() {
    let l = listing(vec![listed(row(1, "A", 1), Some("pro_artistic"), None)]);
    assert_eq!(
        reply(&l, &[], &[], &Downloads::default(), None)["topics"][0]["production"],
        "artistic"
    );
}

#[test]
fn a_topic_carries_its_row_and_labels() {
    let title = "[Studio Name] Alice, Bob - A Scene Title (2026) [1080p]";
    let l = listing(vec![listed(row(7, title, 3), None, None)]);
    let t = &reply(&l, &[], &[], &Downloads::default(), None)["topics"][0];
    let lab = crate::labels::labels(title, 1875);
    assert_eq!(t["title"], title);
    assert_eq!(t["name"], lab.name);
    assert_eq!(t["studio"], json!(lab.studio));
    assert_eq!(t["quality"], json!(lab.quality));
    assert_eq!(t["category"], lab.category);
    assert_eq!(t["tags"], json!(lab.tags));
    assert_eq!(
        (
            t["size"].clone(),
            t["seeders"].clone(),
            t["leechers"].clone(),
            t["added"].clone()
        ),
        (json!(2048), json!(3), json!(1), json!(1000))
    );
    assert_eq!(t["filters"], json!([]));
}

#[test]
fn images_are_null_empty_or_keys() {
    let l = listing(vec![
        listed(row(1, "A", 3), None, None),
        listed(row(2, "B", 2), None, Some(&[])),
        listed(row(3, "C", 1), None, Some(&[COVER])),
    ]);
    let v = reply(&l, &[], &[], &Downloads::default(), None);
    assert_eq!(v["topics"][0]["images"], Value::Null);
    assert_eq!(v["topics"][1]["images"], json!([]));
    assert_eq!(v["topics"][2]["images"], json!([crate::images::key(COVER)]));
}

#[test]
fn state_and_pending_come_from_added_and_queued() {
    let l = listing(vec![
        listed(row(1, "A", 3), None, None),
        listed(row(2, "B", 2), None, None),
        listed(row(3, "C", 1), None, None),
    ]);
    let v = reply(&l, &[1], &[1, 2], &Downloads::default(), None);
    let states: Vec<&str> = v["topics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["state"].as_str().unwrap())
        .collect();
    assert_eq!(states, ["added", "queued", ""]);
    assert_eq!(v["pending"], 1);
}

#[test]
fn the_list_names_its_section_and_inputs() {
    let v = reply(&listing(vec![]), &[], &[], &Downloads::default(), None);
    assert_eq!(v["section"], "video");
    assert_eq!(
        (v["now"].clone(), v["updated"].clone()),
        (json!(5000), json!(900))
    );
    assert_eq!(
        v["topicUrl"],
        "https://tracker.example/forum/viewtopic.php?t="
    );
    assert_eq!(v["curatedFilters"], json!(["couples"]));
    assert!(v.get("query").is_none() && v.get("error").is_none());
}

#[test]
fn a_search_reply_adds_query_and_error() {
    let s = SearchReply {
        query: "alpha".into(),
        error: None,
    };
    let v = reply(&listing(vec![]), &[], &[], &Downloads::default(), Some(s));
    assert_eq!(v["query"], "alpha");
    assert!(v.as_object().unwrap().contains_key("error") && v["error"].is_null());
}

#[test]
fn statuses_serialize_by_kind() {
    let cases = [
        (Status::Queued, None, json!({"kind": "queued"})),
        (
            Status::Downloading(42),
            None,
            json!({"kind": "downloading", "percent": 42}),
        ),
        (Status::Added, None, json!({"kind": "added"})),
        (
            Status::InStash {
                scenes: vec!["7".into()],
                folder: None,
            },
            Some("https://s/scenes/7".to_string()),
            json!({"kind": "inStash", "link": "https://s/scenes/7"}),
        ),
        (
            Status::Identified {
                label: "Studio – Title".into(),
                more: 2,
                guess: true,
                scenes: vec![],
                folder: None,
            },
            None,
            json!({"kind": "identified", "label": "Studio – Title", "more": 2, "guess": true, "link": null}),
        ),
        (
            Status::Failed(Failure::Transmission("stalled".into())),
            None,
            json!({"kind": "failed", "reason": "download", "detail": "stalled"}),
        ),
        (
            Status::Failed(Failure::Identify),
            None,
            json!({"kind": "failed", "reason": "identify", "detail": "identify found nothing or gave up"}),
        ),
        (
            Status::Failed(Failure::Lost),
            None,
            json!({"kind": "failed", "reason": "lost", "detail": "the torrent is gone and no scene came of it"}),
        ),
    ];
    for (s, link, want) in cases {
        assert_eq!(serde_json::to_value(status(&s, link)).unwrap(), want);
    }
}

#[test]
fn a_topic_with_a_download_carries_its_status() {
    let l = listing(vec![
        listed(row(1, "A", 2), None, None),
        listed(row(2, "B", 1), None, None),
    ]);
    let d = Downloads {
        by_topic: HashMap::from([(1, Status::Downloading(50))]),
        ..Downloads::default()
    };
    let v = reply(&l, &[1], &[], &d, None);
    assert_eq!(
        v["topics"][0]["status"],
        json!({"kind": "downloading", "percent": 50})
    );
    assert_eq!(v["topics"][1]["status"], Value::Null);
}

#[test]
fn grabs_carry_studio_title_age_and_status() {
    let r = DownloadRow {
        id: 1,
        source: "grab".into(),
        topic_id: None,
        release_title: "Rel".into(),
        studio: Some("Studio".into()),
        state: "added".into(),
        hash: None,
        added_at: Some(900),
        files_synced: false,
        files: vec![],
    };
    let d = Downloads {
        grabs: vec![(r, Status::Added)],
        ..Downloads::default()
    };
    assert_eq!(
        serde_json::to_value(grabs(&d, 1000)).unwrap(),
        json!({"now": 1000, "grabs": [{"studio": "Studio", "title": "Rel", "addedAt": 900, "status": {"kind": "added"}}]})
    );
}

#[test]
fn jobs_list_registered_jobs_in_order_with_history_and_next_slot() {
    let m = Monitor::default();
    m.register("prune");
    m.register("identify");
    m.set_state("identify", LiveState::Watching { pending: 2 });
    m.set_state("prune", LiveState::Running { since: 990 });
    let db = Db::open_in_memory().unwrap();
    let id = db.history_start("prune", 900).unwrap();
    db.history_finish(id, "prune", 950, Some("boom")).unwrap();
    let v = serde_json::to_value(jobs(&m, &db, 1000)).unwrap();
    assert_eq!(v["now"], 1000);
    assert_eq!(v["jobs"].as_array().unwrap().len(), 2);
    let (idf, pr) = (&v["jobs"][0], &v["jobs"][1]);
    assert_eq!(
        (
            idf["name"].clone(),
            idf["state"].clone(),
            idf["pending"].clone()
        ),
        (json!("identify"), json!("watching"), json!(2))
    );
    assert_eq!(
        (
            idf["next"].clone(),
            idf["since"].clone(),
            idf["restart_at"].clone()
        ),
        (Value::Null, Value::Null, Value::Null)
    );
    assert_eq!(
        (pr["state"].clone(), pr["since"].clone()),
        (json!("running"), json!(990))
    );
    assert_eq!(pr["next"], crate::jobs::next_slot(crate::jobs::PRUNE, 1000));
    assert_eq!(
        pr["runs"],
        json!([{"started": 900, "finished": 950, "ok": false, "error": "boom"}])
    );
    assert_eq!(
        (
            pr["step"].clone(),
            pr["progress"].clone(),
            pr["lines"].clone()
        ),
        (Value::Null, Value::Null, json!([]))
    );
}

// One card per scene (design: 2026-11-06-plab-dedup-design.md).

const TRACKER: &str =
    "[StudioB.com] Dana Lee, Cara Kim - Close To You [2026-10-30, Couples, 1080p, SiteRip]";
const OTHER: &str = "Studio B 26 10 30 Cara Kim And Dana Lee Close To You TAG 1080p MP4 GRP [RG]";
const E: u64 = crate::db::EXTERNAL_BASE;

fn ext(id: u64, kind: crate::db::Kind) -> crate::db::External {
    crate::db::External {
        id,
        indexer: "Indexer A".into(),
        link: format!("http://p/{id}"),
        info_url: Some(format!("http://a/{id}")),
        scene_id: None,
        kind,
        files: None,
        first_seen: 0,
    }
}

fn with_filters(mut l: Listed, f: &[&str]) -> Listed {
    l.filters = f.iter().map(|s| s.to_string()).collect();
    l
}

/// The list as `section` serves it, with `others` the other tab's topics. Every id from
/// EXTERNAL_BASE up is an indexer release of `kind`.
fn deduped(
    section: Section,
    mine: Vec<Listed>,
    others: Vec<Listed>,
    owned: &crate::same::Owned,
    d: &Downloads,
    kind: crate::db::Kind,
) -> Value {
    let externals: HashMap<u64, crate::db::External> = mine
        .iter()
        .chain(&others)
        .map(|l| l.topic.row.id)
        .filter(|&id| id >= E)
        .map(|id| (id, ext(id, kind)))
        .collect();
    serde_json::to_value(list(
        &listing(mine),
        &others,
        owned,
        &[],
        &HashSet::new(),
        &HashSet::new(),
        5000,
        section,
        d,
        None,
        &externals,
    ))
    .unwrap()
}

fn nobody() -> crate::same::Owned {
    crate::same::Owned::new(&[], &[])
}

fn torrent(section: Section, mine: Vec<Listed>, others: Vec<Listed>) -> Value {
    deduped(
        section,
        mine,
        others,
        &nobody(),
        &Downloads::default(),
        crate::db::Kind::Torrent,
    )
}

#[test]
fn a_tracker_and_an_indexer_release_of_one_scene_are_one_card() {
    let v = torrent(
        Section::Video,
        vec![listed(row(1, TRACKER, 5), None, None)],
        vec![listed(row(E, OTHER, 42), None, None)],
    );
    assert_eq!(ids(&v), vec![1]);
    let also = &v["topics"][0]["also"];
    assert_eq!(also[0]["id"], json!(E));
    assert_eq!(also[0]["source"], json!("Indexer A"));
    assert_eq!(also[0]["seeders"], json!(42));
    assert_eq!(also[0]["link"], json!(format!("http://a/{E}")));
}

#[test]
fn indexers_tab_drops_a_scene_the_tracker_has() {
    let v = torrent(
        Section::Indexers,
        vec![listed(row(E, OTHER, 42), None, None)],
        vec![listed(row(1, TRACKER, 5), None, None)],
    );
    assert_eq!(ids(&v), Vec::<u64>::new());
}

#[test]
fn two_indexer_releases_of_one_scene_keep_the_better_seeded() {
    let v = torrent(
        Section::Indexers,
        vec![
            listed(row(E, OTHER, 3), None, None),
            listed(
                row(
                    E + 1,
                    "Studio B 26 10 30 Cara Kim And Dana Lee Close To You 720p MP4",
                    9,
                ),
                None,
                None,
            ),
        ],
        vec![],
    );
    assert_eq!(ids(&v), vec![E + 1]);
    assert_eq!(v["topics"][0]["also"][0]["id"], json!(E));
}

#[test]
fn a_merged_card_carries_every_members_filters() {
    let v = torrent(
        Section::Video,
        vec![with_filters(listed(row(1, TRACKER, 5), None, None), &["a"])],
        vec![with_filters(
            listed(row(E, OTHER, 9), None, None),
            &["b", "a"],
        )],
    );
    assert_eq!(v["topics"][0]["filters"], json!(["a", "b"]));
}

#[test]
fn a_scene_downloaded_through_another_release_is_owned() {
    let owned = crate::same::Owned::new(
        &[crate::same::DownloadTitle {
            id: 5,
            topic_id: None,
            title: OTHER.into(),
        }],
        &[],
    );
    let d = Downloads {
        by_download: HashMap::from([(5, Status::Downloading(50))]),
        ..Downloads::default()
    };
    let v = deduped(
        Section::Video,
        vec![listed(row(1, TRACKER, 5), None, None)],
        vec![],
        &owned,
        &d,
        crate::db::Kind::Torrent,
    );
    assert_eq!(v["topics"][0]["ownedBy"], json!(5));
    assert_eq!(
        v["topics"][0]["status"],
        json!({"kind": "downloading", "percent": 50})
    );
}

#[test]
fn a_download_without_a_live_status_reads_added() {
    // Owned, but outside the 30-day live window: no status to show but "added".
    let owned = crate::same::Owned::new(
        &[crate::same::DownloadTitle {
            id: 6,
            topic_id: Some(99),
            title: OTHER.into(),
        }],
        &[],
    );
    let v = deduped(
        Section::Video,
        vec![listed(row(1, TRACKER, 5), None, None)],
        vec![listed(row(E, OTHER, 9), None, None)],
        &owned,
        &Downloads::default(),
        crate::db::Kind::Torrent,
    );
    assert_eq!(v["topics"][0]["ownedBy"], json!(6));
    assert_eq!(v["topics"][0]["status"], json!({"kind": "added"}));
    assert_eq!(v["topics"][0]["also"][0]["state"], json!("added"));
}

#[test]
fn a_queued_download_makes_its_scene_owned() {
    let owned = crate::same::Owned::new(
        &[crate::same::DownloadTitle {
            id: 8,
            topic_id: Some(99),
            title: OTHER.into(),
        }],
        &[],
    );
    let d = Downloads {
        by_download: HashMap::from([(8, Status::Queued)]),
        ..Downloads::default()
    };
    let v = deduped(
        Section::Video,
        vec![listed(row(1, TRACKER, 5), None, None)],
        vec![],
        &owned,
        &d,
        crate::db::Kind::Torrent,
    );
    assert_eq!(v["topics"][0]["ownedBy"], json!(8));
    assert_eq!(v["topics"][0]["status"], json!({"kind": "queued"}));
}

#[test]
fn albums_are_never_grouped() {
    let v = deduped(
        Section::Albums,
        vec![
            listed(row(E, OTHER, 0), None, None),
            listed(row(E + 1, OTHER, 0), None, None),
        ],
        vec![],
        &nobody(),
        &Downloads::default(),
        crate::db::Kind::Album,
    );
    assert_eq!(ids(&v).len(), 2);
}

#[test]
fn undated_releases_are_never_merged_or_owned() {
    let undated = "Studio B Cara Kim And Dana Lee Close To You 1080p";
    let owned = crate::same::Owned::new(
        &[crate::same::DownloadTitle {
            id: 5,
            topic_id: None,
            title: undated.into(),
        }],
        &[],
    );
    let v = deduped(
        Section::Video,
        vec![listed(row(1, undated, 5), None, None)],
        vec![listed(row(E, undated, 9), None, None)],
        &owned,
        &Downloads::default(),
        crate::db::Kind::Torrent,
    );
    assert_eq!(ids(&v), vec![1]);
    assert_eq!(v["topics"][0]["also"], json!([]));
    assert_eq!(v["topics"][0]["ownedBy"], Value::Null);
}

#[test]
fn a_card_without_duplicates_has_no_also_and_no_owner() {
    let v = torrent(
        Section::Video,
        vec![listed(row(1, TRACKER, 5), None, None)],
        vec![],
    );
    assert_eq!(v["topics"][0]["also"], json!([]));
    assert_eq!(v["topics"][0]["ownedBy"], Value::Null);
}
