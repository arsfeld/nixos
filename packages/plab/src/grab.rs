//! grab (vault-grab): one 1080p copy of every new scene from the followed studios.
//! Ported from vault-grab/main.py; the Python is the reference.

use std::collections::BTreeSet;
use std::future::Future;
use std::path::Path;
use std::sync::LazyLock;

use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, Datelike, Duration, Timelike, Utc};

use crate::db::{Db, NewDownload, Section};
use crate::prowlarr::{Prowlarr, ProwlarrResult};
use crate::transmission::{TorrentClient, TorrentSource};

const WINDOW_DAYS: i64 = 30;
/// A shorter squashed name is too likely to collide to dedup on.
const MIN_NAME: usize = 8;

static HD: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)\b108[08]p\b").unwrap());
static JUNK: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)\bpack\b|imageset|\d+\s*ролик").unwrap());
static YEAR: LazyLock<fancy_regex::Regex> =
    LazyLock::new(|| fancy_regex::Regex::new(r"(?<!\d)(19\d\d|20\d\d)(?!\d)").unwrap());
static EPISODE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)\bE(\d{3,5})\b").unwrap());
static EPISODE_STRIP: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)\(?\bE\d{3,5}\b\)?").unwrap());
/// Where a release name's tail starts: the site's scene tag, or a bracket.
static TAIL: LazyLock<regex::Regex> = LazyLock::new(|| {
    let tag = regex::escape(&crate::site::get().release_tag);
    regex::Regex::new(&format!(r"\s{tag}\b|\[|\(")).unwrap()
});

pub struct Rule {
    pub name: String,
    pub query: String,
    /// `(?i)^(?:<match>)`: anchored like Python's `re.match`.
    pub pattern: fancy_regex::Regex,
}

impl Rule {
    pub fn compile(name: &str, query: &str, matcher: &str) -> Result<Rule> {
        let pattern = fancy_regex::Regex::new(&format!("(?i)^(?:{matcher})"))
            .map_err(|e| anyhow!("[{name}] match: {e}"))?;
        Ok(Rule {
            name: name.into(),
            query: query.into(),
            pattern,
        })
    }
}

fn log(message: &str) {
    tracing::info!("{message}");
}

fn warn(message: &str) {
    tracing::warn!("{message}");
}

/// The studios in the rules file: `[Name]` blocks of `query =` and `match =`.
pub fn load_rules(path: &Path) -> Result<Vec<Rule>> {
    let text =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let mut blocks: Vec<(String, Option<String>, Option<String>)> = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let n = i + 1;
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') && line.len() >= 2 {
            blocks.push((line[1..line.len() - 1].trim().to_string(), None, None));
            continue;
        }
        let (k, v) = match line.split_once('=') {
            Some((k, v)) if !blocks.is_empty() => (k.trim(), v.trim()),
            _ => bail!("{}:{n}: unexpected line {line:?}", path.display()),
        };
        let block = blocks.last_mut().unwrap();
        match k {
            "query" => block.1 = Some(v.to_string()),
            "match" => block.2 = Some(v.to_string()),
            _ => bail!("{}:{n}: unexpected line {line:?}", path.display()),
        }
    }
    let mut rules = Vec::new();
    for (name, query, matcher) in blocks {
        let mut missing = Vec::new();
        if matcher.is_none() {
            missing.push("match");
        }
        if query.is_none() {
            missing.push("query");
        }
        if !missing.is_empty() {
            bail!("[{name}] is missing {}", missing.join(", "));
        }
        rules.push(Rule::compile(&name, &query.unwrap(), &matcher.unwrap())?);
    }
    Ok(rules)
}

/// Why a Prowlarr result is not a candidate for `rule`, or None if it is one. An `Err` is a
/// malformed result.
pub fn skip_reason(
    rule: &Rule,
    result: &ProwlarrResult,
    now: DateTime<Utc>,
) -> Result<Option<&'static str>> {
    let title = result
        .title
        .as_deref()
        .ok_or_else(|| anyhow!("missing title"))?;
    if result.protocol.as_deref() != Some("torrent") {
        return Ok(Some("not a torrent"));
    }
    if rule.pattern.find(title)?.is_none() {
        return Ok(Some("not this studio")); // anchored: a compilation crediting the studio is not its release
    }
    let published = result
        .publish_date
        .as_deref()
        .ok_or_else(|| anyhow!("missing publishDate"))?;
    let published = DateTime::parse_from_rfc3339(&published.replace('Z', "+00:00"))
        .with_context(|| format!("invalid publish date {published:?}"))?;
    if now.signed_duration_since(published) > Duration::days(WINDOW_DAYS) {
        return Ok(Some("older than the window"));
    }
    if !HD.is_match(title) {
        return Ok(Some("not 1080p"));
    }
    if JUNK.is_match(title) {
        return Ok(Some("pack or image set"));
    }
    for c in YEAR.captures_iter(title) {
        let y: i32 = c?[1].parse()?;
        if y < now.year() - 1 {
            return Ok(Some("old scene re-uploaded"));
        }
    }
    Ok(None)
}

/// The keys one scene is known by, whichever source named it: its episode number and its
/// squashed "performers - title" part.
pub fn scene_keys(rule: &Rule, title: &str) -> BTreeSet<String> {
    let mut keys: BTreeSet<String> = EPISODE
        .captures_iter(title)
        .filter_map(|c| c[1].parse::<u64>().ok())
        .map(|n| format!("ep:{n}"))
        .collect();
    let end = rule
        .pattern
        .find(title)
        .ok()
        .flatten()
        .map_or(0, |m| m.end());
    let rest = EPISODE_STRIP.replace_all(&title[end..], " ");
    let rest = match TAIL.find(&rest) {
        Some(m) => &rest[..m.start()],
        None => &rest,
    };
    let name: String = rest
        .replace('&', "and")
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        .collect();
    if name.len() >= MIN_NAME {
        keys.insert(format!("name:{name}"));
    }
    // The same scene as the other source words it: 1337x leads with a "yy mm dd" date and
    // joins performers with "And", the tracker uses commas and its own performer order. So
    // also key on the sorted words, without the date or "and". It is a second key rather
    // than a new `name:`, so the keys grab_seen already holds keep matching.
    let lower = rest.to_lowercase();
    let mut words: Vec<&str> = lower
        .split(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit()))
        .filter(|w| !w.is_empty())
        .collect();
    if words.len() >= 3
        && words[..3]
            .iter()
            .all(|w| w.len() == 2 && w.bytes().all(|b| b.is_ascii_digit()))
    {
        words.drain(..3);
    }
    words.retain(|w| *w != "and");
    words.sort_unstable();
    words.dedup();
    if words.concat().len() >= MIN_NAME {
        keys.insert(format!("words:{}", words.join("-")));
    }
    keys
}

type Candidate = (ProwlarrResult, BTreeSet<String>);

fn rank(result: &ProwlarrResult) -> (bool, f64) {
    (
        // The tracker has a daily download limit, shared with plab.
        result.indexer.as_deref() == Some(crate::site::get().tracker_indexer.as_str()),
        -result.seeders.unwrap_or(0.0),
    )
}

/// One copy per scene. Copies linked by shared keys, even only through a third copy, are
/// one scene. Prefers an indexer without a daily quota, then more seeders. Each scene
/// carries the union of its copies' keys, so a copy named the other way is recognised later.
pub fn choose(cands: Vec<Candidate>) -> Vec<Candidate> {
    let mut groups: Vec<(Vec<Candidate>, BTreeSet<String>)> = Vec::new();
    for (result, keys) in cands {
        let mut union = keys.clone();
        let mut members = vec![(result, keys.clone())];
        // Linked groups are merged in groups order, their members after the new copy.
        let mut kept = Vec::new();
        for g in groups.drain(..) {
            if g.1.is_disjoint(&keys) {
                kept.push(g);
            } else {
                members.extend(g.0);
                union.extend(g.1);
            }
        }
        groups = kept;
        groups.push((members, union));
    }
    groups
        .into_iter()
        .map(|(members, union)| {
            let mut best = 0;
            for (i, m) in members.iter().enumerate().skip(1) {
                if rank(&m.0) < rank(&members[best].0) {
                    best = i;
                }
            }
            (members.into_iter().nth(best).unwrap().0, union)
        })
        .collect()
}

pub trait GrabSource: Send + Sync {
    fn search(&self, query: &str) -> impl Future<Output = Result<Vec<ProwlarrResult>>> + Send;
    fn fetch(&self, url: &str) -> impl Future<Output = Result<TorrentSource>> + Send;
}

impl GrabSource for Prowlarr {
    async fn search(&self, query: &str) -> Result<Vec<ProwlarrResult>> {
        Prowlarr::search(self, query).await
    }
    async fn fetch(&self, url: &str) -> Result<TorrentSource> {
        Prowlarr::fetch(self, url).await
    }
}

/// Python's `datetime.isoformat()`: microseconds only when non-zero.
fn isoformat(now: DateTime<Utc>) -> String {
    let fmt = if now.nanosecond() / 1000 == 0 {
        "%Y-%m-%dT%H:%M:%S%:z"
    } else {
        "%Y-%m-%dT%H:%M:%S%.6f%:z"
    };
    now.format(fmt).to_string()
}

/// One pass over every studio. Returns the exit code: 1 if any studio's search failed. A
/// failed grab is logged and not recorded, so the next run retries it.
pub async fn run<S: GrabSource, C: TorrentClient>(
    rules: &[Rule],
    src: &S,
    torrents: &C,
    db: &Db,
    download_root: &str,
    now: DateTime<Utc>,
    dry_run: bool,
) -> Result<i32> {
    let mut status = 0;
    for (i, rule) in rules.iter().enumerate() {
        tracing::info!(
            done = i + 1,
            total = rules.len(),
            "[{}] searching",
            rule.name
        );
        let results = match src.search(&rule.query).await {
            Ok(r) => r,
            Err(e) => {
                warn(&format!("[{}] search failed: {e}", rule.name));
                status = 1;
                continue;
            }
        };
        let mut candidates = Vec::new();
        for result in &results {
            let reason = match skip_reason(rule, result, now) {
                Err(e) => {
                    warn(&format!(
                        "[{}] skip (bad result: {e}): {}",
                        rule.name,
                        result.title()
                    ));
                    continue;
                }
                Ok(Some(reason)) => Some(reason),
                Ok(None) => None,
            };
            let mut keys = BTreeSet::new();
            let mut reason = reason;
            if reason.is_none() {
                keys = scene_keys(rule, result.title());
                if keys.is_empty() {
                    reason = Some("no scene key");
                }
            }
            if let Some(reason) = reason {
                if dry_run {
                    log(&format!(
                        "[{}] skip ({reason}): {}",
                        rule.name,
                        result.title()
                    ));
                }
                continue;
            }
            candidates.push((result.clone(), keys));
        }
        let scenes = choose(candidates);
        let mut new = Vec::new();
        for (r, k) in scenes.iter() {
            if !db.grabbed(&rule.name, k)? {
                new.push((r, k));
            }
        }
        log(&format!(
            "[{}] {} results, {} scenes, {} new",
            rule.name,
            results.len(),
            scenes.len(),
            new.len()
        ));
        for (result, keys) in new {
            let indexer = result.indexer.as_deref().unwrap_or("?");
            let label = format!("[{}] {} ({indexer})", rule.name, result.title());
            if dry_run {
                log(&format!("would grab {label}"));
                continue;
            }
            match grab(rule, result, keys, src, torrents, db, download_root, now).await {
                Ok(name) => log(&format!("grabbed {label} as {name:?}")),
                // A failed record after a successful add leaves the copy in Transmission but
                // unrecorded, so the next run may grab it again; the alternative is aborting.
                Err(e) => warn(&format!("grab failed {label}: {e}")),
            }
        }
    }
    Ok(status)
}

#[allow(clippy::too_many_arguments)]
async fn grab<S: GrabSource, C: TorrentClient>(
    rule: &Rule,
    result: &ProwlarrResult,
    keys: &BTreeSet<String>,
    src: &S,
    torrents: &C,
    db: &Db,
    download_root: &str,
    now: DateTime<Utc>,
) -> Result<String> {
    let url = result
        .download_url
        .as_deref()
        .ok_or_else(|| anyhow!("missing downloadUrl"))?;
    let title = result.title();
    let torrent = src.fetch(url).await?;
    let dir = format!("{download_root}/{}", rule.name);
    let added = torrents.add(&torrent, &dir).await?;
    let id = db.mark_added(NewDownload {
        source: "grab",
        topic_id: None,
        release_title: title,
        section: Section::Video,
        download_dir: Some(&dir),
        torrent_hash: added.hash.as_deref(),
        now: now.timestamp(),
    })?;
    db.record_grab(&rule.name, keys, title, &isoformat(now), Some(id))?;
    Ok(added.name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transmission::{Added, Torrent};
    use chrono::TimeZone;
    use serde_json::json;
    use std::sync::Mutex;

    #[test]
    fn log_lines_go_through_tracing() {
        let out = crate::testlog::capture(|| {
            log("grabbed x");
            warn("grab failed x");
        });
        assert!(out.contains("INFO") && out.contains("grabbed x"), "{out}");
        assert!(
            out.contains("WARN") && out.contains("grab failed x"),
            "{out}"
        );
    }

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 24, 12, 0, 0).unwrap()
    }
    fn a() -> Rule {
        Rule::compile("Studio A", "studioa", r"(\[studioa\.com\]|studioa e\d+\b)").unwrap()
    }
    fn b() -> Rule {
        Rule::compile("Studio B", "studiob", r"(\[studiob\.com\]|studio b\s)").unwrap()
    }

    fn res(title: &str) -> ProwlarrResult {
        res_with(
            title,
            "1337x",
            10,
            "2026-10-17T20:00:00Z",
            "http://p/1/download",
        )
    }
    fn res_with(
        title: &str,
        indexer: &str,
        seeders: i64,
        published: &str,
        url: &str,
    ) -> ProwlarrResult {
        serde_json::from_value(
            json!({"title": title, "indexer": indexer, "seeders": seeders, "publishDate": published,
               "downloadUrl": url, "protocol": "torrent"}),
        )
        .unwrap()
    }
    fn set(keys: &[&str]) -> BTreeSet<String> {
        keys.iter().map(|s| s.to_string()).collect()
    }

    fn rules_file(text: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("rules.txt");
        std::fs::write(&p, text).unwrap();
        (dir, p)
    }
    fn load_err(text: &str) -> String {
        let (_d, p) = rules_file(text);
        load_rules(&p).err().expect("expected an error").to_string()
    }

    // LoadRules

    #[test]
    fn load_rules_blocks_and_comments() {
        let (_d, p) = rules_file(
            "# c\n\n[Studio A]\nquery = studioa\nmatch = ^studioa e\\d+\n\n[Studio B]\nquery = studiob\nmatch = ^\\[studiob\\.com\\]\n",
        );
        let rules = load_rules(&p).unwrap();
        assert_eq!(
            rules.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(),
            ["Studio A", "Studio B"]
        );
        assert_eq!(rules[0].query, "studioa");
        assert!(
            rules[1]
                .pattern
                .find("[StudioB.com] X - Y")
                .unwrap()
                .is_some()
        ); // case-insensitive
    }

    #[test]
    fn load_rules_missing_key() {
        assert!(load_err("[Studio A]\nquery = studioa\n").contains("missing match"));
    }

    #[test]
    fn load_rules_unknown_key_and_line_before_block() {
        for text in [
            "[Studio A]\nquery = a\nmatch = a\nsave = x\n",
            "query = a\n",
        ] {
            assert!(load_err(text).contains("unexpected line"), "{text}");
        }
        assert!(load_err("query = a\n").ends_with(":1: unexpected line \"query = a\""));
    }

    #[test]
    fn load_rules_bad_regex() {
        assert!(load_err("[Studio A]\nquery = a\nmatch = ^(a\n").starts_with("[Studio A] match"));
    }

    // SkipReason

    fn reason(title: &str) -> Option<&'static str> {
        skip_reason(&a(), &res(title), now()).unwrap()
    }
    fn reason_b(title: &str) -> Option<&'static str> {
        skip_reason(&b(), &res(title), now()).unwrap()
    }

    #[test]
    fn skip_candidates() {
        assert_eq!(
            reason("StudioA E2283 Ann And Ben How We Dance TAG 1080p MP4 GRP [RG]"),
            None
        );
        assert_eq!(
            reason(
                "[StudioA.com] Cara & Dan - Park & Walk (E2274) [2026-09-29, All beta, Outdoor, 1080p, SiteRip]"
            ),
            None
        );
        assert_eq!(
            reason_b(
                "[StudioB.com] Performer K - Waking to Find You [2026, Alpha, All Beta, 1088p, SiteRip]"
            ),
            None
        );
        assert_eq!(
            reason_b("Studio B   Hailey White   An Evening of Romance (10.06.2026) 1080p"),
            None
        );
    }

    #[test]
    fn skip_480p_twin() {
        assert_eq!(
            reason("StudioA E2283 Ann And Ben How We Dance TAG 480p MP4 TAG [RG]"),
            Some("not 1080p")
        );
    }

    #[test]
    fn skip_studio_must_lead_the_title() {
        assert_eq!(
            reason(
                "Guess the Straight Girl (Other) [2026 г., BDRip, 1080p] (Jane(StudioA - Emanuel & Jane))"
            ),
            Some("not this studio")
        );
    }

    #[test]
    fn skip_window() {
        let r = res_with(
            "StudioA E2100 Some Couple Some Title TAG 1080p",
            "1337x",
            10,
            "2026-09-20T00:00:00Z",
            "u",
        );
        assert_eq!(
            skip_reason(&a(), &r, now()).unwrap(),
            Some("older than the window")
        );
    }

    #[test]
    fn skip_pack_and_imageset() {
        assert_eq!(
            reason("[StudioA.com] Mike & Vika (3 ролика) Pack [2025-2026, 1080p]"),
            Some("pack or image set")
        );
        assert_eq!(
            reason_b("Studio B   Ashby Winter IMAGESET (30.04.2026) 1080p"),
            Some("pack or image set")
        );
    }

    #[test]
    fn skip_old_scene_reuploaded() {
        assert_eq!(
            reason("[StudioA.com] Eve And Finn - Cabin Trip (E769) [2022 г., HDRip, 1080p]"),
            Some("old scene re-uploaded")
        );
        assert_eq!(
            reason("[StudioA.com] Ariel & Kirk - Pull Out Couch [2025-10-13, 1080p, SiteRip]"),
            None
        );
    }

    #[test]
    fn skip_not_a_torrent() {
        let mut r = res("StudioA E1 Some Couple Some Title TAG 1080p");
        r.protocol = Some("usenet".into());
        assert_eq!(skip_reason(&a(), &r, now()).unwrap(), Some("not a torrent"));
    }

    // SceneKeys

    #[test]
    fn keys_both_namings_share_keys() {
        let lab = scene_keys(
            &a(),
            "[StudioA.com] Cara & Dan - Park & Walk (E2274) [2026-09-29, 1080p, SiteRip]",
        );
        let x = scene_keys(
            &a(),
            "StudioA E2274 Cara And Dan Park And Walk TAG 1080p MP4 GRP [RG]",
        );
        assert_eq!(
            lab,
            set(&[
                "ep:2274",
                "name:caraanddanparkandwalk",
                "words:cara-dan-park-walk"
            ])
        );
        assert_eq!(x, lab);
    }

    #[test]
    fn keys_dated_and_reordered_namings_share_a_key() {
        // 1337x leads with the date and joins performers with "And"; the tracker drops the
        // date into its tags, uses commas, and may list the performers the other way round.
        let x = scene_keys(
            &b(),
            "Studio B 26 10 30 Cara Kim And Dana Lee Close To You TAG 1080p MP4 GRP [RG]",
        );
        let lab = scene_keys(
            &b(),
            "[StudioB.com] Dana Lee, Cara Kim - Close To You [2026-10-30, Couples, 1080p, SiteRip]",
        );
        assert!(!x.is_disjoint(&lab), "{x:?} vs {lab:?}");
        assert!(lab.contains("words:cara-close-dana-kim-lee-to-you"));
    }

    #[test]
    fn keys_name_only() {
        assert_eq!(
            scene_keys(
                &b(),
                "[StudioB.com] Sofia Smith - Beauty In The Bath [2026-10-16, 1080p]"
            ),
            set(&[
                "name:sofiasmithbeautyinthebath",
                "words:bath-beauty-in-smith-sofia-the"
            ])
        );
    }

    #[test]
    fn keys_short_name_is_not_a_key() {
        assert_eq!(
            scene_keys(&a(), "StudioA E0042 Ab TAG 1080p"),
            set(&["ep:42"])
        );
        assert_eq!(scene_keys(&b(), "[StudioB.com] Ab [2026, 1080p]"), set(&[]));
    }

    // Choose

    #[test]
    fn choose_non_quota_indexer_wins_then_seeders() {
        let lab = res_with("lab", "TrackerA", 99, "x", "u");
        let weak = res_with("weak", "1337x", 5, "x", "u");
        let strong = res_with("strong", "1337x", 40, "x", "u");
        let scenes = choose(vec![
            (lab, set(&["ep:1", "name:x"])),
            (weak, set(&["ep:1"])),
            (strong.clone(), set(&["name:x"])),
        ]);
        assert_eq!(scenes.len(), 1);
        assert_eq!(scenes[0].0, strong);
        assert_eq!(scenes[0].1, set(&["ep:1", "name:x"]));
    }

    #[test]
    fn choose_distinct_scenes_stay_apart() {
        let scenes = choose(vec![(res("a"), set(&["ep:1"])), (res("b"), set(&["ep:2"]))]);
        assert_eq!(scenes.len(), 2);
    }

    // StateFile (the Db's grab_seen)

    #[test]
    fn state_record_persists_and_matches_any_key() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("plab.db");
        let db = Db::open(&p).unwrap();
        assert!(!db.grabbed("Studio A", &set(&["ep:1"])).unwrap());
        db.record_grab(
            "Studio A",
            &set(&["ep:1", "name:abcdefgh"]),
            "t",
            "2026-10-24T00:00:00+00:00",
            None,
        )
        .unwrap();
        drop(db);
        let again = Db::open(&p).unwrap();
        assert!(again.grabbed("Studio A", &set(&["name:abcdefgh"])).unwrap());
        assert!(!again.grabbed("Studio B", &set(&["ep:1"])).unwrap());
    }

    #[test]
    fn isoformat_matches_python() {
        assert_eq!(isoformat(now()), "2026-10-24T12:00:00+00:00");
        let t = Utc.with_ymd_and_hms(2026, 10, 24, 19, 17, 41).unwrap()
            + Duration::microseconds(530317);
        assert_eq!(isoformat(t), "2026-10-24T19:17:41.530317+00:00");
    }

    // Run

    struct Fake {
        results: Vec<ProwlarrResult>,
        search_fails: bool,
        fail_urls: Vec<String>,
        added: Mutex<Vec<(String, String)>>,
    }
    impl Fake {
        fn new(results: Vec<ProwlarrResult>) -> Fake {
            Fake {
                results,
                search_fails: false,
                fail_urls: vec![],
                added: Mutex::new(vec![]),
            }
        }
        fn added(&self) -> Vec<(String, String)> {
            self.added.lock().unwrap().clone()
        }
    }
    impl GrabSource for Fake {
        async fn search(&self, _: &str) -> Result<Vec<ProwlarrResult>> {
            if self.search_fails {
                bail!("connection refused");
            }
            Ok(self.results.clone())
        }
        async fn fetch(&self, url: &str) -> Result<TorrentSource> {
            if self.fail_urls.iter().any(|u| u == url) {
                bail!("HTTP Error 429: daily limit");
            }
            Ok(TorrentSource::Magnet(format!("magnet:{url}")))
        }
    }
    impl TorrentClient for Fake {
        async fn add(&self, src: &TorrentSource, dir: &str) -> Result<Added> {
            let TorrentSource::Magnet(m) = src else {
                panic!("bytes")
            };
            self.added
                .lock()
                .unwrap()
                .push((m.clone(), dir.to_string()));
            Ok(Added {
                name: "name".into(),
                hash: Some("h".into()),
            })
        }
        async fn torrents(&self) -> Result<Vec<Torrent>> {
            unimplemented!()
        }
        async fn remove(&self, _: &[i64]) -> Result<()> {
            unimplemented!()
        }
    }

    async fn go(f: &Fake, db: &Db, dry_run: bool) -> i32 {
        run(&[a()], f, f, db, "/vault", now(), dry_run)
            .await
            .unwrap()
    }
    fn r(title: &str, url: &str) -> ProwlarrResult {
        res_with(title, "1337x", 10, "2026-10-17T20:00:00Z", url)
    }

    #[tokio::test]
    async fn run_grabs_one_copy_per_scene_into_studio_dir() {
        let db = Db::open_in_memory().unwrap();
        let f = Fake::new(vec![
            r(
                "StudioA E2283 Ann And Ben How We Dance TAG 480p MP4 TAG [RG]",
                "u480",
            ),
            r(
                "StudioA E2283 Ann And Ben How We Dance TAG 1080p MP4 GRP [RG]",
                "u1080",
            ),
            res_with(
                "[StudioA.com] Ann & Ben - How We Dance (E2283) [2026-10-15, 1080p, SiteRip]",
                "TrackerA",
                90,
                "2026-10-17T20:00:00Z",
                "ulab",
            ),
            r("Unrelated Release 1080p", "other"),
        ]);
        assert_eq!(go(&f, &db, false).await, 0);
        assert_eq!(
            f.added(),
            [("magnet:u1080".to_string(), "/vault/Studio A".to_string())]
        );
        assert!(
            db.grabbed("Studio A", &set(&["name:annandbenhowwedance"]))
                .unwrap()
        );
    }

    #[tokio::test]
    async fn run_already_grabbed_is_skipped() {
        let db = Db::open_in_memory().unwrap();
        db.record_grab("Studio A", &set(&["ep:2283"]), "t", "x", None)
            .unwrap();
        let f = Fake::new(vec![r(
            "StudioA E2283 Ann And Ben How We Dance TAG 1080p MP4 [RG]",
            "u",
        )]);
        go(&f, &db, false).await;
        assert!(f.added().is_empty());
    }

    #[tokio::test]
    async fn run_failed_grab_is_not_recorded_and_others_continue() {
        let db = Db::open_in_memory().unwrap();
        let mut f = Fake::new(vec![
            r("StudioA E1001 Some Couple Some Title TAG 1080p", "bad"),
            r("StudioA E1002 Other Couple Other Title TAG 1080p", "good"),
        ]);
        f.fail_urls = vec!["bad".into()];
        assert_eq!(go(&f, &db, false).await, 0);
        assert_eq!(
            f.added(),
            [("magnet:good".to_string(), "/vault/Studio A".to_string())]
        );
        assert!(!db.grabbed("Studio A", &set(&["ep:1001"])).unwrap());
        assert!(db.grabbed("Studio A", &set(&["ep:1002"])).unwrap());
    }

    #[tokio::test]
    async fn run_failed_search_exits_1() {
        let db = Db::open_in_memory().unwrap();
        let mut f = Fake::new(vec![]);
        f.search_fails = true;
        assert_eq!(go(&f, &db, false).await, 1);
    }

    #[tokio::test]
    async fn run_malformed_result_is_skipped_and_run_continues() {
        let db = Db::open_in_memory().unwrap();
        let mut bad = r("StudioA E1001 Some Couple Some Title TAG 1080p", "bad");
        bad.publish_date = None;
        let naive = res_with(
            "StudioA E1003 Third Couple Third Title TAG 1080p",
            "1337x",
            10,
            "2026-10-17T20:00:00",
            "naive",
        );
        let f = Fake::new(vec![
            bad,
            naive,
            r("StudioA E1002 Other Couple Other Title TAG 1080p", "good"),
        ]);
        assert_eq!(go(&f, &db, false).await, 0);
        assert_eq!(
            f.added(),
            [("magnet:good".to_string(), "/vault/Studio A".to_string())]
        );
    }

    #[tokio::test]
    async fn run_failed_state_write_after_add_does_not_stop_the_run() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("plab.db");
        let db = Db::open(&p).unwrap();
        // The first scene's record fails, as a full disk would.
        rusqlite::Connection::open(&p)
            .unwrap()
            .execute_batch(
                "CREATE TRIGGER fail_once BEFORE INSERT ON grab_seen WHEN NEW.scene_key = 'ep:1001'
                 BEGIN SELECT RAISE(ABORT, 'disk full'); END;",
            )
            .unwrap();
        let f = Fake::new(vec![
            r("StudioA E1001 Some Couple Some Title TAG 1080p", "first"),
            r("StudioA E1002 Other Couple Other Title TAG 1080p", "second"),
        ]);
        assert_eq!(go(&f, &db, false).await, 0);
        assert_eq!(
            f.added(),
            [
                ("magnet:first".to_string(), "/vault/Studio A".to_string()),
                ("magnet:second".to_string(), "/vault/Studio A".to_string())
            ]
        );
        assert!(!db.grabbed("Studio A", &set(&["ep:1001"])).unwrap());
        assert!(db.grabbed("Studio A", &set(&["ep:1002"])).unwrap());
    }

    #[tokio::test]
    async fn run_dry_run_writes_nothing() {
        let db = Db::open_in_memory().unwrap();
        let f = Fake::new(vec![r(
            "StudioA E1001 Some Couple Some Title TAG 1080p",
            "u",
        )]);
        go(&f, &db, true).await;
        assert!(f.added().is_empty());
        assert!(!db.grabbed("Studio A", &set(&["ep:1001"])).unwrap());
    }
}
