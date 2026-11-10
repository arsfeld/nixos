//! Turns bridge messages and touches into model changes and screen properties.
//!
//! One `Controller` per window. The app feeds it messages with [`Controller::on_message`] and calls
//! [`Controller::tick`] a few times a second; everything the user does arrives through the window's
//! callbacks, which this wires up. Answers leave through the [`Outbox`].

use std::cell::RefCell;
use std::rc::Rc;

use claude_board_proto::{join_labels, AnswerOutcome, Applied, AskId, ClientMsg, Model, Session, State};
use slint::{ComponentHandle, Model as _, ModelRc, SharedString, VecModel, Weak};

use crate::view::{arc_index_at, fmt_ago, presence_for, rim_models, session_rows, shorten, PresenceKind, MAX_RIM_SEGMENTS};
use crate::{AppWindow, OptionRow, Page, PresenceState, RimSegment, SessionRow};

/// Taps this soon after an answer are ignored (a double tap is two taps well under this apart).
const ANSWER_GUARD_MS: u64 = 400;

/// Where answers go: the websocket to the bridge.
pub trait Outbox {
    /// Send one text frame. False when not connected.
    fn send(&self, json: String) -> bool;
}

/// Where the user has navigated; a waiting question overrides it until it is answered.
enum Nav {
    Home,
    List,
    Detail { host: String, session: String },
}

/// Multi-select state for the question on screen, keyed so it can never outlive that question.
#[derive(Default)]
struct Selection {
    key: Option<(AskId, usize)>,
    picked: Vec<bool>,
}

/// The list models the window shows. Each is created once and updated in place: handing the window a new model
/// makes Slint destroy and rebuild every row, so a touch area that has seen the press would be gone before the
/// release and the tap lost (a refresh lands four times a second, and on every bridge message).
struct Models {
    rim: Rc<VecModel<RimSegment>>,
    rim_pulsing: Rc<VecModel<RimSegment>>,
    rows: Rc<VecModel<SessionRow>>,
    options: Rc<VecModel<OptionRow>>,
    recent: Rc<VecModel<SharedString>>,
}

/// Make `model` hold exactly `new`, touching only what differs.
fn sync<T: Clone + PartialEq + 'static>(model: &VecModel<T>, new: Vec<T>) {
    for (i, item) in new.iter().enumerate() {
        if i < model.row_count() {
            if model.row_data(i).as_ref() != Some(item) {
                model.set_row_data(i, item.clone());
            }
        } else {
            model.push(item.clone());
        }
    }
    while model.row_count() > new.len() {
        model.remove(model.row_count() - 1);
    }
}

struct Inner<O: Outbox> {
    models: Models,
    model: Model,
    outbox: O,
    window: Weak<AppWindow>,
    nav: Nav,
    link: bool,
    now: Option<i64>,
    sel: Selection,
    /// The app's monotonic clock in milliseconds (see `set_time_ms`), and when the last answer was given: taps
    /// within `ANSWER_GUARD_MS` of it are ignored, so a double tap cannot answer the next question of the ask.
    time_ms: u64,
    answered_at_ms: Option<u64>,
    prev_waiting: usize,
    chimed_ask: Option<AskId>,
    chime: bool,
}

pub struct Controller<O: Outbox> {
    inner: Rc<RefCell<Inner<O>>>,
}

impl<O: Outbox + 'static> Controller<O> {
    pub fn new(window: &AppWindow, outbox: O) -> Self {
        let models = Models {
            rim: Rc::new(VecModel::default()),
            rim_pulsing: Rc::new(VecModel::default()),
            rows: Rc::new(VecModel::default()),
            options: Rc::new(VecModel::default()),
            recent: Rc::new(VecModel::default()),
        };
        window.set_rim(ModelRc::from(models.rim.clone()));
        window.set_rim_pulsing(ModelRc::from(models.rim_pulsing.clone()));
        window.set_rows(ModelRc::from(models.rows.clone()));
        window.set_options(ModelRc::from(models.options.clone()));
        window.set_detail_recent(ModelRc::from(models.recent.clone()));
        let inner = Rc::new(RefCell::new(Inner {
            models,
            model: Model::new(),
            outbox,
            window: window.as_weak(),
            nav: Nav::Home,
            // Offline until the bridge connection comes up: the home screen says so.
            link: false,
            now: None,
            sel: Selection::default(),
            time_ms: 0,
            answered_at_ms: None,
            prev_waiting: 0,
            chimed_ask: None,
            chime: false,
        }));
        macro_rules! wire {
            ($on:ident, |$s:ident $(, $a:ident : $t:ty)*| $body:expr) => {{
                let i = inner.clone();
                window.$on(move |$($a: $t),*| {
                    let mut $s = i.borrow_mut();
                    $body
                });
            }};
        }
        wire!(on_option_tapped, |s, i: i32| s.option_tapped(i as usize));
        wire!(on_done_tapped, |s| s.done_tapped());
        wire!(on_decline_tapped, |s| s.decline_tapped());
        wire!(on_row_tapped, |s, i: i32| s.open_detail_at(i as usize));
        wire!(on_rim_tapped, |s, deg: f32| s.rim_tapped(deg));
        wire!(on_back_tapped, |s| s.back_tapped());
        wire!(on_avatar_tapped, |s| s.avatar_tapped());
        inner.borrow_mut().refresh();
        Controller { inner }
    }

    /// One text frame from the bridge.
    pub fn on_message(&self, json: &str) {
        let mut s = self.inner.borrow_mut();
        if s.model.apply(json) != Applied::Changed {
            return;
        }
        let waiting = s.model.waiting_count();
        let ask = s.model.current_ask().map(|a| a.ask.id.clone());
        if waiting > s.prev_waiting || (ask.is_some() && ask != s.chimed_ask) {
            s.chime = true;
        }
        s.prev_waiting = waiting;
        s.chimed_ask = ask;
        s.refresh();
    }

    /// The bridge connection came up or went down.
    pub fn set_link(&self, up: bool) {
        let mut s = self.inner.borrow_mut();
        s.link = up;
        s.refresh();
    }

    /// Tell the controller the time (a monotonic clock in milliseconds); the app calls this every pass of its loop
    /// so an answer is timestamped to the millisecond.
    pub fn set_time_ms(&self, ms: u64) {
        self.inner.borrow_mut().time_ms = ms;
    }

    /// The wall clock moved on (`None` while it is not set) at monotonic time `ms`; refreshes "time in state".
    pub fn tick_at(&self, now: Option<i64>, ms: u64) {
        let mut s = self.inner.borrow_mut();
        s.time_ms = ms;
        s.now = now;
        s.refresh();
    }

    /// `tick_at` for callers with no clock of their own (the tests): half a second passes.
    pub fn tick(&self, now: Option<i64>) {
        let ms = self.inner.borrow().time_ms + 500;
        self.tick_at(now, ms);
    }

    /// True once after something started needing the user.
    pub fn wants_chime(&self) -> bool {
        std::mem::take(&mut self.inner.borrow_mut().chime)
    }
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

fn state_name(s: State) -> &'static str {
    match s {
        State::Working => "working",
        State::Waiting => "waiting",
        State::Done => "done",
        State::Error => "error",
        State::Idle => "idle",
    }
}

impl<O: Outbox> Inner<O> {
    fn send(&self, msg: &ClientMsg) {
        let json = serde_json::to_string(msg).expect("a ClientMsg serialises");
        // Offline: the question is still consumed (as in the C firmware); the bridge times it out and
        // Claude falls back to the terminal prompt.
        let _ = self.outbox.send(json);
    }

    fn cooling_down(&self) -> bool {
        self.answered_at_ms.is_some_and(|at| self.time_ms < at + ANSWER_GUARD_MS)
    }

    fn submit(&mut self, label: &str) {
        match self.model.answer(label) {
            AnswerOutcome::Complete(msg) => {
                self.send(&msg);
                self.answered_at_ms = Some(self.time_ms);
            }
            AnswerOutcome::NextQuestion => self.answered_at_ms = Some(self.time_ms),
            AnswerOutcome::NoQuestion => {}
        }
        self.refresh();
    }

    fn option_tapped(&mut self, i: usize) {
        if self.cooling_down() {
            return;
        }
        let Some(ask) = self.model.current_ask() else { return };
        let q = ask.current();
        let Some(opt) = q.options.get(i) else { return };
        if q.multi_select {
            if let Some(p) = self.sel.picked.get_mut(i) {
                *p = !*p;
            }
            self.refresh();
        } else {
            let label = opt.label.clone();
            self.submit(&label);
        }
    }

    fn done_tapped(&mut self) {
        if self.cooling_down() {
            return;
        }
        let Some(ask) = self.model.current_ask() else { return };
        let q = ask.current();
        let picked: Vec<&str> =
            q.options.iter().zip(&self.sel.picked).filter(|(_, on)| **on).map(|(o, _)| o.label.as_str()).collect();
        if picked.is_empty() {
            return;
        }
        let joined = join_labels(&picked);
        self.submit(&joined);
    }

    fn decline_tapped(&mut self) {
        if self.cooling_down() {
            return;
        }
        let Some(msg) = self.model.decline_msg() else { return };
        self.send(&msg);
        if let ClientMsg::Decline { id } = &msg {
            self.model.dismiss(id);
        }
        self.answered_at_ms = Some(self.time_ms);
        self.refresh();
    }

    fn open_detail_at(&mut self, i: usize) {
        if let Some(s) = self.model.sessions().get(i) {
            self.nav = Nav::Detail { host: s.host.clone(), session: s.session.clone() };
            self.refresh();
        }
    }

    /// Show the list from its first row.
    fn open_list(&mut self) {
        if let Some(win) = self.window.upgrade() {
            win.set_list_scroll(0.0);
        }
        self.nav = Nav::List;
        self.refresh();
    }

    fn rim_tapped(&mut self, deg: f32) {
        let n = self.model.sessions().len();
        match arc_index_at(deg, n) {
            // With more than 12 sessions the last arc stands for the rest: show the list.
            Some(i) if n > MAX_RIM_SEGMENTS && i == MAX_RIM_SEGMENTS - 1 => self.open_list(),
            Some(i) => self.open_detail_at(i),
            None => {}
        }
    }

    fn back_tapped(&mut self) {
        self.nav = match self.nav {
            Nav::Detail { .. } => Nav::List,
            _ => Nav::Home,
        };
        self.refresh();
    }

    fn avatar_tapped(&mut self) {
        self.open_list();
    }

    fn detail_session(&self) -> Option<&Session> {
        let Nav::Detail { host, session } = &self.nav else { return None };
        self.model.sessions().iter().find(|s| &s.host == host && &s.session == session)
    }

    /// Push everything the screen shows from the model, the navigation and the clock.
    fn refresh(&mut self) {
        if matches!(self.nav, Nav::Detail { .. }) && self.detail_session().is_none() {
            self.nav = Nav::List; // the session went away
        }
        let Some(win) = self.window.upgrade() else { return };

        let sessions = self.model.sessions();
        let waiting = self.model.waiting_count();
        let (still, pulsing) = rim_models(sessions);
        sync(&self.models.rim, still);
        sync(&self.models.rim_pulsing, pulsing);
        win.set_link(self.link);

        win.set_presence_state(match presence_for(&self.model) {
            PresenceKind::Idle => PresenceState::Idle,
            PresenceKind::Thinking => PresenceState::Thinking,
            PresenceKind::Alert => PresenceState::Alert,
        });
        win.set_presence_level(0.0);
        let working = sessions.iter().filter(|s| s.state == State::Working).count();
        win.set_summary(
            if waiting > 0 {
                plural(waiting, "needs you", "need you")
            } else if working > 0 {
                format!("{working} working")
            } else if sessions.is_empty() {
                "No sessions".into()
            } else {
                "All quiet".into()
            }
            .into(),
        );

        sync(&self.models.rows, session_rows(sessions, self.now));
        if let Some(s) = self.detail_session() {
            win.set_detail_host(shorten(&s.host, 24).into());
            win.set_detail_project(shorten(&s.project, 40).into());
            win.set_detail_state(crate::view::session_state(s.state));
            win.set_detail_state_text(state_name(s.state).into());
            win.set_detail_since(fmt_ago(self.now, s.since).into());
        }
        win.set_detail_summary("".into());
        sync(&self.models.recent, Vec::new());

        match self.model.current_ask() {
            Some(ask) => {
                let q = ask.current();
                let key = (ask.ask.id.clone(), ask.next_question());
                if self.sel.key.as_ref() != Some(&key) {
                    self.sel = Selection { key: Some(key), picked: vec![false; q.options.len()] };
                }
                win.set_question_source(
                    format!("{} - {}", shorten(&ask.ask.host, 24), shorten(&ask.ask.project, 40)).to_uppercase().into(),
                );
                win.set_question_text(shorten(&q.question, 160).into());
                win.set_multi(q.multi_select);
                win.set_can_done(self.sel.picked.iter().any(|p| *p));
                let rows: Vec<OptionRow> = q
                    .options
                    .iter()
                    .zip(&self.sel.picked)
                    .map(|(o, on)| OptionRow { label: shorten(&o.label, 60).into(), selected: *on })
                    .collect();
                sync(&self.models.options, rows);
                win.set_page(Page::Question);
            }
            None => {
                self.sel = Selection::default(); // no question: nothing selected can outlive it
                win.set_page(match self.nav {
                    Nav::Home => Page::Home,
                    Nav::List => Page::List,
                    Nav::Detail { .. } => Page::Detail,
                });
            }
        }
    }
}
