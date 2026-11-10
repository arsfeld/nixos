//! The board's model of the world: the sessions the bridge reports and the questions waiting for an
//! answer. Pure logic over the wire types, so it is tested on the host; the firmware and the UI only
//! read it and call [`Model::answer`].

use std::collections::BTreeMap;

use crate::{AskId, BoardMsg, ClientMsg, PendingAsk, Question, Session, State};

/// What [`Model::apply`] did with a message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Applied {
    /// The model may have changed: redraw.
    Changed,
    /// A well-formed message of a kind this version does not know (or a greeting): nothing changed.
    Ignored,
    /// Not valid JSON or missing fields: nothing changed.
    Malformed,
}

/// A question held by the board, with the answers given so far.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ask {
    pub ask: PendingAsk,
    answers: Vec<String>,
    dismissed: bool,
}

impl Ask {
    fn new(ask: PendingAsk) -> Self {
        Ask { ask, answers: Vec::new(), dismissed: false }
    }

    /// Index of the question of this ask that is waiting for an answer.
    pub fn next_question(&self) -> usize {
        self.answers.len()
    }

    /// The question waiting for an answer. Only valid for an ask returned by [`Model::current_ask`].
    pub fn current(&self) -> &Question {
        &self.ask.questions[self.answers.len()]
    }

    fn waiting(&self) -> bool {
        !self.dismissed && self.answers.len() < self.ask.questions.len()
    }
}

/// What [`Model::answer`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AnswerOutcome {
    /// Recorded; more questions of the same ask remain.
    NextQuestion,
    /// That was the last question: send this message to the bridge.
    Complete(ClientMsg),
    /// No question is waiting.
    NoQuestion,
}

#[derive(Debug, Default)]
pub struct Model {
    sessions: Vec<Session>,
    asks: Vec<Ask>,
}

impl Model {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apply one message from the bridge (a JSON text frame).
    ///
    /// A `state` snapshot replaces every session and drops every held question: the bridge re-sends
    /// the pending ones straight after it.
    pub fn apply(&mut self, json: &str) -> Applied {
        let Ok(msg) = serde_json::from_str::<BoardMsg>(json) else {
            return Applied::Malformed;
        };
        match msg {
            BoardMsg::Hello { .. } | BoardMsg::Unknown => return Applied::Ignored,
            BoardMsg::State { sessions } => {
                self.sessions = sessions;
                self.asks.clear();
            }
            BoardMsg::Upsert { session } => {
                match self.sessions.iter_mut().find(|s| s.host == session.host && s.session == session.session) {
                    Some(slot) => *slot = session,
                    None => self.sessions.push(session),
                }
            }
            BoardMsg::Remove { host, session } => {
                self.sessions.retain(|s| !(s.host == host && s.session == session));
            }
            BoardMsg::Question { ask } => {
                // Already held: a re-send after a reconnect.
                if !self.asks.iter().any(|a| a.ask.id == ask.id) {
                    self.asks.push(Ask::new(ask));
                }
            }
            BoardMsg::QuestionClear { id } => self.asks.retain(|a| a.ask.id != id),
        }
        self.sort();
        Applied::Changed
    }

    fn sort(&mut self) {
        // Waiting first, then newest state change first; host and session make it deterministic.
        self.sessions.sort_by(|a, b| {
            (a.state != State::Waiting)
                .cmp(&(b.state != State::Waiting))
                .then(b.since.cmp(&a.since))
                .then_with(|| a.host.cmp(&b.host))
                .then_with(|| a.session.cmp(&b.session))
        });
    }

    pub fn sessions(&self) -> &[Session] {
        &self.sessions
    }

    pub fn waiting_count(&self) -> usize {
        self.sessions.iter().filter(|s| s.state == State::Waiting).count()
    }

    /// The oldest question still waiting for an answer and not dismissed.
    pub fn current_ask(&self) -> Option<&Ask> {
        self.asks.iter().find(|a| a.waiting())
    }

    /// Questions held, including fully answered ones awaiting the bridge's `question_clear`.
    pub fn ask_count(&self) -> usize {
        self.asks.len()
    }

    /// Stop showing the question with this id (the user declined it). It is still held, and still
    /// counted, until the bridge's `question_clear` removes it. Unknown ids are ignored.
    pub fn dismiss(&mut self, id: &AskId) {
        for a in self.asks.iter_mut().filter(|a| &a.ask.id == id) {
            a.dismissed = true;
        }
    }

    /// Record the answer to the question on screen: its option label, or the labels of a multi-select
    /// question joined with [`join_labels`].
    pub fn answer(&mut self, label: &str) -> AnswerOutcome {
        let Some(a) = self.asks.iter_mut().find(|a| a.waiting()) else {
            return AnswerOutcome::NoQuestion;
        };
        a.answers.push(label.to_owned());
        if a.answers.len() < a.ask.questions.len() {
            return AnswerOutcome::NextQuestion;
        }
        // The exact question text is the key, never truncated.
        let answers: BTreeMap<String, String> =
            a.ask.questions.iter().map(|q| q.question.clone()).zip(a.answers.iter().cloned()).collect();
        AnswerOutcome::Complete(ClientMsg::Answer { id: a.ask.id.clone(), answers })
    }

    /// The message that declines to answer the question on screen ("answer on computer").
    pub fn decline_msg(&self) -> Option<ClientMsg> {
        self.current_ask().map(|a| ClientMsg::Decline { id: a.ask.id.clone() })
    }
}

/// Labels joined with "," as the question tool expects for a multi-select answer.
pub fn join_labels(labels: &[&str]) -> String {
    labels.join(",")
}

/// How many bytes of `s` (at most `max_bytes`) to show: never ends in the middle of a character.
pub fn fit(s: &str, max_bytes: usize) -> usize {
    let mut n = max_bytes.min(s.len());
    while !s.is_char_boundary(n) {
        n -= 1;
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ClientMsg, State};

    fn load(name: &str) -> String {
        let dir = format!("{}/../claude-board-bridge/tests/fixtures/board", env!("CARGO_MANIFEST_DIR"));
        std::fs::read_to_string(format!("{dir}/{name}.json")).unwrap()
    }

    fn apply_fixture(m: &mut Model, name: &str) -> Applied {
        m.apply(&load(name))
    }

    fn ids(m: &Model) -> Vec<&str> {
        m.sessions().iter().map(|s| s.session.as_str()).collect()
    }

    const ID1: &str = "00000000000000000000000000000001";
    const ID2: &str = "00000000000000000000000000000002";

    #[test]
    fn state_fixture_sorts_waiting_first() {
        let mut m = Model::new();
        assert_eq!(apply_fixture(&mut m, "state"), Applied::Changed);
        assert_eq!(ids(&m), ["s-2", "s-3", "s-1"]); // waiting, done since 1200, working since 1000
        assert_eq!(m.waiting_count(), 1);
        let s1 = m.sessions().iter().find(|s| s.session == "s-1").unwrap();
        assert_eq!((s1.host.as_str(), s1.project.as_str(), s1.state, s1.since), ("raider", "nixos", State::Working, 1000));
    }

    #[test]
    fn upsert_replaces_by_host_and_session() {
        let mut m = Model::new();
        apply_fixture(&mut m, "state");
        assert_eq!(apply_fixture(&mut m, "upsert"), Applied::Changed);
        assert_eq!(m.sessions().len(), 3);
        assert_eq!(ids(&m), ["s-2", "s-1", "s-3"]); // s-1 is now error, since 1300, ahead of s-3
        assert_eq!(m.sessions()[1].state, State::Error);
    }

    #[test]
    fn remove_drops_the_session() {
        let mut m = Model::new();
        apply_fixture(&mut m, "state");
        assert_eq!(apply_fixture(&mut m, "remove"), Applied::Changed);
        assert_eq!(ids(&m), ["s-2", "s-3"]);
    }

    #[test]
    fn single_question_becomes_current_ask() {
        let mut m = Model::new();
        assert!(m.current_ask().is_none());
        assert_eq!(apply_fixture(&mut m, "question_single"), Applied::Changed);
        let a = m.current_ask().unwrap();
        assert_eq!((a.ask.id.0.as_str(), a.ask.host.as_str(), a.ask.project.as_str()), (ID1, "galactica", "plab"));
        let q = a.current();
        assert_eq!(q.question, "Which colour?");
        assert_eq!(q.header.as_deref(), Some("Colour"));
        assert_eq!(q.options.len(), 2);
        assert_eq!(q.options[1].label, "Blue");
        assert_eq!(q.options[1].description, None);
        assert!(!q.multi_select);
    }

    #[test]
    fn question_clear_removes_only_the_matching_id() {
        let mut m = Model::new();
        apply_fixture(&mut m, "question_single");
        apply_fixture(&mut m, "question_multi");
        assert_eq!(m.ask_count(), 2);
        assert_eq!(apply_fixture(&mut m, "question_clear"), Applied::Changed); // id ...01
        assert_eq!(m.ask_count(), 1);
        assert_eq!(m.current_ask().unwrap().ask.id.0, ID2);
    }

    #[test]
    fn state_snapshot_drops_held_asks() {
        // The bridge re-sends every pending question right after a snapshot, so one cleared while the
        // board was offline must not survive the reconnect.
        let mut m = Model::new();
        apply_fixture(&mut m, "question_single");
        apply_fixture(&mut m, "state");
        assert!(m.current_ask().is_none());
        assert_eq!(m.ask_count(), 0);
    }

    #[test]
    fn duplicate_question_id_is_ignored() {
        let mut m = Model::new();
        apply_fixture(&mut m, "question_single");
        apply_fixture(&mut m, "question_single");
        assert_eq!(m.ask_count(), 1);
    }

    #[test]
    fn malformed_json_leaves_the_model_unchanged() {
        let mut m = Model::new();
        apply_fixture(&mut m, "state");
        for bad in [
            "{not json",
            "",
            "[1,2]",
            r#"{"t":"upsert"}"#,
            r#"{"t":"question","id":"x"}"#,
            // One bad element must not half-apply a snapshot.
            r#"{"t":"state","sessions":[{"host":"a","session":"b","project":"c","state":"idle","since":1},{"host":"only"}]}"#,
        ] {
            assert_eq!(m.apply(bad), Applied::Malformed, "{bad}");
        }
        assert_eq!(ids(&m), ["s-2", "s-3", "s-1"]);
    }

    #[test]
    fn unknown_state_maps_to_idle() {
        let mut m = Model::new();
        let msg = r#"{"t":"upsert","session":{"host":"h","session":"s","project":"p","state":"levitating","since":5}}"#;
        assert_eq!(m.apply(msg), Applied::Changed);
        assert_eq!(m.sessions()[0].state, State::Idle);
    }

    #[test]
    fn hello_with_a_future_version_is_ignored() {
        let mut m = Model::new();
        apply_fixture(&mut m, "state");
        assert_eq!(m.apply(r#"{"t":"hello","version":99,"features":["voice"]}"#), Applied::Ignored);
        assert_eq!(ids(&m), ["s-2", "s-3", "s-1"]);
    }

    #[test]
    fn unknown_type_is_ignored_and_changes_nothing() {
        let mut m = Model::new();
        apply_fixture(&mut m, "state");
        assert_eq!(m.apply(r#"{"t":"nonsense"}"#), Applied::Ignored);
        assert_eq!(m.apply(r#"{"t":"session_output","session":"s-1","lines":["x"]}"#), Applied::Ignored);
        assert_eq!(m.sessions().len(), 3);
    }

    #[test]
    fn unknown_fields_on_upsert_are_ignored() {
        let mut m = Model::new();
        let msg = r#"{"t":"upsert","later":1,"session":{"host":"h","session":"s","project":"p","state":"idle","since":1,"cwd":"/","avatar":"x"}}"#;
        assert_eq!(m.apply(msg), Applied::Changed);
        assert_eq!(m.sessions().len(), 1);
    }

    #[test]
    fn long_fields_are_kept_whole() {
        // Truncation for display is the UI's job (see `fit`); the model never loses data.
        let project = "🙂".repeat(90);
        let msg = format!(
            r#"{{"t":"upsert","session":{{"host":"h","session":"s","project":"{project}","state":"idle","since":1}}}}"#
        );
        let mut m = Model::new();
        assert_eq!(m.apply(&msg), Applied::Changed);
        assert_eq!(m.sessions()[0].project, project);
    }

    fn answers_of(msg: ClientMsg) -> (String, std::collections::BTreeMap<String, String>) {
        match msg {
            ClientMsg::Answer { id, answers } => (id.0, answers),
            other => panic!("expected an answer, got {other:?}"),
        }
    }

    #[test]
    fn answer_complete_uses_the_exact_question_text_as_key() {
        let mut m = Model::new();
        apply_fixture(&mut m, "question_single");
        let (id, answers) = answers_of(match m.answer("Blue") {
            AnswerOutcome::Complete(msg) => msg,
            other => panic!("{other:?}"),
        });
        assert_eq!(id, ID1);
        assert_eq!(answers.len(), 1);
        assert_eq!(answers["Which colour?"], "Blue");
    }

    #[test]
    fn unicode_question_text_is_kept_intact_in_the_answer_key() {
        let text = "🎨 Cuál es tu color? e\u{0301}\u{200d}🙂";
        let mut m = Model::new();
        apply_fixture(&mut m, "question_unicode");
        assert_eq!(m.current_ask().unwrap().current().question, text);
        let AnswerOutcome::Complete(msg) = m.answer("Α β ✓") else { panic!() };
        let (_, answers) = answers_of(msg);
        assert_eq!(answers[text], "Α β ✓");
    }

    #[test]
    fn a_very_long_question_is_stored_whole_and_the_key_is_not_truncated() {
        let text = "x".repeat(5000);
        let msg = format!(
            r#"{{"t":"question","id":"l","host":"h","session":"s","project":"p","questions":[{{"question":"{text}","header":null,"options":[{{"label":"A","description":null}}],"multiSelect":false}}]}}"#
        );
        let mut m = Model::new();
        assert_eq!(m.apply(&msg), Applied::Changed);
        assert_eq!(m.current_ask().unwrap().current().question.len(), 5000);
        let AnswerOutcome::Complete(msg) = m.answer("A") else { panic!() };
        assert_eq!(answers_of(msg).1.keys().next().unwrap().len(), 5000);
    }

    #[test]
    fn multi_question_fixture_needs_all_answers_before_complete() {
        let mut m = Model::new();
        apply_fixture(&mut m, "question_multi");
        assert!(matches!(m.answer("Pear"), AnswerOutcome::NextQuestion));
        let a = m.current_ask().unwrap();
        assert_eq!(a.next_question(), 1);
        assert_eq!(a.current().question, "Which toppings?");
        let AnswerOutcome::Complete(msg) = m.answer("Nuts,Honey") else { panic!() };
        let (_, answers) = answers_of(msg);
        assert_eq!(answers["Which fruit?"], "Pear");
        assert_eq!(answers["Which toppings?"], "Nuts,Honey");
        assert!(m.current_ask().is_none()); // answered; waiting only for the bridge's clear
        assert_eq!(m.ask_count(), 1);
    }

    #[test]
    fn answer_with_no_ask_is_noquestion() {
        let mut m = Model::new();
        assert!(matches!(m.answer("x"), AnswerOutcome::NoQuestion));
    }

    #[test]
    fn join_labels_uses_commas() {
        assert_eq!(join_labels(&["Nuts", "Honey"]), "Nuts,Honey");
        assert_eq!(join_labels(&["Nuts"]), "Nuts");
        assert_eq!(join_labels(&[]), "");
    }

    #[test]
    fn decline_msg_matches_the_wire_shape() {
        let mut m = Model::new();
        assert_eq!(m.decline_msg(), None);
        apply_fixture(&mut m, "question_single");
        let json = serde_json::to_string(&m.decline_msg().unwrap()).unwrap();
        assert_eq!(json, format!(r#"{{"t":"decline","id":"{ID1}"}}"#));
    }

    #[test]
    fn dismissed_ask_is_not_current_but_is_still_counted_until_clear() {
        let mut m = Model::new();
        apply_fixture(&mut m, "question_single");
        apply_fixture(&mut m, "question_multi");
        m.dismiss(&crate::AskId(ID1.into()));
        assert_eq!(m.ask_count(), 2);
        assert_eq!(m.current_ask().unwrap().ask.id.0, ID2); // moves on to the next
        m.dismiss(&crate::AskId("no-such-id".into())); // harmless
        assert_eq!(m.ask_count(), 2);
        // Answers go to the question being shown, not the dismissed one.
        assert!(matches!(m.answer("Pear"), AnswerOutcome::NextQuestion));
        apply_fixture(&mut m, "question_clear"); // the bridge clears ...01
        assert_eq!(m.ask_count(), 1);
    }

    #[test]
    fn fit_never_splits_a_char() {
        let s = "aé日🙂b"; // 1 + 2 + 3 + 4 + 1 = 11 bytes
        assert_eq!(s.len(), 11);
        for (max, want) in [(100, 11), (2, 1), (3, 3), (5, 3), (6, 6), (9, 6), (10, 10), (0, 0)] {
            assert_eq!(fit(s, max), want, "max {max}");
        }
        for max in 0..=12 {
            assert!(s.is_char_boundary(fit(s, max)));
        }
        assert_eq!(fit("héllo", 2), 1);
        assert_eq!(fit("héllo", 3), 3);
    }
}
