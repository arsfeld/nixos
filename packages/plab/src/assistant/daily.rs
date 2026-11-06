//! The daily picks shown on For you: which recommend conversation is shown, whether today
//! has been attempted, and which dailies count as followed up (kept, and listed in the
//! history) rather than unread (left out of the history, pruned after 30 days).
//! Design: docs/superpowers/specs/2026-11-03-plab-daily-picks-design.md

use anyhow::Result;
use serde_json::Value;

use super::{error_of, is_hidden, parse_final};
use crate::db::{ConversationRow, Db};

/// Unread dailies older than this are deleted when a new one is made.
pub const KEEP_DAYS: i64 = 30;

/// A timestamp's date on this machine's clock (galactica's local time), `YYYY-MM-DD`.
pub fn local_ymd(ts: i64) -> String {
    use chrono::TimeZone;
    chrono::Local
        .timestamp_opt(ts, 0)
        .single()
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

#[derive(Debug, Default, PartialEq)]
pub struct Daily {
    /// The newest recommend conversation whose answer has at least one pick.
    pub shown: Option<ConversationRow>,
    /// The newest recommend conversation was created today, whatever came of it.
    pub attempted_today: bool,
    /// Today's attempt has no good answer: its error, that it never finished, or that
    /// it had no picks.
    pub error: Option<String>,
}

fn parsed(db: &Db, id: i64) -> Result<Vec<(String, Value)>> {
    Ok(db
        .messages(id)?
        .into_iter()
        .filter_map(|m| serde_json::from_str(&m.content).ok().map(|v| (m.role, v)))
        .collect())
}

/// User turns the user can see: the canned ask counts, a hidden re-ask does not.
fn user_turns(msgs: &[(String, Value)]) -> usize {
    msgs.iter()
        .filter(|(r, v)| r == "user" && !is_hidden(v))
        .count()
}

/// The daily's answer: the first shown assistant message (not hidden, not a tool call).
fn first_answer(msgs: &[(String, Value)]) -> Option<&Value> {
    msgs.iter()
        .find(|(r, v)| {
            r == "assistant"
                && !is_hidden(v)
                && v.get("tool_calls")
                    .and_then(Value::as_array)
                    .is_none_or(|a| a.is_empty())
        })
        .map(|(_, v)| v)
}

fn has_picks(answer: Option<&Value>) -> bool {
    answer
        .and_then(|v| v.get("content")?.as_str())
        .and_then(parse_final)
        .is_some_and(|f| !f.picks.is_empty())
}

pub fn state(db: &Db, now: i64) -> Result<Daily> {
    let today = local_ymd(now);
    let mut d = Daily::default();
    for (i, row) in db
        .conversations_of_kind("recommend")?
        .into_iter()
        .enumerate()
    {
        let msgs = parsed(db, row.id)?;
        let answer = first_answer(&msgs);
        if i == 0 && local_ymd(row.created_at) == today {
            d.attempted_today = true;
            d.error = match answer {
                Some(v) => match error_of(v) {
                    Some(e) => Some(e.to_owned()),
                    None if !has_picks(answer) => Some("today's answer had no picks".into()),
                    None => None,
                },
                None => Some("today's picks did not finish".into()),
            };
        }
        if has_picks(answer) {
            d.shown = Some(row);
            break;
        }
    }
    Ok(d)
}

/// The user asked something of this conversation beyond its first question.
pub fn followed_up(db: &Db, id: i64) -> Result<bool> {
    Ok(user_turns(&parsed(db, id)?) > 1)
}

/// Delete the unread dailies older than `KEEP_DAYS`. Returns how many went.
pub fn prune(db: &Db, now: i64) -> Result<usize> {
    let cutoff = now - KEEP_DAYS * 86_400;
    let mut n = 0;
    for row in db.conversations_of_kind("recommend")? {
        if row.created_at < cutoff && !followed_up(db, row.id)? {
            db.delete_conversation(row.id)?;
            n += 1;
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const DAY: i64 = 86_400;
    /// Noon UTC: the same local date in any time zone from UTC-12 to UTC+11.
    const NOON: i64 = 20_000 * DAY + 43_200;

    fn answer(picks: Value) -> Value {
        json!({"role": "assistant", "content": json!({"text": "t", "picks": picks}).to_string()})
    }

    fn conv(db: &Db, at: i64, msgs: &[Value]) -> i64 {
        let id = db
            .create_conversation("Recommendations", "recommend", at)
            .unwrap();
        for m in msgs {
            db.append_message(id, m["role"].as_str().unwrap(), &m.to_string(), at)
                .unwrap();
        }
        id
    }

    fn ask() -> Value {
        json!({"role": "user", "content": "recommend"})
    }

    fn good() -> Vec<Value> {
        vec![
            json!({"role": "system", "content": "s"}),
            ask(),
            answer(json!([{"ref": "t:1", "action": "download", "reason": "r"}])),
        ]
    }

    #[test]
    fn nothing_yet() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(state(&db, NOON).unwrap(), Daily::default());
    }

    #[test]
    fn yesterday_is_shown_and_today_is_not_attempted() {
        let db = Db::open_in_memory().unwrap();
        let y = conv(&db, NOON - DAY, &good());
        let d = state(&db, NOON).unwrap();
        assert_eq!(d.shown.map(|r| r.id), Some(y));
        assert!(!d.attempted_today);
        assert_eq!(d.error, None);
    }

    #[test]
    fn a_failed_today_keeps_yesterday_and_carries_the_error() {
        let db = Db::open_in_memory().unwrap();
        let y = conv(&db, NOON - DAY, &good());
        conv(
            &db,
            NOON,
            &[
                ask(),
                json!({"role": "assistant", "content": "", "plab_error": "boom"}),
            ],
        );
        let d = state(&db, NOON + 60).unwrap();
        assert_eq!(d.shown.map(|r| r.id), Some(y));
        assert!(d.attempted_today);
        assert_eq!(d.error.as_deref(), Some("boom"));
    }

    #[test]
    fn today_good_is_shown_without_error() {
        let db = Db::open_in_memory().unwrap();
        conv(&db, NOON - DAY, &good());
        let t = conv(&db, NOON, &good());
        let d = state(&db, NOON).unwrap();
        assert_eq!(
            (d.shown.map(|r| r.id), d.attempted_today, d.error),
            (Some(t), true, None)
        );
    }

    #[test]
    fn an_unfinished_today_is_an_error() {
        let db = Db::open_in_memory().unwrap();
        conv(&db, NOON, &[ask()]);
        let d = state(&db, NOON).unwrap();
        assert!(d.attempted_today && d.shown.is_none());
        assert_eq!(d.error.as_deref(), Some("today's picks did not finish"));
    }

    #[test]
    fn an_answer_without_picks_is_not_shown() {
        let db = Db::open_in_memory().unwrap();
        conv(&db, NOON - DAY, &[ask(), answer(json!([]))]);
        assert_eq!(state(&db, NOON).unwrap().shown, None);
    }

    #[test]
    fn a_today_answer_without_picks_is_an_error() {
        let db = Db::open_in_memory().unwrap();
        let y = conv(&db, NOON - DAY, &good());
        conv(&db, NOON, &[ask(), answer(json!([]))]);
        let d = state(&db, NOON).unwrap();
        assert_eq!(d.shown.map(|r| r.id), Some(y));
        assert_eq!(d.error.as_deref(), Some("today's answer had no picks"));
        let db = Db::open_in_memory().unwrap();
        conv(
            &db,
            NOON,
            &[ask(), json!({"role": "assistant", "content": "not json"})],
        );
        assert_eq!(
            state(&db, NOON).unwrap().error.as_deref(),
            Some("today's answer had no picks")
        );
    }

    #[test]
    fn followed_up_needs_a_second_visible_user_turn() {
        let db = Db::open_in_memory().unwrap();
        let mut msgs = good();
        msgs.push(json!({"role": "user", "content": "again", "plab_hidden": true}));
        let id = conv(&db, NOON, &msgs);
        assert!(!followed_up(&db, id).unwrap());
        db.append_message(
            id,
            "user",
            &json!({"role": "user", "content": "why?"}).to_string(),
            NOON,
        )
        .unwrap();
        assert!(followed_up(&db, id).unwrap());
    }

    #[test]
    fn prune_drops_only_old_unread_dailies() {
        let db = Db::open_in_memory().unwrap();
        let old = conv(&db, NOON - 31 * DAY, &good());
        let mut asked = good();
        asked.push(json!({"role": "user", "content": "why?"}));
        let kept = conv(&db, NOON - 31 * DAY, &asked);
        let recent = conv(&db, NOON - 29 * DAY, &good());
        let chat = db
            .create_conversation("c", "chat", NOON - 40 * DAY)
            .unwrap();
        assert_eq!(prune(&db, NOON).unwrap(), 1);
        assert!(db.conversation(old).unwrap().is_none());
        for id in [kept, recent, chat] {
            assert!(db.conversation(id).unwrap().is_some());
        }
    }
}
