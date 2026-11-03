//! Port of lab.py's test_lab.py. The Python tests hand Lab a fake opener that answers each
//! request with the next canned response (LOGGED_IN once they run out), whatever the URL;
//! `Seq` is that opener as a wiremock responder, and `calls` its record of requests.

use super::*;
use std::collections::VecDeque;
use wiremock::matchers::{any, header, method, path};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

const LOGGED_OUT: &str = r#"<html><form action="/forum/login.php"></form></html>"#;
const LOGGED_IN: &str =
    r#"<html>[ <a onclick="return post2url('login.php', {logout: 1});">Выход</a> ]</html>"#;
const CAPTCHA: &str = r#"<html><input type="hidden" name="cap_sid" value="x"></html>"#;

fn cp(s: &str) -> Vec<u8> {
    encoding_rs::WINDOWS_1251.encode(s).0.into_owned()
}

fn fixture(name: &str) -> Vec<u8> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    cp(&std::fs::read_to_string(path).unwrap())
}

struct Seq(std::sync::Mutex<VecDeque<Vec<u8>>>);

impl Respond for Seq {
    fn respond(&self, _: &Request) -> ResponseTemplate {
        let body = self
            .0
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| cp(LOGGED_IN));
        ResponseTemplate::new(200).set_body_bytes(body)
    }
}

struct Lab {
    server: MockServer,
    db: Db,
    t: Tracker,
}

impl Lab {
    async fn new(responses: Vec<Vec<u8>>) -> Lab {
        Lab::with_db(Db::open_in_memory().unwrap(), responses).await
    }

    async fn with_db(db: Db, responses: Vec<Vec<u8>>) -> Lab {
        let server = MockServer::start().await;
        Mock::given(any())
            .respond_with(Seq(std::sync::Mutex::new(responses.into())))
            .mount(&server)
            .await;
        let base = format!("{}/forum/", server.uri());
        let t = Tracker::new(&base, "user".into(), "pдssword".into(), db.clone());
        Lab { server, db, t }
    }

    /// (path and query, body of a POST) per request, in order. (wiremock rebuilds the
    /// request URL with a placeholder host, so the origin is not compared.)
    async fn calls(&self) -> Vec<(String, Option<Vec<u8>>)> {
        self.server
            .received_requests()
            .await
            .unwrap()
            .into_iter()
            .map(|r| {
                let body = (r.method.as_str() == "POST").then(|| r.body.clone());
                let url = match r.url.query() {
                    Some(q) => format!("{}?{q}", r.url.path()),
                    None => r.url.path().to_string(),
                };
                (url, body)
            })
            .collect()
    }

    async fn urls(&self) -> Vec<String> {
        self.calls().await.into_iter().map(|(u, _)| u).collect()
    }

    async fn login_posts(&self) -> usize {
        let login = "/forum/login.php".to_string();
        self.urls().await.iter().filter(|u| **u == login).count()
    }

    fn jar(&self) -> CookieJar {
        self.t.session.lock().unwrap().jar.clone()
    }
}

fn re(p: &str) -> fancy_regex::Regex {
    fancy_regex::Regex::new(p).unwrap()
}

/// Excludes id 3313754 of the fixture by title.
fn not_3313754() -> Vec<fancy_regex::Regex> {
    vec![re(r"Studio\.com")]
}

/// Excludes id 3314001 of the fixture by title.
fn not_3314001() -> Vec<fancy_regex::Regex> {
    vec![re(r"It's A Test")]
}

fn login_err(r: Result<impl std::fmt::Debug, TrackerError>) -> String {
    match r {
        Err(TrackerError::Login(m)) => m,
        other => panic!("expected a login error, got {other:?}"),
    }
}

#[tokio::test]
async fn page_when_logged_in_does_not_log_in() {
    let lab = Lab::new(vec![fixture("tracker.html")]).await;
    assert!(lab.t.page("tracker.php").await.unwrap().contains("tor-tbl"));
    assert_eq!(lab.calls().await.len(), 1);
}

#[tokio::test]
async fn page_logs_in_when_logged_out() {
    let lab = Lab::new(vec![cp(LOGGED_OUT), cp(LOGGED_IN), fixture("tracker.html")]).await;
    assert!(lab.t.page("tracker.php").await.unwrap().contains("tor-tbl"));
    let (url, data) = lab.calls().await.swap_remove(1);
    assert_eq!(url, "/forum/login.php");
    let data = String::from_utf8(data.unwrap()).unwrap();
    assert!(data.contains("login_username=user"), "{data}");
    assert!(data.contains("login_password=p%E4ssword"), "{data}"); // cp1251, as the form expects
    assert!(data.contains("login=%C2%F5%EE%E4"), "{data}");
}

#[tokio::test]
async fn captcha_raises() {
    let lab = Lab::new(vec![cp(LOGGED_OUT), cp(CAPTCHA)]).await;
    assert!(login_err(lab.t.page("tracker.php").await).contains("captcha"));
}

#[tokio::test]
async fn login_failed_without_captcha_raises() {
    let lab = Lab::new(vec![cp(LOGGED_OUT), cp("<html>wrong password</html>")]).await;
    assert_eq!(login_err(lab.t.page("tracker.php").await), "login failed");
    assert_eq!(lab.calls().await.len(), 2);
}

#[tokio::test]
async fn failed_login_backs_off_without_posting_again() {
    let lab = Lab::new(vec![cp(LOGGED_OUT), cp(CAPTCHA), cp(LOGGED_OUT)]).await;
    assert!(login_err(lab.t.page("tracker.php").await).contains("captcha"));
    assert!(login_err(lab.t.page("tracker.php").await).contains("captcha"));
    assert!(login_err(lab.t.login(lab.t.logins()).await).contains("captcha"));
    let posts: Vec<String> = lab
        .calls()
        .await
        .into_iter()
        .filter(|(_, d)| d.is_some())
        .map(|(u, _)| u)
        .collect();
    assert_eq!(posts, vec!["/forum/login.php"]);
}

#[tokio::test]
async fn login_is_tried_again_after_the_backoff() {
    let lab = Lab::new(vec![cp(LOGGED_OUT), cp(CAPTCHA), cp(LOGGED_IN)]).await;
    login_err(lab.t.page("tracker.php").await);
    {
        let mut state = lab.t.login.lock().await;
        let (msg, at) = state.failure.take().unwrap();
        let earlier = at
            .checked_sub(Duration::from_secs(LOGIN_BACKOFF + 1))
            .unwrap();
        state.failure = Some((msg, earlier));
    }
    lab.t.login(lab.t.logins()).await.unwrap();
    assert_eq!(lab.calls().await.len(), 3);
}

#[tokio::test]
async fn new_cookie_file_clears_the_login_backoff() {
    let lab = Lab::new(vec![
        cp(LOGGED_OUT),
        cp(CAPTCHA),
        cp(LOGGED_OUT),
        cp(LOGGED_OUT),
        cp(LOGGED_IN),
        fixture("tracker.html"),
    ])
    .await;
    login_err(lab.t.page("tracker.php").await);
    Tracker::set_cookie(&lab.db, "fresh").unwrap();
    // reloads, still out, logs in again
    assert!(lab.t.page("tracker.php").await.unwrap().contains("tor-tbl"));
    assert_eq!(lab.login_posts().await, 2);
}

#[tokio::test]
async fn login_skipped_when_another_thread_logged_in_since() {
    let lab = Lab::new(vec![cp(LOGGED_IN)]).await;
    let seen = lab.t.logins();
    lab.t.login(seen).await.unwrap();
    lab.t.login(seen).await.unwrap(); // a waiter that saw the old count: the jar is already fresh
    assert_eq!(lab.calls().await.len(), 1);
    lab.t.login(lab.t.logins()).await.unwrap(); // one that saw the new count still logs in
    assert_eq!(lab.calls().await.len(), 2);
}

#[tokio::test]
async fn still_logged_out_after_login_raises() {
    let lab = Lab::new(vec![cp(LOGGED_OUT), cp(LOGGED_IN), cp(LOGGED_OUT)]).await;
    assert_eq!(
        login_err(lab.t.page("tracker.php").await),
        "still logged out after login: tracker.php"
    );
}

#[tokio::test]
async fn top_query_and_second_page() {
    let lab = Lab::new(vec![fixture("tracker.html"), fixture("tracker.html")]).await;
    let rows = lab.t.top(&[1875, 1818], 7, 3, &[]).await.unwrap();
    assert_eq!(
        rows.iter().map(|r| r.id).collect::<Vec<_>>(),
        vec![3313754, 3314001, 3313754]
    );
    let urls = lab.urls().await;
    for part in ["f%5B%5D=1875", "f%5B%5D=1818", "o=10", "s=2", "tm=7"] {
        assert!(urls[0].contains(part), "{} lacks {part}", urls[0]);
    }
    assert_eq!(urls[1], "/forum/tracker.php?search_id=AbCdEf123&start=50");
}

#[tokio::test]
async fn top_stops_at_limit_without_second_page() {
    let lab = Lab::new(vec![fixture("tracker.html")]).await;
    assert_eq!(lab.t.top(&[1875], 7, 2, &[]).await.unwrap().len(), 2);
    assert_eq!(lab.calls().await.len(), 1);
}

#[tokio::test]
async fn top_with_predicate_filters_and_pages_for_limit() {
    let lab = Lab::new(vec![fixture("tracker.html"), fixture("tracker.html")]).await;
    // The excludes skip id 3313754, so each page yields 1 row (3314001)
    let rows = lab.t.top(&[1875], 7, 2, &not_3313754()).await.unwrap();
    assert_eq!(
        rows.iter().map(|r| r.id).collect::<Vec<_>>(),
        vec![3314001, 3314001]
    );
    assert_eq!(lab.calls().await.len(), 2);
}

#[tokio::test]
async fn search_encodes_params_and_filters() {
    let lab = Lab::new(vec![fixture("tracker.html")]).await;
    let rows = lab
        .t
        .search("Alpha", &[1875, 1818], Some(32), 10, &not_3314001(), None)
        .await
        .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, 3313754);
    let url = &lab.urls().await[0];
    for part in [
        "f%5B%5D=1875",
        "f%5B%5D=1818",
        "nm=Alpha",
        "tm=32",
        "o=10",
        "s=2",
    ] {
        assert!(url.contains(part), "{url} lacks {part}");
    }
}

#[tokio::test]
async fn search_all_time_sends_no_window() {
    let lab = Lab::new(vec![fixture("tracker.html")]).await;
    lab.t
        .search("Alpha", &[1875], None, 1, &[], None)
        .await
        .unwrap();
    let url = &lab.urls().await[0];
    assert!(url.contains("nm=Alpha"));
    assert!(!url.contains("tm="));
}

#[tokio::test]
async fn search_pagination() {
    let lab = Lab::new(vec![fixture("tracker.html"), fixture("tracker.html")]).await;
    let rows = lab
        .t
        .search("Alpha", &[1875], Some(32), 3, &[], None)
        .await
        .unwrap();
    assert_eq!(rows.len(), 3);
    let urls = lab.urls().await;
    assert_eq!(urls.len(), 2);
    assert_eq!(urls[1], "/forum/tracker.php?search_id=AbCdEf123&start=50");
}

#[tokio::test]
async fn search_pages_caps_requests() {
    let lab = Lab::new(vec![fixture("tracker.html"), fixture("tracker.html")]).await;
    let rows = lab
        .t
        .search("Alpha", &[1875], None, 5, &not_3314001(), Some(1))
        .await
        .unwrap();
    assert_eq!(rows.iter().map(|r| r.id).collect::<Vec<_>>(), vec![3313754]);
    let urls = lab.urls().await;
    assert_eq!(urls.len(), 1);
    assert!(!urls.iter().any(|u| u.contains("tm=")));
}

#[tokio::test]
async fn torrent_logs_in_once() {
    let lab = Lab::new(vec![
        cp(LOGGED_OUT),
        cp(LOGGED_IN),
        b"d8:announce1:xe".to_vec(),
    ])
    .await;
    assert_eq!(lab.t.torrent(3313754).await.unwrap(), b"d8:announce1:xe");
    assert_eq!(lab.urls().await[0], "/forum/dl.php?t=3313754");
}

#[tokio::test]
async fn torrent_logged_in_non_torrent_raises_without_login() {
    let lab = Lab::new(vec![cp(LOGGED_IN)]).await;
    match lab.t.torrent(3313754).await {
        Err(TrackerError::Tracker(m)) => assert_eq!(m, "no torrent for topic 3313754"),
        other => panic!("{other:?}"),
    }
    assert_eq!(lab.calls().await.len(), 1);
}

#[tokio::test]
async fn torrent_daily_limit_raises_without_login() {
    let lab = Lab::new(vec![fixture("limit.html")]).await;
    let err = lab.t.torrent(1).await.unwrap_err();
    assert!(matches!(err, TrackerError::Limit(10)), "{err:?}");
    assert_eq!(err.to_string(), "daily download limit reached (10/day)");
    assert_eq!(lab.calls().await.len(), 1);
}

#[tokio::test]
async fn torrent_other_info_page_carries_tracker_message() {
    let page = cp(r#"<html>{logout: 1}<div class="mrg_16">Тема удалена</div></html>"#);
    let lab = Lab::new(vec![page]).await;
    match lab.t.torrent(1).await {
        Err(TrackerError::Tracker(m)) => assert!(m.contains("Тема удалена"), "{m}"),
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn torrent_still_logged_out_after_login_raises() {
    let lab = Lab::new(vec![cp(LOGGED_OUT), cp(LOGGED_IN), cp(LOGGED_OUT)]).await;
    assert_eq!(
        login_err(lab.t.torrent(3313754).await),
        "still logged out after login: topic 3313754"
    );
    assert_eq!(lab.calls().await.len(), 3);
}

#[tokio::test]
async fn fetch_returns_bytes_for_any_url() {
    let lab = Lab::new(vec![]).await;
    Tracker::set_cookie(&lab.db, "secret").unwrap();
    let images = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/a.png"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"\x89PNG-bytes".to_vec()))
        .mount(&images)
        .await;
    let url = format!("{}/a.png", images.uri());
    assert_eq!(lab.t.fetch(&url).await.unwrap(), b"\x89PNG-bytes");
    let reqs = images.received_requests().await.unwrap();
    assert_eq!(reqs[0].url.path(), "/a.png");
    // The tracker's session cookies stay with the tracker.
    assert!(!reqs[0].headers.contains_key("cookie"));
    assert!(lab.calls().await.is_empty());
}

#[tokio::test]
async fn set_cookie_survives_a_new_lab() {
    let lab = Lab::new(vec![]).await;
    Tracker::set_cookie(&lab.db, "abc123").unwrap();
    let new_lab = Lab::with_db(lab.db.clone(), vec![]).await;
    assert_eq!(
        new_lab.jar().0.get("bb_data").map(String::as_str),
        Some("abc123")
    );
}

#[tokio::test]
async fn new_cookie_file_is_reloaded_without_login() {
    let lab = Lab::new(vec![cp(LOGGED_OUT), fixture("tracker.html")]).await;
    Tracker::set_cookie(&lab.db, "fresh").unwrap();
    assert!(lab.t.page("tracker.php").await.unwrap().contains("tor-tbl"));
    assert_eq!(lab.urls().await, vec!["/forum/tracker.php".to_string(); 2]);
    assert_eq!(
        lab.jar().0.get("bb_data").map(String::as_str),
        Some("fresh")
    );
    // ... and it went out with the retry.
    let reqs = lab.server.received_requests().await.unwrap();
    assert_eq!(reqs[1].headers.get("cookie").unwrap(), "bb_data=fresh");
}

#[tokio::test]
async fn new_cookie_file_still_logged_out_logs_in_once() {
    let lab = Lab::new(vec![
        cp(LOGGED_OUT),
        cp(LOGGED_OUT),
        cp(LOGGED_IN),
        fixture("tracker.html"),
    ])
    .await;
    Tracker::set_cookie(&lab.db, "dead").unwrap();
    lab.t.page("tracker.php").await.unwrap();
    assert_eq!(lab.login_posts().await, 1);
}

#[tokio::test]
async fn torrent_reloads_new_cookie_file_without_login() {
    let lab = Lab::new(vec![cp(LOGGED_OUT), b"d8:announce1:xe".to_vec()]).await;
    Tracker::set_cookie(&lab.db, "fresh").unwrap();
    assert_eq!(lab.t.torrent(1).await.unwrap(), b"d8:announce1:xe");
    assert_eq!(lab.calls().await.len(), 2);
    assert_eq!(lab.login_posts().await, 0);
}

#[tokio::test]
async fn own_save_is_not_reloaded() {
    let lab = Lab::new(vec![
        cp(LOGGED_OUT),
        cp(LOGGED_IN),
        fixture("tracker.html"),
        cp(LOGGED_OUT),
        cp(LOGGED_IN),
        fixture("tracker.html"),
    ])
    .await;
    lab.t.page("tracker.php").await.unwrap(); // logs in and saves
    lab.t.page("tracker.php").await.unwrap();
    // our own save is not "newer": a logged-out reply goes straight to login, no reload retry
    assert_eq!(lab.calls().await.len(), 6);
}

#[tokio::test]
async fn successful_page_saves_the_jar() {
    let lab = Lab::new(vec![fixture("tracker.html")]).await;
    lab.t.page("tracker.php").await.unwrap();
    assert!(lab.db.kv_get(COOKIES_KEY).unwrap().is_some());
}

#[tokio::test]
async fn corrupt_jar_is_an_empty_jar() {
    let db = Db::open_in_memory().unwrap();
    db.kv_set(COOKIES_KEY, "garbage\nnot a cookie jar").unwrap();
    let lab = Lab::with_db(db, vec![]).await;
    assert_eq!(lab.jar(), CookieJar::default());
}

#[tokio::test]
async fn set_cookie() {
    // lab.py also stored the domain (.tracker.example); here the jar holds only the tracker's
    // cookies, so the name and value are what persist.
    let lab = Lab::new(vec![]).await;
    Tracker::set_cookie(&lab.db, "abc123").unwrap();
    let saved = lab.db.kv_get(COOKIES_KEY).unwrap().unwrap().0;
    assert_eq!(saved, r#"{"bb_data":"abc123"}"#);
}

// Beyond test_lab.py: the cookie handling urllib's HTTPCookieProcessor did for lab.py.

#[tokio::test]
async fn page_logs_in_once_when_logged_out() {
    let server = MockServer::start().await;
    let db = Db::open_in_memory().unwrap();
    let logged_out = "<html>login</html>";
    let logged_in = "<html>{logout: 1}</html>";
    Mock::given(method("GET"))
        .and(path("/forum/x.php"))
        .respond_with(ResponseTemplate::new(200).set_body_string(logged_out))
        .up_to_n_times(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/forum/login.php"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string(logged_in)
                .insert_header("Set-Cookie", "bb_data=abc; path=/forum/"),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/forum/x.php"))
        .and(header("Cookie", "bb_data=abc"))
        .respond_with(ResponseTemplate::new(200).set_body_string(logged_in))
        .mount(&server)
        .await;
    let t = Tracker::new(
        &format!("{}/forum/", server.uri()),
        "u".into(),
        "p".into(),
        db.clone(),
    );
    assert!(t.page("x.php").await.unwrap().contains("{logout: 1}"));
    assert!(db.kv_get(COOKIES_KEY).unwrap().unwrap().0.contains("abc"));
}

#[tokio::test]
async fn rotated_session_cookie_is_saved() {
    let server = MockServer::start().await;
    Mock::given(any())
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_bytes(cp(LOGGED_IN))
                .append_header("Set-Cookie", "bb_data=rotated; path=/forum/")
                .append_header("Set-Cookie", "bb_t=gone; Max-Age=0"),
        )
        .mount(&server)
        .await;
    let db = Db::open_in_memory().unwrap();
    db.kv_set(COOKIES_KEY, r#"{"bb_data":"old","bb_t":"x"}"#)
        .unwrap();
    let t = Tracker::new(
        &format!("{}/forum/", server.uri()),
        "u".into(),
        "p".into(),
        db.clone(),
    );
    t.page("index.php").await.unwrap();
    assert_eq!(
        db.kv_get(COOKIES_KEY).unwrap().unwrap().0,
        r#"{"bb_data":"rotated"}"#
    );
}

#[tokio::test]
async fn session_not_saved_over_a_newer_jar() {
    // _save_session: a jar written elsewhere since we loaded wins over our rotated cookies.
    let lab = Lab::new(vec![]).await;
    Tracker::set_cookie(&lab.db, "theirs").unwrap();
    lab.t.page("index.php").await.unwrap(); // LOGGED_IN by default
    assert_eq!(
        lab.db.kv_get(COOKIES_KEY).unwrap().unwrap().0,
        r#"{"bb_data":"theirs"}"#
    );
}

#[tokio::test]
async fn redirect_is_followed_with_cookies_and_post_becomes_get() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/forum/login.php"))
        .respond_with(
            ResponseTemplate::new(302)
                .insert_header("Location", "index.php?ok=1")
                .insert_header("Set-Cookie", "bb_data=new; path=/forum/"),
        )
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/forum/index.php"))
        .and(header("Cookie", "bb_data=new"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(cp(LOGGED_IN)))
        .expect(1)
        .mount(&server)
        .await;
    let db = Db::open_in_memory().unwrap();
    let t = Tracker::new(
        &format!("{}/forum/", server.uri()),
        "u".into(),
        "p".into(),
        db.clone(),
    );
    t.login(t.logins()).await.unwrap();
    assert_eq!(t.logins(), 1);
    assert_eq!(
        db.kv_get(COOKIES_KEY).unwrap().unwrap().0,
        r#"{"bb_data":"new"}"#
    );
}

#[tokio::test]
async fn redirect_loop_is_an_error() {
    let server = MockServer::start().await;
    Mock::given(any())
        .respond_with(ResponseTemplate::new(301).insert_header("Location", "/forum/loop.php"))
        .mount(&server)
        .await;
    let t = Tracker::new(
        &format!("{}/forum/", server.uri()),
        "u".into(),
        "p".into(),
        Db::open_in_memory().unwrap(),
    );
    assert!(matches!(
        t.page("loop.php").await,
        Err(TrackerError::Tracker(_))
    ));
    assert_eq!(server.received_requests().await.unwrap().len(), 6);
}

#[tokio::test]
async fn http_error_status_is_an_error() {
    let server = MockServer::start().await;
    Mock::given(any())
        .respond_with(ResponseTemplate::new(503))
        .mount(&server)
        .await;
    let t = Tracker::new(
        &format!("{}/forum/", server.uri()),
        "u".into(),
        "p".into(),
        Db::open_in_memory().unwrap(),
    );
    assert!(matches!(t.page("x.php").await, Err(TrackerError::Http(_))));
}

#[tokio::test]
async fn netscape_jar_is_converted_on_first_load() {
    let db = Db::open_in_memory().unwrap();
    db.kv_set(
        NETSCAPE_KEY,
        "# Netscape HTTP Cookie File\n#HttpOnly_.tracker.example\tTRUE\t/forum/\tTRUE\t\tbb_data\tlegacy\n",
    )
    .unwrap();
    let lab = Lab::with_db(db, vec![]).await;
    assert_eq!(
        lab.jar().0.get("bb_data").map(String::as_str),
        Some("legacy")
    );
    assert_eq!(
        lab.db.kv_get(COOKIES_KEY).unwrap().unwrap().0,
        r#"{"bb_data":"legacy"}"#
    );
    assert_eq!(lab.db.kv_get(NETSCAPE_KEY).unwrap(), None);
    // ... and it is sent.
    lab.t.page("index.php").await.unwrap();
    let reqs = lab.server.received_requests().await.unwrap();
    assert_eq!(reqs[0].headers.get("cookie").unwrap(), "bb_data=legacy");
}

#[tokio::test]
async fn empty_netscape_jar_converts_to_an_empty_jar() {
    let db = Db::open_in_memory().unwrap();
    db.kv_set(NETSCAPE_KEY, "").unwrap();
    let lab = Lab::with_db(db, vec![]).await;
    assert_eq!(lab.jar(), CookieJar::default());
    assert_eq!(lab.db.kv_get(COOKIES_KEY).unwrap().unwrap().0, "{}");
    assert_eq!(lab.db.kv_get(NETSCAPE_KEY).unwrap(), None);
    // No Cookie header at all for an empty jar.
    lab.t.page("index.php").await.unwrap();
    let reqs = lab.server.received_requests().await.unwrap();
    assert!(!reqs[0].headers.contains_key("cookie"));
}

#[tokio::test]
async fn set_cookie_keeps_the_other_cookies() {
    let db = Db::open_in_memory().unwrap();
    db.kv_set(COOKIES_KEY, r#"{"bb_data":"old","bb_t":"x"}"#)
        .unwrap();
    Tracker::set_cookie(&db, "new").unwrap();
    assert_eq!(
        db.kv_get(COOKIES_KEY).unwrap().unwrap().0,
        r#"{"bb_data":"new","bb_t":"x"}"#
    );
}

#[tokio::test]
async fn sends_the_user_agent() {
    let lab = Lab::new(vec![]).await;
    lab.t.page("index.php").await.unwrap();
    let reqs = lab.server.received_requests().await.unwrap();
    assert_eq!(reqs[0].headers.get("user-agent").unwrap(), UA);
}

#[test]
fn futures_are_send() {
    fn send<T: Send>(_: T) {}
    let t = Tracker::new(
        &crate::site::get().tracker_url,
        "u".into(),
        "p".into(),
        Db::open_in_memory().unwrap(),
    );
    send(t.page("x"));
    send(t.login(0));
    send(t.top(&[1], 7, 1, &[]));
    send(t.search("q", &[1], None, 1, &[], None));
    send(t.topic(1));
    send(t.torrent(1));
    send(t.fetch(&crate::site::get().tracker_url));
}
