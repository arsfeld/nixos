//! The tracker client: one logged-in session, persisted as a cookie jar in `kv`.
//!
//! Logging in is the risky part: repeated logins make the form demand a captcha, which
//! plab cannot solve. So the jar is reused across runs and a login happens only when a
//! page comes back logged out, at most once per request. On a captcha it gives up and says
//! so; `plab set-cookie` is the way back in. Logins are serialized across tasks: one that
//! waited for another's login reuses it, and after a failure no task posts the form again
//! for LOGIN_BACKOFF seconds (or until a newer jar lands in `kv`).

pub mod cookies;
pub mod forums;
pub mod parse;

use std::future::Future;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::db::Db;
use cookies::CookieJar;
use parse::Row;

#[derive(Debug, thiserror::Error)]
pub enum TrackerError {
    #[error("{0}")]
    Login(String),
    #[error("daily download limit reached ({0}/day)")]
    Limit(u32),
    #[error("{0}")]
    Tracker(String),
    #[error(transparent)]
    Http(#[from] reqwest::Error),
}

pub const UA: &str = "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0";
/// Seconds a failed login blocks further ones.
pub const LOGIN_BACKOFF: u64 = 300;
const TIMEOUT: u64 = 60;
const MAX_REDIRECTS: usize = 5;
/// The jar, as JSON.
const COOKIES_KEY: &str = "tracker_cookies";
/// The legacy cookies.txt the one-time import stored; converted on first load.
const NETSCAPE_KEY: &str = "tracker_cookies_netscape";

pub trait TrackerApi: Send + Sync {
    fn top(
        &self,
        forums: &[u32],
        days: u32,
        limit: usize,
        excludes: &crate::filters::Excludes,
    ) -> impl Future<Output = Result<Vec<Row>, TrackerError>> + Send;
    fn search(
        &self,
        query: &str,
        forums: &[u32],
        days: Option<u32>,
        limit: usize,
        excludes: &crate::filters::Excludes,
        pages: Option<usize>,
    ) -> impl Future<Output = Result<Vec<Row>, TrackerError>> + Send;
    fn topic(&self, topic_id: u64) -> impl Future<Output = Result<String, TrackerError>> + Send;
    fn torrent(&self, topic_id: u64) -> impl Future<Output = Result<Vec<u8>, TrackerError>> + Send;
    fn fetch(&self, url: &str) -> impl Future<Output = Result<Vec<u8>, TrackerError>> + Send;
}

/// The jar and the `kv` rev it was loaded from (or last saved as).
#[derive(Debug, Default)]
struct Session {
    jar: CookieJar,
    rev: i64,
}

#[derive(Debug, Default)]
struct LoginState {
    /// The message and time of the last failed login.
    failure: Option<(String, Instant)>,
}

pub struct Tracker {
    http: reqwest::Client,
    base: String,
    username: String,
    password: String,
    db: Db,
    session: Mutex<Session>,
    login: tokio::sync::Mutex<LoginState>,
    /// Successful logins so far.
    logins: AtomicU64,
    backoff: Duration,
}

impl Tracker {
    pub fn new(base: &str, username: String, password: String, db: Db) -> Tracker {
        let session = load_session(&db);
        Tracker {
            http: crate::http::client(TIMEOUT),
            base: base.to_string(),
            username,
            password,
            db,
            session: Mutex::new(session),
            login: tokio::sync::Mutex::new(LoginState::default()),
            logins: AtomicU64::new(0),
            backoff: Duration::from_secs(LOGIN_BACKOFF),
        }
    }

    /// Successful logins so far; pass it to `login` as `seen`.
    pub fn logins(&self) -> u64 {
        self.logins.load(Ordering::SeqCst)
    }

    pub async fn page(&self, path: &str) -> Result<String, TrackerError> {
        let (mut reloaded, mut logged_in) = (false, false);
        loop {
            let seen = self.logins();
            let page = decode(&self.open(&format!("{}{path}", self.base), None).await?);
            if parse::logged_in(&page) {
                self.save_session();
                return Ok(page);
            }
            // A newer jar is tried before any login; then at most one login.
            if !reloaded && self.reload_if_newer().await {
                reloaded = true;
            } else if !logged_in {
                self.login(seen).await?;
                logged_in = true;
            } else {
                return Err(TrackerError::Login(format!(
                    "still logged out after login: {path}"
                )));
            }
        }
    }

    /// Log in; `seen` is the login count from before the request that came back logged out.
    pub async fn login(&self, seen: u64) -> Result<(), TrackerError> {
        let mut state = self.login.lock().await;
        if self.logins() != seen {
            return Ok(()); // another task logged in while this one waited; retry with its jar
        }
        if let Some((msg, at)) = &state.failure
            && at.elapsed() < self.backoff
        {
            return Err(TrackerError::Login(msg.clone()));
        }
        match self.post_login().await {
            Err(TrackerError::Login(msg)) => {
                state.failure = Some((msg.clone(), Instant::now()));
                Err(TrackerError::Login(msg))
            }
            Err(e) => Err(e),
            Ok(()) => {
                state.failure = None;
                self.logins.fetch_add(1, Ordering::SeqCst);
                Ok(())
            }
        }
    }

    async fn post_login(&self) -> Result<(), TrackerError> {
        fn cp1251(s: &str) -> std::borrow::Cow<'_, [u8]> {
            std::borrow::Cow::Owned(encoding_rs::WINDOWS_1251.encode(s).0.into_owned())
        }
        let body = form_urlencoded::Serializer::new(String::new())
            .encoding_override(Some(&cp1251))
            .append_pair("login_username", &self.username)
            .append_pair("login_password", &self.password)
            .append_pair("login", "Вход")
            .finish();
        let url = format!("{}login.php", self.base);
        let page = decode(&self.open(&url, Some(body.into_bytes())).await?);
        if parse::needs_captcha(&page) {
            return Err(TrackerError::Login("login needs captcha".into()));
        }
        if !parse::logged_in(&page) {
            return Err(TrackerError::Login("login failed".into()));
        }
        let mut session = self.session.lock().unwrap();
        self.save(&mut session);
        Ok(())
    }

    /// `plab set-cookie`: put `value` in the stored jar as bb_data.
    pub fn set_cookie(db: &Db, value: &str) -> anyhow::Result<()> {
        let mut session = load_session(db);
        session.jar.set("bb_data", value);
        db.kv_set(COOKIES_KEY, &serde_json::to_string(&session.jar)?)?;
        Ok(())
    }

    /// GET (or, with `form`, POST) `url` with the session's cookies, following redirects by
    /// hand as urllib did (a POST becomes a GET); the body of the final reply.
    async fn open(&self, url: &str, form: Option<Vec<u8>>) -> Result<Vec<u8>, TrackerError> {
        let bad = |e: url::ParseError| TrackerError::Tracker(format!("bad url {url}: {e}"));
        let mut url = url::Url::parse(url).map_err(bad)?;
        let mut form = form;
        for _ in 0..=MAX_REDIRECTS {
            let ours = self.is_tracker(&url);
            let mut req = match form.take() {
                Some(body) => self
                    .http
                    .post(url.clone())
                    .header(
                        reqwest::header::CONTENT_TYPE,
                        "application/x-www-form-urlencoded",
                    )
                    .body(body),
                None => self.http.get(url.clone()),
            }
            .header(reqwest::header::USER_AGENT, UA);
            if let Some(cookie) = ours.then(|| self.cookie_header()).flatten() {
                req = req.header(reqwest::header::COOKIE, cookie);
            }
            let resp = req.send().await?;
            if ours {
                self.apply_set_cookies(resp.headers());
            }
            let location = resp
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok());
            if matches!(resp.status().as_u16(), 301 | 302 | 303 | 307 | 308)
                && let Some(location) = location
            {
                url = url
                    .join(location)
                    .map_err(|e| TrackerError::Tracker(format!("bad redirect {location}: {e}")))?;
                continue;
            }
            return Ok(resp.error_for_status()?.bytes().await?.to_vec());
        }
        Err(TrackerError::Tracker(format!("too many redirects: {url}")))
    }

    /// Whether `url` is on the tracker's origin, the only one its cookies go to.
    fn is_tracker(&self, url: &url::Url) -> bool {
        url::Url::parse(&self.base).is_ok_and(|base| base.origin() == url.origin())
    }

    fn cookie_header(&self) -> Option<String> {
        self.session.lock().unwrap().jar.header()
    }

    fn apply_set_cookies(&self, headers: &reqwest::header::HeaderMap) {
        let mut session = self.session.lock().unwrap();
        for value in headers.get_all(reqwest::header::SET_COOKIE) {
            if let Ok(value) = value.to_str() {
                session.jar.apply_set_cookie(value);
            }
        }
    }

    /// The rev of the stored jar, 0 when there is none (lab.py's _file_mtime).
    fn stored_rev(&self) -> i64 {
        match self.db.kv_get(COOKIES_KEY) {
            Ok(found) => found.map_or(0, |(_, rev)| rev),
            Err(e) => {
                tracing::warn!("reading the tracker session: {e:#}");
                0
            }
        }
    }

    fn save(&self, session: &mut Session) {
        let json = serde_json::to_string(&session.jar).expect("a string map serializes");
        match self.db.kv_set(COOKIES_KEY, &json) {
            Ok(rev) => session.rev = rev,
            Err(e) => tracing::warn!("saving the tracker session: {e:#}"),
        }
    }

    /// The tracker rotates session cookies; keep them, unless a newer jar is waiting.
    fn save_session(&self) {
        let mut session = self.session.lock().unwrap();
        if self.stored_rev() <= session.rev {
            self.save(&mut session);
        }
    }

    /// Pick up a jar another process wrote (`plab set-cookie`); true if reloaded.
    async fn reload_if_newer(&self) -> bool {
        let reloaded = {
            let mut session = self.session.lock().unwrap();
            let newer = self.stored_rev() > session.rev;
            if newer {
                *session = load_session(&self.db);
            }
            newer
        };
        if reloaded {
            // set-cookie is the way back in after a failed login
            self.login.lock().await.failure = None;
        }
        reloaded
    }

    async fn rows(
        &self,
        first: String,
        limit: usize,
        excludes: &crate::filters::Excludes,
        pages: Option<usize>,
    ) -> Result<Vec<Row>, TrackerError> {
        let keep = |rows: Vec<Row>| {
            rows.into_iter()
                .filter(|r| !excludes.excluded(&r.title))
                .collect::<Vec<_>>()
        };
        let mut page = self.page(&first).await?;
        let mut rows = keep(parse::rows(&page));
        let mut start = 50;
        let mut fetched = 1;
        while rows.len() < limit && pages.is_none_or(|p| fetched < p) {
            let Some(link) = parse::page_link(&page, start) else {
                break;
            };
            page = self.page(&link).await?;
            fetched += 1;
            rows.extend(keep(parse::rows(&page)));
            start += 50;
        }
        rows.truncate(limit);
        Ok(rows)
    }
}

/// The stored jar and its rev. A missing or corrupt jar is an empty one; the legacy
/// cookies.txt the import left behind is converted the first time.
fn load_session(db: &Db) -> Session {
    let stored = match db.kv_get(COOKIES_KEY) {
        Ok(stored) => stored,
        Err(e) => {
            tracing::warn!("reading the tracker session: {e:#}");
            return Session::default();
        }
    };
    if let Some((json, rev)) = stored {
        let jar = serde_json::from_str(&json).unwrap_or_else(|e| {
            tracing::warn!("ignoring a corrupt tracker session: {e}");
            CookieJar::default()
        });
        return Session { jar, rev };
    }
    let Ok(Some((text, _))) = db.kv_get(NETSCAPE_KEY) else {
        return Session::default();
    };
    let jar = CookieJar::from_netscape(&text);
    let json = serde_json::to_string(&jar).expect("a string map serializes");
    match db.kv_set(COOKIES_KEY, &json) {
        Ok(rev) => {
            if let Err(e) = db.kv_delete(NETSCAPE_KEY) {
                tracing::warn!("removing the converted cookies.txt: {e:#}");
            }
            Session { jar, rev }
        }
        Err(e) => {
            tracing::warn!("saving the converted tracker session: {e:#}");
            Session { jar, rev: 0 }
        }
    }
}

fn decode(bytes: &[u8]) -> String {
    encoding_rs::WINDOWS_1251
        .decode_without_bom_handling(bytes)
        .0
        .into_owned()
}

/// `re.match(rb"d\d+:", data)`: a bencoded dictionary, not a login page.
fn is_torrent(data: &[u8]) -> bool {
    let Some(rest) = data.strip_prefix(b"d") else {
        return false;
    };
    let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
    digits > 0 && rest.get(digits) == Some(&b':')
}

fn query(forums: &[u32], rest: &[(&str, String)]) -> String {
    let mut q = form_urlencoded::Serializer::new(String::new());
    for f in forums {
        q.append_pair("f[]", &f.to_string());
    }
    for (k, v) in rest {
        q.append_pair(k, v);
    }
    q.finish()
}

impl TrackerApi for Tracker {
    /// The most-seeded releases uploaded in the last `days` days, best first.
    fn top(
        &self,
        forums: &[u32],
        days: u32,
        limit: usize,
        excludes: &crate::filters::Excludes,
    ) -> impl Future<Output = Result<Vec<Row>, TrackerError>> + Send {
        let q = query(
            forums,
            &[
                ("o", "10".into()),
                ("s", "2".into()),
                ("tm", days.to_string()),
            ],
        );
        self.rows(format!("tracker.php?{q}"), limit, excludes, None)
    }

    /// Releases matching `query` within `forums` uploaded in the last `days` days (all time
    /// when None), fetching at most `pages` results pages (None: as many as `limit` needs).
    fn search(
        &self,
        query_text: &str,
        forums: &[u32],
        days: Option<u32>,
        limit: usize,
        excludes: &crate::filters::Excludes,
        pages: Option<usize>,
    ) -> impl Future<Output = Result<Vec<Row>, TrackerError>> + Send {
        let mut rest = vec![
            ("nm", query_text.to_string()),
            ("o", "10".into()),
            ("s", "2".into()),
        ];
        if let Some(days) = days {
            rest.push(("tm", days.to_string()));
        }
        let q = query(forums, &rest);
        self.rows(format!("tracker.php?{q}"), limit, excludes, pages)
    }

    async fn topic(&self, topic_id: u64) -> Result<String, TrackerError> {
        self.page(&format!("viewtopic.php?t={topic_id}")).await
    }

    async fn torrent(&self, topic_id: u64) -> Result<Vec<u8>, TrackerError> {
        let (mut reloaded, mut logged_in) = (false, false);
        loop {
            let seen = self.logins();
            let url = format!("{}dl.php?t={topic_id}", self.base);
            let data = self.open(&url, None).await?;
            if is_torrent(&data) {
                self.save_session();
                return Ok(data);
            }
            // Only a missing session earns a login; a logged-in reply that is not a
            // torrent (deleted topic, no access) is the tracker's answer, not a reason to
            // log in again.
            let text = decode(&data);
            if parse::logged_in(&text) {
                if let Some(limit) = parse::daily_limit(&text) {
                    return Err(TrackerError::Limit(limit));
                }
                return Err(TrackerError::Tracker(
                    parse::info_message(&text)
                        .unwrap_or_else(|| format!("no torrent for topic {topic_id}")),
                ));
            }
            if !reloaded && self.reload_if_newer().await {
                reloaded = true;
            } else if !logged_in {
                self.login(seen).await?;
                logged_in = true;
            } else {
                return Err(TrackerError::Login(format!(
                    "still logged out after login: topic {topic_id}"
                )));
            }
        }
    }

    fn fetch(&self, url: &str) -> impl Future<Output = Result<Vec<u8>, TrackerError>> + Send {
        self.open(url, None)
    }
}

#[cfg(test)]
mod tests;
