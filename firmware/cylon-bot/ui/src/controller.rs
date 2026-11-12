//! Turns bridge messages and touches into model changes and screen properties.
//!
//! One `Controller` per window. The app feeds it messages with [`Controller::on_message`] and calls
//! [`Controller::tick`] a few times a second; everything the user does arrives through the window's
//! callbacks, which this wires up. Answers leave through the [`Outbox`].

use std::cell::RefCell;
use std::rc::Rc;

use cylon_bot_proto::{join_labels, AnswerOutcome, Applied, AskId, BoardMsg, ClientMsg, Model, Mood, Session, State, APPROVAL_TEXT_MAX};
use slint::{ComponentHandle, Model as _, ModelRc, VecModel, Weak};

use crate::view::{
    arc_index_at, command_at, command_segments, feed_rows, fmt_ago, presence_for, rim_models, session_rows, shorten, Command,
    PresenceKind, MAX_RIM_SEGMENTS,
};
use crate::rim::ticks;
use crate::{AppWindow, FeedRow, OptionRow, Page, PresenceState, RimSegment, SessionRow};

/// Utterance ids the bridge owns (its spoken reminders) have this bit set; the board's own stay below it. Mirrors
/// `REMINDER_ID_BASE` in `packages/cylon-bot-bridge/src/voice/pipeline.rs`.
pub const REMINDER_ID_BASE: u32 = 0x8000_0000;

/// How long the reply card stays up, in `tick_at` time.
const REPLY_CARD_MS: u64 = 20_000;
/// Thinking with no word from the bridge for this long goes back to idle (the bridge gives up on a reply at 60 s).
const THINKING_WATCHDOG_MS: u64 = 90_000;
/// Where the avatar is and how far a hold on it counts (the circle inscribed in its 280 px box).
const AVATAR_CENTRE: i16 = 233;
const AVATAR_RADIUS: i32 = 140;

/// Taps this soon after an answer are ignored (a double tap is two taps well under this apart).
const ANSWER_GUARD_MS: u64 = 400;
/// Taps this soon after a different question takes over the screen are ignored too: one meant for the list or the
/// feed a moment ago must not answer (or, for a tool approval, allow) what just appeared under the finger.
const NEW_ASK_GUARD_MS: u64 = 500;
/// The command menu closes after this long with no touch.
const MENU_IDLE_MS: u64 = 10_000;
/// How long the purge button must be held.
pub const PURGE_HOLD_MS: u64 = 1_500;
/// A purge with no `session_reset` from the bridge after this long gives up waiting: the creature goes back to idle.
const RESET_WAIT_MS: u64 = 10_000;

/// Where answers go: the websocket to the bridge.
pub trait Outbox {
    /// Send one text frame. False when not connected.
    fn send(&self, json: String) -> bool;
    /// Send one binary frame (microphone audio). False when not connected or not supported.
    fn send_bin(&self, bytes: Vec<u8>) -> bool {
        let _ = bytes;
        false
    }
}

/// Where the user has navigated; a waiting question overrides it until it is answered.
enum Nav {
    Home,
    List,
    Detail { host: String, session: String },
    /// The pages the command menu opens.
    Volume,
    Link,
    Purge,
}

impl Nav {
    fn is_command(&self) -> bool {
        matches!(self, Nav::Volume | Nav::Link | Nav::Purge)
    }
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
    commands: Rc<VecModel<RimSegment>>,
    rows: Rc<VecModel<SessionRow>>,
    options: Rc<VecModel<OptionRow>>,
    feed: Rc<VecModel<FeedRow>>,
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
    /// The command menu is up on home, and when it was last touched (or opened), in `tick_at` time.
    menu_open: bool,
    menu_touched_ms: u64,
    link: bool,
    now: Option<i64>,
    sel: Selection,
    /// The app's monotonic clock in milliseconds (see `set_time_ms`), and the time until which taps on the question
    /// are ignored: `ANSWER_GUARD_MS` after an answer, so a double tap cannot answer the next question of the ask,
    /// and `NEW_ASK_GUARD_MS` after a different ask appears.
    time_ms: u64,
    guard_until_ms: u64,
    prev_waiting: usize,
    chimed_ask: Option<AskId>,
    chime: bool,
    /// Something arrived that should light a dark panel (see `take_wake`).
    wake: bool,
    /// The voice path: the bridge's mood for the creature, the finger holding the avatar, the utterance in
    /// progress (kept after the release so a cancel can name it), the last one numbered, the microphone level.
    mood: Mood,
    holding: bool,
    utterance: Option<u32>,
    last_utterance: u32,
    mic_level: f32,
    /// The app is still playing the reply's audio, and an `idle` mood arrived meanwhile (the bridge sends all of a
    /// reply long before it has been played): the creature keeps speaking until `set_audio_playing(false)`.
    audio_playing: bool,
    idle_deferred: bool,
    /// When the current mood began, in `tick_at` time (the thinking watchdog).
    mood_since_ms: u64,
    /// The words of the last transcript, the reply on the card and the time it goes away.
    transcript: String,
    reply: String,
    reply_until_ms: u64,
    /// The heading of a reminder on the card. A reminder does not expire with `REPLY_CARD_MS`: it stays until it
    /// is tapped or a reply replaces it.
    reminder_heading: Option<String>,
    /// The utterance the bridge is speaking, from its `speak_start` to its `speak_end`: a reminder's speech is not
    /// one of ours, and a tap has to name its id to stop it.
    speaking: Option<u32>,
    /// A - or + tap on the volume page, waiting for the app (`take_volume_step`).
    volume_step: Option<bool>,
    /// A purge sent and not yet answered: its utterance id and when it was sent, in `tick_at` time.
    purge_wait: Option<(u32, u64)>,
}

pub struct Controller<O: Outbox> {
    inner: Rc<RefCell<Inner<O>>>,
}

impl<O: Outbox + 'static> Controller<O> {
    pub fn new(window: &AppWindow, outbox: O) -> Self {
        let models = Models {
            rim: Rc::new(VecModel::default()),
            rim_pulsing: Rc::new(VecModel::default()),
            // The menu's arcs never change: built here once.
            commands: Rc::new(VecModel::from(command_segments())),
            rows: Rc::new(VecModel::default()),
            options: Rc::new(VecModel::default()),
            feed: Rc::new(VecModel::default()),
        };
        window.set_rim(ModelRc::from(models.rim.clone()));
        window.set_rim_pulsing(ModelRc::from(models.rim_pulsing.clone()));
        window.set_commands(ModelRc::from(models.commands.clone()));
        window.set_rows(ModelRc::from(models.rows.clone()));
        window.set_options(ModelRc::from(models.options.clone()));
        window.set_feed(ModelRc::from(models.feed.clone()));
        // Fixed geometry, built once: the volume page's level (a gap at the bottom) and the purge page's full ring.
        window.set_volume_ticks(ModelRc::new(VecModel::from(ticks(-120.0, 120.0, 24, 195.0, 221.0))));
        window.set_ring_ticks(ModelRc::new(VecModel::from(ticks(0.0, 350.0, 36, 200.0, 222.0))));
        window.set_purge_hold(PURGE_HOLD_MS as i64);
        let inner = Rc::new(RefCell::new(Inner {
            models,
            model: Model::new(),
            outbox,
            window: window.as_weak(),
            nav: Nav::Home,
            menu_open: false,
            menu_touched_ms: 0,
            // Offline until the bridge connection comes up: the home screen says so.
            link: false,
            now: None,
            sel: Selection::default(),
            time_ms: 0,
            guard_until_ms: 0,
            prev_waiting: 0,
            chimed_ask: None,
            chime: false,
            wake: false,
            mood: Mood::Idle,
            holding: false,
            utterance: None,
            last_utterance: 0,
            mic_level: 0.0,
            audio_playing: false,
            idle_deferred: false,
            mood_since_ms: 0,
            transcript: String::new(),
            reply: String::new(),
            reply_until_ms: 0,
            reminder_heading: None,
            speaking: None,
            volume_step: None,
            purge_wait: None,
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
        wire!(on_reply_tapped, |s| s.dismiss_reply());
        wire!(on_entry_tapped, |s, i: i32| s.entry_tapped(i as usize));
        wire!(on_expanded_closed, |s| s.close_expanded());
        wire!(on_volume_step, |s, louder: bool| s.volume_step = Some(louder));
        wire!(on_purge_confirmed, |s| s.purge_confirmed());
        inner.borrow_mut().refresh();
        Controller { inner }
    }

    /// One text frame from the bridge.
    pub fn on_message(&self, json: &str) {
        let mut s = self.inner.borrow_mut();
        // The voice messages are not the model's business.
        match serde_json::from_str::<BoardMsg>(json) {
            Ok(BoardMsg::Creature { mood }) => {
                if mood == Mood::Idle && s.audio_playing && s.mood == Mood::Speaking {
                    s.idle_deferred = true;
                    return;
                }
                s.idle_deferred = false;
                s.set_mood(mood);
                s.refresh();
                return;
            }
            Ok(BoardMsg::Transcript { text, .. }) => {
                s.transcript = text;
                return;
            }
            Ok(BoardMsg::ReplyText { text, .. }) => {
                s.reply = text;
                s.reminder_heading = None;
                s.reply_until_ms = s.time_ms + REPLY_CARD_MS;
                s.refresh();
                return;
            }
            Ok(BoardMsg::Reminder { label, due, .. }) => {
                // `due` is RFC 3339 with the user's offset: characters 11..16 are the local HH:MM.
                s.reminder_heading = Some(format!("Reminder {}", due.get(11..16).unwrap_or("")).trim_end().to_string());
                s.reply = label;
                s.chime = true;
                s.wake = true;
                // The card lives on home; a waiting question keeps the screen and the card is there after it.
                if !matches!(s.nav, Nav::Home) {
                    s.set_nav(Nav::Home);
                }
                s.refresh();
                return;
            }
            Ok(BoardMsg::SpeakStart { utterance, .. }) => {
                s.speaking = Some(utterance);
                s.wake = true;
                return;
            }
            Ok(BoardMsg::SpeakEnd { .. }) => {
                s.speaking = None;
                return;
            }
            Ok(BoardMsg::SessionReset { utterance }) => {
                if s.purge_wait.is_some_and(|(id, _)| id == utterance) {
                    // Only the wait ends here: the bridge's own mood follows (speaking the confirmation, idle when
                    // it could not, offline when its voice is down) and takes over from the thinking.
                    s.purge_wait = None;
                    s.refresh();
                }
                return;
            }
            _ => {}
        }
        if s.model.apply(json) != Applied::Changed {
            return;
        }
        let waiting = s.model.waiting_count();
        let ask = s.model.current_ask().map(|a| a.ask.id.clone());
        if waiting > s.prev_waiting || (ask.is_some() && ask != s.chimed_ask) {
            s.chime = true;
            s.wake = true;
        }
        s.prev_waiting = waiting;
        s.chimed_ask = ask;
        s.refresh();
    }

    /// The bridge connection came up or went down.
    pub fn set_link(&self, up: bool) {
        let mut s = self.inner.borrow_mut();
        let came_up = up && !s.link;
        s.link = up;
        s.wake |= came_up;
        if !up {
            // Whatever the voice path was doing died with the socket: nothing will end it.
            s.holding = false;
            s.utterance = None;
            s.speaking = None;
            s.mic_level = 0.0;
            s.idle_deferred = false;
            s.purge_wait = None;
            s.set_mood(Mood::Idle);
        }
        // The bridge forgets what a board watches when the socket drops: ask again.
        if came_up && matches!(s.nav, Nav::Detail { .. }) {
            if let Some(msg) = s.model.rewatch_msg() {
                s.send(&msg);
            }
        }
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
        if s.menu_open && ms.saturating_sub(s.menu_touched_ms) >= MENU_IDLE_MS {
            s.menu_open = false;
        }
        if s.purge_wait.is_some_and(|(_, at)| ms.saturating_sub(at) >= RESET_WAIT_MS) {
            s.purge_wait = None;
            // Only the thinking the purge put up: a mood the bridge has sent since is its own.
            if s.mood == Mood::Thinking {
                s.set_mood(Mood::Idle);
            }
        }
        s.refresh();
    }

    /// Open the command menu (a swipe down from the top edge). Only home has one.
    pub fn open_menu(&self) {
        let mut s = self.inner.borrow_mut();
        if s.model.current_ask().is_some() || !matches!(s.nav, Nav::Home) {
            return;
        }
        s.menu_open = true;
        s.menu_touched_ms = s.time_ms;
        s.refresh();
    }

    pub fn menu_open(&self) -> bool {
        self.inner.borrow().menu_open
    }

    /// The screen was touched: the menu's idle clock starts again.
    pub fn note_touch(&self) {
        let mut s = self.inner.borrow_mut();
        s.menu_touched_ms = s.time_ms;
    }

    /// `tick_at` for callers with no clock of their own (the tests): half a second passes.
    pub fn tick(&self, now: Option<i64>) {
        let ms = self.inner.borrow().time_ms + 500;
        self.tick_at(now, ms);
    }

    /// A finger has been held at (x, y): true when that starts a voice question (home page, on the avatar), and
    /// then the app starts the microphone.
    pub fn hold_started(&self, x: i16, y: i16) -> bool {
        self.inner.borrow_mut().hold_started(x, y)
    }

    /// Whether a hold at (x, y) would be taken now, with no effect: the app opens the microphone on touch-down
    /// when it would, so the words spoken before the hold is recognised are kept.
    pub fn can_hold_at(&self, x: i16, y: i16) -> bool {
        self.inner.borrow().can_hold_at(x, y)
    }

    /// The held finger lifted: the app stops the microphone. Returns the utterance that ended, if one was open.
    pub fn hold_ended(&self) -> Option<u32> {
        self.inner.borrow_mut().hold_ended()
    }

    /// The utterance in progress or most recently ended.
    pub fn utterance(&self) -> Option<u32> {
        self.inner.borrow().utterance
    }

    /// The microphone level, 0 to 1, while listening.
    pub fn set_mic_level(&self, level: f32) {
        let mut s = self.inner.borrow_mut();
        s.mic_level = level.clamp(0.0, 1.0);
        if s.holding {
            if let Some(win) = s.window.upgrade() {
                win.set_presence_level(s.mic_level);
            }
        }
    }

    /// A tap that is not on a control (the app calls this for taps on other pages): while the creature is
    /// speaking it cancels the speech. True when it did, and the tap should go no further.
    pub fn tap_cancels_speech(&self) -> bool {
        self.inner.borrow_mut().tap_cancels_speech()
    }

    /// Whether the creature is speaking (so the app knows its audio should be playing).
    pub fn is_speaking(&self) -> bool {
        self.inner.borrow().mood == Mood::Speaking
    }

    /// The app's player has audio queued or playing. While true, an `idle` mood from the bridge waits; when it turns
    /// false (the audio drained) a waiting `idle` takes effect.
    pub fn set_audio_playing(&self, on: bool) {
        let mut s = self.inner.borrow_mut();
        s.audio_playing = on;
        if !on && std::mem::take(&mut s.idle_deferred) && s.mood == Mood::Speaking {
            s.set_mood(Mood::Idle);
            s.refresh();
        }
    }

    /// A - (false) or + (true) tap on the volume page since the last call: the app steps the level, saves it and
    /// plays the preview chime, as for a swipe on home.
    pub fn take_volume_step(&self) -> Option<bool> {
        self.inner.borrow_mut().volume_step.take()
    }

    /// True once after something started needing the user.
    pub fn wants_chime(&self) -> bool {
        std::mem::take(&mut self.inner.borrow_mut().chime)
    }

    /// Whether something since the last call should light a dark panel: exactly what chimes (a new question or
    /// approval, a reminder), the start of a spoken reply, and the link coming back. Every other message is only
    /// activity (`power::Power::activity`).
    pub fn take_wake(&self) -> bool {
        std::mem::take(&mut self.inner.borrow_mut().wake)
    }

    /// A question or approval is waiting for an answer from this board: the board must not deep-sleep on it. Not
    /// while the link is down: the bridge has handed it to the terminal, and the `question_clear` that would drop it
    /// cannot arrive.
    pub fn question_waiting(&self) -> bool {
        let s = self.inner.borrow();
        s.link && s.model.current_ask().is_some()
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
        self.time_ms < self.guard_until_ms
    }

    /// Ignore taps on the question for the next `ms` (a later guard is never cut short by an earlier one).
    fn guard(&mut self, ms: u64) {
        self.guard_until_ms = self.guard_until_ms.max(self.time_ms + ms);
    }

    fn submit(&mut self, label: &str) {
        match self.model.answer(label) {
            AnswerOutcome::Complete(msg) => {
                self.send(&msg);
                self.guard(ANSWER_GUARD_MS);
            }
            AnswerOutcome::NextQuestion => self.guard(ANSWER_GUARD_MS),
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
        self.guard(ANSWER_GUARD_MS);
        self.refresh();
    }

    fn open_detail_at(&mut self, i: usize) {
        if let Some(s) = self.model.sessions().get(i) {
            let nav = Nav::Detail { host: s.host.clone(), session: s.session.clone() };
            self.set_nav(nav);
            self.refresh();
        }
    }

    /// Show the list from its first row.
    fn open_list(&mut self) {
        if let Some(win) = self.window.upgrade() {
            win.set_list_scroll(0.0);
        }
        self.set_nav(Nav::List);
        self.refresh();
    }

    fn rim_tapped(&mut self, deg: f32) {
        if self.tap_cancels_speech() {
            return;
        }
        if self.menu_open {
            match command_at(deg) {
                // Purging needs the bridge: while the link is down the arc is dimmed and does nothing.
                Some(Command::Purge) if !self.link => {}
                Some(c) => {
                    self.menu_open = false;
                    self.set_nav(match c {
                        Command::Volume => Nav::Volume,
                        Command::Link => Nav::Link,
                        Command::Purge => Nav::Purge,
                    });
                    self.refresh();
                }
                None => {}
            }
            return;
        }
        let n = self.model.sessions().len();
        match arc_index_at(deg, n) {
            // With more than 12 sessions the last arc stands for the rest: show the list.
            Some(i) if n > MAX_RIM_SEGMENTS && i == MAX_RIM_SEGMENTS - 1 => self.open_list(),
            Some(i) => self.open_detail_at(i),
            None => {}
        }
    }

    fn back_tapped(&mut self) {
        let nav = match self.nav {
            Nav::Detail { .. } => Nav::List,
            _ => Nav::Home,
        };
        self.menu_open = false;
        self.set_nav(nav);
        self.close_expanded();
        self.refresh();
    }

    fn close_expanded(&mut self) {
        if let Some(win) = self.window.upgrade() {
            win.set_expanded_text("".into());
        }
    }

    fn entry_tapped(&mut self, i: usize) {
        let rows = feed_rows(self.model.feed());
        if let (Some(row), Some(win)) = (rows.get(i), self.window.upgrade()) {
            win.set_expanded_text(row.text.as_str().into());
        }
    }

    /// The one place navigation changes. Moving to a different detail target (or off one) stops watching the old
    /// session and starts watching the new, so the bridge only ever streams the feed the board is showing.
    fn set_nav(&mut self, nav: Nav) {
        let target = |n: &Nav| match n {
            Nav::Detail { host, session } => Some((host.clone(), session.clone())),
            _ => None,
        };
        let (old, new) = (target(&self.nav), target(&nav));
        if old != new {
            if let Some(msg) = self.model.unwatch() {
                self.send(&msg);
            }
            if let Some((host, session)) = &new {
                let msg = self.model.watch(host, session);
                self.send(&msg);
            }
            self.close_expanded();
        }
        // A page left mid-hold (a purge confirmed, a question taking over) cannot empty its own ring.
        if !matches!(nav, Nav::Purge) {
            if let Some(win) = self.window.upgrade() {
                win.set_purge_progress(0.0);
            }
        }
        self.nav = nav;
    }

    fn avatar_tapped(&mut self) {
        self.menu_open = false;
        if self.tap_cancels_speech() {
            return;
        }
        self.open_list();
    }

    fn tap_cancels_speech(&mut self) -> bool {
        if self.mood != Mood::Speaking {
            return false;
        }
        if let Some(utterance) = self.speaking.or(self.utterance) {
            self.send(&ClientMsg::Cancel { utterance });
        }
        self.idle_deferred = false;
        self.set_mood(Mood::Idle);
        self.refresh();
        true
    }

    fn set_mood(&mut self, mood: Mood) {
        self.mood = mood;
        self.mood_since_ms = self.time_ms;
    }

    /// A tap on the card. Dismissing a reminder also stops its speech, but only while the bridge is speaking a
    /// bridge-owned (reminder) utterance: the card can arrive while the previous reply still drains, after its
    /// `speak_end`, and that reply must not be cut off. A reminder not yet spoken needs nothing more here; an ordinary
    /// reply card only goes away.
    fn dismiss_reply(&mut self) {
        let reminder = self.reminder_heading.is_some();
        self.reply.clear();
        self.reminder_heading = None;
        if let Some(utterance) = self.speaking.filter(|id| reminder && id & REMINDER_ID_BASE != 0) {
            self.send(&ClientMsg::Cancel { utterance });
            self.idle_deferred = false;
            self.set_mood(Mood::Idle);
        }
        self.refresh();
    }

    /// The purge button was held to the end: start the creature's conversation afresh, named by the next utterance
    /// id, and wait on home for the bridge's `session_reset`. Needs the link, and one purge at a time.
    fn purge_confirmed(&mut self) {
        if !self.link || self.purge_wait.is_some() {
            return;
        }
        self.last_utterance += 1;
        let utterance = self.last_utterance;
        self.send(&ClientMsg::NewSession { utterance });
        self.purge_wait = Some((utterance, self.time_ms));
        // Offline stays offline: the bridge has no voice to confirm with, and the home screen should keep saying so.
        if self.mood != Mood::Offline {
            self.set_mood(Mood::Thinking);
        }
        self.set_nav(Nav::Home);
        self.refresh();
    }

    fn can_hold_at(&self, x: i16, y: i16) -> bool {
        let Some(win) = self.window.upgrade() else { return false };
        let (dx, dy) = ((x - AVATAR_CENTRE) as i32, (y - AVATAR_CENTRE) as i32);
        // Offline: the home screen already says so, and the bridge would discard what we upload.
        self.mood != Mood::Offline && win.get_page() == Page::Home && !self.holding && dx * dx + dy * dy <= AVATAR_RADIUS * AVATAR_RADIUS
    }

    fn hold_started(&mut self, x: i16, y: i16) -> bool {
        if !self.can_hold_at(x, y) {
            return false;
        }
        self.menu_open = false;
        // A purge still waiting gives up: its 10 s fallback must not drop this question's thinking to idle.
        self.purge_wait = None;
        self.last_utterance += 1;
        self.utterance = Some(self.last_utterance);
        self.holding = true;
        self.mic_level = 0.0;
        self.send(&ClientMsg::VoiceStart { utterance: self.last_utterance });
        self.refresh();
        true
    }

    fn hold_ended(&mut self) -> Option<u32> {
        if !std::mem::take(&mut self.holding) {
            return None;
        }
        // No open utterance means nothing was sent, so there is nothing to think about.
        let utterance = self.utterance?;
        self.send(&ClientMsg::VoiceEnd { utterance });
        // The words are on their way: show it thinking until the bridge says otherwise.
        self.set_mood(Mood::Thinking);
        self.mic_level = 0.0;
        self.refresh();
        Some(utterance)
    }

    fn detail_session(&self) -> Option<&Session> {
        let Nav::Detail { host, session } = &self.nav else { return None };
        self.model.sessions().iter().find(|s| &s.host == host && &s.session == session)
    }

    /// Push everything the screen shows from the model, the navigation and the clock.
    fn refresh(&mut self) {
        if matches!(self.nav, Nav::Detail { .. }) && self.detail_session().is_none() {
            self.set_nav(Nav::List); // the session went away
        }
        // A question takes over from the menu and its pages; once answered, the board is back on a plain home.
        if self.model.current_ask().is_some() {
            self.menu_open = false;
            if self.nav.is_command() {
                self.set_nav(Nav::Home);
            }
        }
        let Some(win) = self.window.upgrade() else { return };

        let sessions = self.model.sessions();
        let waiting = self.model.waiting_count();
        let (still, pulsing) = rim_models(sessions, self.menu_open);
        sync(&self.models.rim, still);
        sync(&self.models.rim_pulsing, pulsing);
        win.set_menu_open(self.menu_open);
        win.set_link(self.link);
        win.set_purge_pending(self.purge_wait.is_some());

        if self.mood == Mood::Thinking && self.time_ms.saturating_sub(self.mood_since_ms) >= THINKING_WATCHDOG_MS {
            self.mood = Mood::Idle;
            self.mood_since_ms = self.time_ms;
        }
        if !self.reply.is_empty() && self.reminder_heading.is_none() && self.time_ms >= self.reply_until_ms {
            self.reply.clear();
        }
        win.set_reply_text(shorten(&self.reply, 110).into());
        win.set_reply_heading(shorten(self.reminder_heading.as_deref().unwrap_or(&self.transcript), 40).into());
        win.set_voice_available(self.mood != Mood::Offline);
        let from_sessions = || match presence_for(&self.model) {
            PresenceKind::Idle => PresenceState::Idle,
            PresenceKind::Thinking => PresenceState::Thinking,
            PresenceKind::Alert => PresenceState::Alert,
        };
        win.set_presence_state(if self.holding {
            PresenceState::Listening
        } else {
            match self.mood {
                Mood::Listening => PresenceState::Listening,
                Mood::Thinking => PresenceState::Thinking,
                Mood::Speaking => PresenceState::Speaking,
                Mood::Alert => PresenceState::Alert,
                Mood::Idle | Mood::Offline => from_sessions(),
            }
        });
        win.set_presence_level(if self.holding { self.mic_level } else { 0.0 });
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
        let rows: Vec<FeedRow> = feed_rows(self.model.feed())
            .into_iter()
            .map(|r| FeedRow { kind: r.kind, text: shorten(&r.text, 200).into(), failed: r.failed })
            .collect();
        win.set_feed_empty(rows.is_empty());
        sync(&self.models.feed, rows);

        let mut new_ask = false;
        match self.model.current_ask() {
            Some(ask) => {
                let q = ask.current();
                let key = (ask.ask.id.clone(), ask.next_question());
                if self.sel.key.as_ref() != Some(&key) {
                    // A different ask from the one on screen, as opposed to the next question of the same ask.
                    new_ask = self.sel.key.as_ref().map(|(id, _)| id) != Some(&key.0);
                    self.sel = Selection { key: Some(key), picked: vec![false; q.options.len()] };
                }
                win.set_question_source(
                    format!("{} - {}", shorten(&ask.ask.host, 24), shorten(&ask.ask.project, 40)).to_uppercase().into(),
                );
                win.set_question_text(shorten(&q.question, APPROVAL_TEXT_MAX).into());
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
                    Nav::Volume => Page::Volume,
                    Nav::Link => Page::Link,
                    Nav::Purge => Page::Purge,
                });
            }
        }
        // It has just taken over the screen: a tap meant for what was there a moment ago must not answer it.
        if new_ask {
            self.guard(NEW_ASK_GUARD_MS);
        }
    }
}
