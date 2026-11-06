//! The CLI's commands: the `serve` daemon, and each of its jobs once.

use crate::backends::Live;
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::bail;
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::Semaphore;

use crate::app::{self, App};
use crate::config::Config;
use crate::db::Db;
use crate::identify::watch::watch;
use crate::identify::{Clients, PassOpts, Paths, locked_pass, run_pass};
use crate::images::ImageCache;
use crate::jobs::{self, CURATED, GRAB, PRUNE, REFRESH, SWEEP, run_periodic, supervise};
use crate::llm::{self, OpenRouter};
use crate::prowlarr::{self, Prowlarr};
use crate::stash::StashApi;
use crate::tracker::Tracker;
use crate::transmission::Transmission;
use crate::web::{self, WebState};
use crate::{curated, grab, plab, prune as prune_mod, sources};

/// The daemon's tasks, as `serve --tasks` names them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Task {
    Web,
    Identify,
    Refresh,
    Prune,
    Grab,
}

pub fn parse_tasks(names: &[String]) -> anyhow::Result<Vec<Task>> {
    names
        .iter()
        .map(|n| {
            Ok(match n.trim() {
                "web" => Task::Web,
                "identify" => Task::Identify,
                "refresh" => Task::Refresh,
                "prune" => Task::Prune,
                "grab" => Task::Grab,
                other => {
                    bail!(
                        "unknown task {other:?}: expected some of web,identify,refresh,prune,grab"
                    )
                }
            })
        })
        .collect()
}

/// grab's exit status 1: a studio's search failed (the rest still ran).
#[derive(Debug, thiserror::Error)]
#[error("some studio searches failed")]
pub struct SearchesFailed;

fn now_f64() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

// --- the jobs, over whatever the caller built --------------------------------------------

#[allow(clippy::too_many_arguments)]
async fn refresh_with(
    cfg: &Config,
    db: &Db,
    images: &ImageCache,
    tracker: &Tracker,
    torrents: &Transmission,
    classify: Option<&OpenRouter>,
    fetch_slots: &Semaphore,
    prowlarr: Option<&Prowlarr>,
) -> anyhow::Result<()> {
    let ctx = plab::Ctx::<Live> {
        tracker,
        torrents,
        db,
        images,
        state_dir: &cfg.state_dir,
        exclude_file: cfg.exclude_file.as_deref(),
        filter_file: cfg.filter_file.as_deref(),
        download_dir: Config::require(&cfg.download_dir, "PLAB_DOWNLOAD_DIR")?,
        games_dir: cfg.games_dir.as_deref(),
        delay: plab::DELAY,
        fetch_slots,
        prowlarr,
    };
    plab::run_refresh(&ctx, classify, now_f64() as i64).await
}

/// One curated run. The filter and sources files and the scene key are read each run, so
/// editing a secret needs no restart.
#[allow(clippy::too_many_arguments)]
async fn curated_with(
    cfg: &Config,
    db: &Db,
    images: &ImageCache,
    tracker: &Tracker,
    torrents: &Transmission,
    classify: Option<&OpenRouter>,
    fetch_slots: &Semaphore,
    prowlarr: Option<&Prowlarr>,
    stash: &crate::stash::Stash,
) -> anyhow::Result<()> {
    let ctx = plab::Ctx::<Live> {
        tracker,
        torrents,
        db,
        images,
        state_dir: &cfg.state_dir,
        exclude_file: cfg.exclude_file.as_deref(),
        filter_file: cfg.filter_file.as_deref(),
        download_dir: Config::require(&cfg.download_dir, "PLAB_DOWNLOAD_DIR")?,
        games_dir: cfg.games_dir.as_deref(),
        delay: plab::DELAY,
        fetch_slots,
        prowlarr,
    };
    let sources = sources::load(cfg.sources_file.as_deref());
    let key = match stash.codedb_api_key().await {
        Ok(k) => k,
        Err(e) => {
            tracing::warn!("scene key from Stash: {e:#}");
            None
        }
    };
    let scenes = match (sources.as_ref().and_then(|s| s.scene_url.as_deref()), key) {
        (Some(url), Some(key)) => Some(crate::scenes::SceneDb::new(url, &key)),
        _ => None,
    };
    let albums = sources.as_ref().and_then(|s| {
        s.album_index_url
            .as_deref()
            .map(|u| crate::albums::AlbumIndex::new(u, s.album_label(), s.album_mode()))
    });
    let elsewhere = sources.as_ref().map(|s| curated::Elsewhere {
        sources: s,
        scenes: scenes.as_ref(),
        albums: albums.as_ref(),
    });
    curated::run_curated(&ctx, classify, elsewhere, now_f64() as i64).await
}

/// The Vault download dir, then the Games one if set.
fn prune_dirs(cfg: &Config) -> anyhow::Result<Vec<String>> {
    let download = Config::require(&cfg.download_dir, "PLAB_DOWNLOAD_DIR")?;
    Ok([Some(download), cfg.games_dir.as_ref()]
        .into_iter()
        .flatten()
        .filter(|d| !d.is_empty())
        .cloned()
        .collect())
}

async fn prune_with(
    cfg: &Config,
    torrents: &Transmission,
    db: Option<&Db>,
    dry_run: bool,
) -> anyhow::Result<Vec<(i64, String, String)>> {
    let paths = app::paths(cfg);
    let record = db.map(|db| (db, &paths));
    prune_mod::run_prune(torrents, &prune_dirs(cfg)?, now_f64(), dry_run, record).await
}

/// One grab pass. The rules and Prowlarr's key are read each run, so an edit to either
/// needs no restart.
async fn grab_with(
    cfg: &Config,
    db: &Db,
    torrents: &Transmission,
    dry_run: bool,
) -> anyhow::Result<()> {
    let rules = grab::load_rules(Config::require(
        &cfg.grab_rules_file,
        "PLAB_GRAB_RULES_FILE",
    )?)?;
    let key = prowlarr::api_key(Config::require(
        &cfg.prowlarr_config,
        "PLAB_PROWLARR_CONFIG",
    )?)?;
    let src = Prowlarr::new(&cfg.prowlarr_url, key);
    let download = Config::require(&cfg.download_dir, "PLAB_DOWNLOAD_DIR")?;
    let status = grab::run(
        &rules,
        &src,
        torrents,
        db,
        download,
        chrono::Utc::now(),
        dry_run,
    )
    .await?;
    if status != 0 {
        return Err(SearchesFailed.into());
    }
    Ok(())
}

/// The daily pass over the whole library, with Stash's jobs.
async fn sweep(a: &App) -> anyhow::Result<()> {
    tracing::info!("sweep");
    let paths = app::paths(&a.cfg);
    let codedb = app::codedb(&a.stash).await;
    locked_pass(
        &clients(a, &paths, codedb.as_ref())?,
        &a.db,
        &a.pass_lock,
        None,
    )
    .await
}

fn clients<'a>(
    a: &'a App,
    paths: &'a Paths,
    codedb: Option<&'a crate::codedb::CodeDb>,
) -> anyhow::Result<Clients<'a, Live>> {
    Ok(Clients::<Live> {
        stash: &a.stash,
        llm: app::require_openrouter(&a.openrouter)?,
        codedb,
        paths,
        torrents: Some(&a.transmission),
    })
}

/// Every minute, delete the streams nobody has read for `stream::IDLE_SECS`, and retry
/// the deletes that failed earlier.
async fn reap_streams(a: &App) -> anyhow::Result<()> {
    let Some(engine) = a.rqbit.as_ref() else {
        return std::future::pending().await;
    };
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
        a.streams
            .reap_and_delete(engine, chrono::Utc::now().timestamp())
            .await;
    }
}

// --- serve ------------------------------------------------------------------------------

/// The daemon: each task under the supervisor until SIGTERM or Ctrl-C.
pub async fn serve(
    cfg: Config,
    bind: String,
    port: u16,
    stream_port: Option<u16>,
    names: Vec<String>,
) -> anyhow::Result<()> {
    let tasks = parse_tasks(&names)?;
    let app = Arc::new(App::build(cfg)?);
    if tasks.contains(&Task::Identify) {
        app::require_openrouter(&app.openrouter)?;
    }
    if let Err(e) = app.db.close_interrupted() {
        tracing::warn!("closing interrupted job runs: {e:#}");
    }
    // Only the jobs this daemon runs are listed on the jobs page.
    let mon = crate::monitor::global();
    for task in &tasks {
        match task {
            Task::Identify => {
                mon.register("identify");
                mon.register("sweep");
            }
            Task::Refresh => {
                mon.register("refresh");
                mon.register("curated");
            }
            Task::Grab => mon.register("grab"),
            Task::Prune => mon.register("prune"),
            Task::Web => {}
        }
    }
    // One broadcast for the whole daemon: the web handlers hold it in WebState, refresh
    // reaches it through the global.
    let events = crate::events::Events::default();
    crate::events::set_global(events.clone());
    for task in tasks {
        let a = app.clone();
        match task {
            Task::Web => {
                let state = Arc::new(WebState::<Live> {
                    tracker: a.tracker.clone(),
                    torrents: a.transmission.clone(),
                    db: a.db.clone(),
                    images: a.images.clone(),
                    state_dir: a.cfg.state_dir.clone(),
                    exclude_file: a.cfg.exclude_file.clone(),
                    filter_file: a.cfg.filter_file.clone(),
                    download_dir: Config::require(&a.cfg.download_dir, "PLAB_DOWNLOAD_DIR")?
                        .clone(),
                    games_dir: a.cfg.games_dir.clone(),
                    stash_web_url: a.cfg.stash_web_url.clone(),
                    static_dir: a.cfg.static_dir.clone(),
                    fetch_slots: a.fetch_slots.clone(),
                    add_lock: Arc::new(tokio::sync::Mutex::new(())),
                    engine: a.rqbit.clone(),
                    streams: a.streams.clone(),
                    stream_public_url: a.cfg.stream_public_url.clone(),
                    events: events.clone(),
                    monitor: crate::monitor::global().clone(),
                    prowlarr: a.prowlarr.clone(),
                    sources_file: a.cfg.sources_file.clone(),
                    assistant: crate::app::assistant(&a.cfg, crate::llm::OPENROUTER)?.map(Arc::new),
                });
                if let Some(assistant) = &state.assistant {
                    assistant.set_search(Arc::new(web::WebSearch(Arc::downgrade(&state))));
                }
                let pump_state = state.clone();
                let web_state = state.clone();
                let web_bind = bind.clone();
                tokio::spawn(supervise("web", move || {
                    let router = web::router(web_state.clone());
                    let bind = web_bind.clone();
                    async move { web::serve(router, &bind, port).await }
                }));
                if let Some(sp) = stream_port {
                    let bind = bind.clone();
                    tokio::spawn(supervise("stream-web", move || {
                        let router = web::stream_router(state.clone());
                        let bind = bind.clone();
                        async move { web::serve(router, &bind, sp).await }
                    }));
                }
                let reaper = a.clone();
                tokio::spawn(supervise("stream-reaper", move || {
                    let a = reaper.clone();
                    async move { reap_streams(&a).await }
                }));
                tokio::spawn(supervise("events", move || {
                    let st = pump_state.clone();
                    async move { crate::events::pump(st).await }
                }));
            }
            Task::Identify => {
                let b = a.clone();
                tokio::spawn(supervise("identify", move || {
                    let a = a.clone();
                    async move {
                        let paths = app::paths(&a.cfg);
                        let codedb = app::codedb(&a.stash).await;
                        watch(&clients(&a, &paths, codedb.as_ref())?, &a.db, &a.pass_lock).await
                    }
                }));
                tokio::spawn(supervise("sweep", move || {
                    let a = b.clone();
                    async move {
                        let a: &App = &a;
                        run_periodic(a.db.clone(), "sweep", SWEEP, || sweep(a)).await
                    }
                }));
            }
            Task::Refresh => {
                let a_curated = a.clone();
                tokio::spawn(supervise("refresh", move || {
                    let a = a.clone();
                    async move {
                        let a: &App = &a;
                        run_periodic(a.db.clone(), "refresh", REFRESH, || {
                            refresh_with(
                                &a.cfg,
                                &a.db,
                                &a.images,
                                &a.tracker,
                                &a.transmission,
                                a.openrouter.as_ref(),
                                &a.fetch_slots,
                                a.prowlarr.as_deref(),
                            )
                        })
                        .await
                    }
                }));
                let c = a_curated;
                tokio::spawn(supervise("curated", move || {
                    let a = c.clone();
                    async move {
                        let a: &App = &a;
                        run_periodic(a.db.clone(), "curated", CURATED, || {
                            curated_with(
                                &a.cfg,
                                &a.db,
                                &a.images,
                                &a.tracker,
                                &a.transmission,
                                a.openrouter.as_ref(),
                                &a.fetch_slots,
                                a.prowlarr.as_deref(),
                                &a.stash,
                            )
                        })
                        .await
                    }
                }));
            }
            Task::Prune => {
                tokio::spawn(supervise("prune", move || {
                    let a = a.clone();
                    async move {
                        let a: &App = &a;
                        run_periodic(a.db.clone(), "prune", PRUNE, || async move {
                            prune_with(&a.cfg, &a.transmission, Some(&a.db), false)
                                .await
                                .map(drop)
                        })
                        .await
                    }
                }));
            }
            Task::Grab => {
                tokio::spawn(supervise("grab", move || {
                    let a = a.clone();
                    async move {
                        let a: &App = &a;
                        run_periodic(a.db.clone(), "grab", GRAB, || {
                            grab_with(&a.cfg, &a.db, &a.transmission, false)
                        })
                        .await
                    }
                }));
            }
        }
    }
    let mut term = signal(SignalKind::terminate())?;
    tokio::select! {
        r = tokio::signal::ctrl_c() => r?,
        _ = term.recv() => {}
    }
    tracing::info!("stopping");
    Ok(())
}

// --- one-shots --------------------------------------------------------------------------

/// The `refresh` job once. Recorded as the slot's run.
pub async fn refresh(cfg: &Config) -> anyhow::Result<()> {
    let db = app::open_db(cfg)?;
    let images = app::images(cfg)?;
    let tracker = app::tracker(cfg, &db)?;
    let torrents = app::transmission(cfg)?;
    let classify = app::openrouter(cfg, llm::OPENROUTER)?;
    let prowlarr = app::prowlarr(cfg);
    let slots = Semaphore::new(app::FETCH_SLOTS);
    let job = refresh_with(
        cfg,
        &db,
        &images,
        &tracker,
        &torrents,
        classify.as_ref(),
        &slots,
        prowlarr.as_ref(),
    );
    jobs::record(&db, "refresh", job).await
}

/// The `curated` job once. Recorded as the slot's run.
pub async fn curated(cfg: &Config) -> anyhow::Result<()> {
    let db = app::open_db(cfg)?;
    let images = app::images(cfg)?;
    let tracker = app::tracker(cfg, &db)?;
    let torrents = app::transmission(cfg)?;
    let classify = app::openrouter(cfg, llm::OPENROUTER)?;
    let prowlarr = app::prowlarr(cfg);
    let stash = app::stash(cfg);
    let slots = Semaphore::new(app::FETCH_SLOTS);
    let job = curated_with(
        cfg,
        &db,
        &images,
        &tracker,
        &torrents,
        classify.as_ref(),
        &slots,
        prowlarr.as_ref(),
        &stash,
    );
    jobs::record(&db, "curated", job).await
}

/// The `prune` job once: Transmission only, no tracker login. A dry run touches no state,
/// so it never counts as the slot's prune.
pub async fn prune(cfg: &Config, dry_run: bool) -> anyhow::Result<Vec<(i64, String, String)>> {
    let torrents = app::transmission(cfg)?;
    if dry_run {
        return prune_with(cfg, &torrents, None, true).await;
    }
    let db = app::open_db(cfg)?;
    let mut chosen = Vec::new();
    jobs::record(&db, "prune", async {
        chosen = prune_with(cfg, &torrents, Some(&db), false).await?;
        Ok(())
    })
    .await?;
    Ok(chosen)
}

/// The `grab` job once; exit status 1 when a studio's search failed, as vault-grab. A dry
/// run is not recorded.
pub async fn grab(cfg: &Config, dry_run: bool) -> anyhow::Result<ExitCode> {
    let db = app::open_db(cfg)?;
    let torrents = app::transmission(cfg)?;
    let job = grab_with(cfg, &db, &torrents, dry_run);
    let res = if dry_run {
        job.await
    } else {
        jobs::record(&db, "grab", job).await
    };
    match res {
        Ok(()) => Ok(ExitCode::SUCCESS),
        Err(e) if e.is::<SearchesFailed>() => Ok(ExitCode::from(1)),
        Err(e) => Err(e),
    }
}

/// One identify pass, as `stash-identify run`. Without paths it is the LLM step only, as
/// the Python's manual run; with paths, Stash's jobs run on them first unless `no_jobs`.
/// Never recorded as the sweep.
pub async fn identify(
    cfg: &Config,
    dry_run: bool,
    limit: Option<usize>,
    scenes: Vec<String>,
    no_jobs: bool,
    paths: Vec<String>,
) -> anyhow::Result<()> {
    let llm = app::openrouter(cfg, llm::OPENROUTER)?;
    let llm = app::require_openrouter(&llm)?;
    let db = app::open_db(cfg)?;
    let stash = app::stash(cfg);
    let codedb = app::codedb(&stash).await;
    let library = app::paths(cfg);
    let torrents = app::transmission(cfg)?;
    let c = Clients::<Live> {
        stash: &stash,
        llm,
        codedb: codedb.as_ref(),
        paths: &library,
        torrents: Some(&torrents),
    };
    let defaults = stash.defaults().await?;
    let paths = (!paths.is_empty()).then_some(paths);
    let opts = PassOpts {
        jobs: paths.is_some() && !no_jobs,
        dry_run,
        limit,
        scene_ids: (!scenes.is_empty()).then_some(scenes),
    };
    run_pass(&c, &db, &defaults, paths, &opts).await
}

/// `plab set-cookie`: the database only.
pub fn set_cookie(cfg: &Config, value: &str) -> anyhow::Result<()> {
    Tracker::set_cookie(&app::open_db(cfg)?, value)?;
    tracing::info!("cookie saved");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;
    use serde_json::{Value, json};
    use wiremock::{Mock, MockServer, Request, ResponseTemplate, matchers::method};

    /// A config over a temp dir: state and legacy dirs never touch a real path.
    fn cfg(dir: &std::path::Path, vars: Vec<(&'static str, String)>) -> Config {
        let mut vars = vars;
        for (k, sub) in [
            ("PLAB_STATE_DIR", "state"),
            ("PLAB_LEGACY_PLAB_DIR", "legacy-plab"),
            ("PLAB_LEGACY_STASH_IDENTIFY_DIR", "legacy-si"),
            ("PLAB_LEGACY_VAULT_GRAB_DIR", "legacy-vg"),
        ] {
            vars.push((k, dir.join(sub).display().to_string()));
        }
        Config::from_env(move |k| vars.iter().find(|(n, _)| *n == k).map(|(_, v)| v.clone()))
    }

    /// Transmission's RPC with two finished Vault torrents: a public one (pruned at once)
    /// and a tracker one still under its ratio (kept).
    async fn transmission() -> MockServer {
        let server = MockServer::start().await;
        let torrents = json!({"result": "success", "arguments": {"torrents": [
            {"id": 1, "name": "public", "downloadDir": "/v/Vault", "percentDone": 1.0,
             "uploadRatio": 0.0, "doneDate": 100, "activityDate": 100,
             "trackers": [{"announce": "udp://open.example:1337"}]},
            {"id": 2, "name": "lab", "downloadDir": "/v/Vault", "percentDone": 1.0,
             "uploadRatio": 0.1, "doneDate": 2_000_000_000, "activityDate": 2_000_000_000,
             "trackers": [{"announce": "http://bt.tracker.example/ann"}]},
        ]}});
        Mock::given(method("POST"))
            .respond_with(move |req: &Request| {
                if req
                    .headers
                    .get("X-Transmission-Session-Id")
                    .is_none_or(|v| v != "s")
                {
                    return ResponseTemplate::new(409)
                        .insert_header("X-Transmission-Session-Id", "s");
                }
                let body: Value = serde_json::from_slice(&req.body).unwrap();
                match body["method"].as_str() {
                    Some("torrent-get") => {
                        ResponseTemplate::new(200).set_body_json(torrents.clone())
                    }
                    _ => ResponseTemplate::new(200).set_body_json(json!({"result": "success"})),
                }
            })
            .mount(&server)
            .await;
        server
    }

    async fn methods(server: &MockServer) -> Vec<String> {
        server
            .received_requests()
            .await
            .unwrap()
            .iter()
            .map(|r| {
                serde_json::from_slice::<Value>(&r.body).unwrap()["method"]
                    .as_str()
                    .unwrap()
                    .to_string()
            })
            .collect()
    }

    #[tokio::test]
    async fn prune_dry_run_against_transmission() {
        let dir = tempfile::tempdir().unwrap();
        let server = transmission().await;
        let c = cfg(
            dir.path(),
            vec![
                ("PLAB_TRANSMISSION_URL", server.uri()),
                ("PLAB_DOWNLOAD_DIR", "/v/Vault".into()),
            ],
        );
        let chosen = prune(&c, true).await.unwrap();
        assert_eq!(chosen.iter().map(|c| c.0).collect::<Vec<_>>(), vec![1]);
        assert!(
            !methods(&server)
                .await
                .contains(&"torrent-remove".to_string())
        );
        // A dry run touches no state: it must not count as the slot's prune.
        assert!(!dir.path().join("state").exists());
    }

    #[tokio::test]
    async fn prune_removes_and_records_the_job() {
        let dir = tempfile::tempdir().unwrap();
        let server = transmission().await;
        let c = cfg(
            dir.path(),
            vec![
                ("PLAB_TRANSMISSION_URL", server.uri()),
                ("PLAB_DOWNLOAD_DIR", "/v/Vault".into()),
            ],
        );
        prune(&c, false).await.unwrap();
        assert!(
            methods(&server)
                .await
                .contains(&"torrent-remove".to_string())
        );
        let db = Db::open(&dir.path().join("state/state.db")).unwrap();
        assert!(db.job_last_started("prune").unwrap().is_some());
    }

    #[tokio::test]
    async fn prune_needs_no_tracker_credentials_but_needs_transmission() {
        let dir = tempfile::tempdir().unwrap();
        let c = cfg(dir.path(), vec![("PLAB_DOWNLOAD_DIR", "/v".into())]);
        let e = prune(&c, true).await.unwrap_err();
        assert_eq!(e.to_string(), "PLAB_TRANSMISSION_URL is not set");
    }

    #[tokio::test]
    async fn identify_without_key_fails_before_contacting_stash() {
        let dir = tempfile::tempdir().unwrap();
        // An unreachable Stash: reaching it would fail differently.
        let c = cfg(
            dir.path(),
            vec![("PLAB_STASH_URL", "http://127.0.0.1:1/graphql".into())],
        );
        let e = identify(&c, true, None, vec![], false, vec![])
            .await
            .unwrap_err();
        assert!(e.to_string().contains("PLAB_OPENROUTER_KEY_FILE"), "{e:#}");
    }

    #[test]
    fn set_cookie_needs_only_the_database() {
        let dir = tempfile::tempdir().unwrap();
        set_cookie(&cfg(dir.path(), vec![]), "abc").unwrap();
        assert!(dir.path().join("state/state.db").exists());
    }

    #[test]
    fn tasks_parse_and_reject_unknown_names() {
        let names = |s: &str| s.split(',').map(String::from).collect::<Vec<_>>();
        assert_eq!(
            parse_tasks(&names("web,identify,refresh,prune,grab")).unwrap(),
            vec![
                Task::Web,
                Task::Identify,
                Task::Refresh,
                Task::Prune,
                Task::Grab
            ]
        );
        let e = parse_tasks(&names("web,bogus")).unwrap_err();
        assert!(e.to_string().contains("bogus"));
    }
}
