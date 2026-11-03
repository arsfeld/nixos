//! The assistant's conversations and messages.

use super::*;

#[derive(Debug, Clone, PartialEq)]
pub struct ConversationRow {
    pub id: i64,
    pub title: String,
    pub kind: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MessageRow {
    pub seq: i64,
    pub role: String,
    pub content: String,
    pub at: i64,
}

fn conversation_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<ConversationRow> {
    Ok(ConversationRow {
        id: r.get(0)?,
        title: r.get(1)?,
        kind: r.get(2)?,
        created_at: r.get(3)?,
        updated_at: r.get(4)?,
    })
}

impl Db {
    pub fn create_conversation(&self, title: &str, kind: &str, now: i64) -> Result<i64> {
        self.with(|c| {
            c.execute(
                "INSERT INTO conversation (title, kind, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)",
                params![title, kind, now],
            )?;
            Ok(c.last_insert_rowid())
        })
    }

    pub fn conversations(&self) -> Result<Vec<ConversationRow>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT id, title, kind, created_at, updated_at FROM conversation
                 ORDER BY updated_at DESC, id DESC",
            )?;
            let rows = s.query_map([], conversation_row)?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    pub fn conversation(&self, id: i64) -> Result<Option<ConversationRow>> {
        self.with(|c| {
            Ok(c.query_row(
                "SELECT id, title, kind, created_at, updated_at FROM conversation WHERE id = ?1",
                params![id],
                conversation_row,
            )
            .optional()?)
        })
    }

    pub fn delete_conversation(&self, id: i64) -> Result<bool> {
        self.with(|c| Ok(c.execute("DELETE FROM conversation WHERE id = ?1", params![id])? > 0))
    }

    /// Append one message; returns its seq.
    pub fn append_message(
        &self,
        conversation: i64,
        role: &str,
        content: &str,
        now: i64,
    ) -> Result<i64> {
        self.append(conversation, &[(role, content)], now)
    }

    /// Append `(role, content)` messages with consecutive seqs, all or none: a tool round
    /// (the assistant's tool_calls and every result) must never be stored half-way.
    pub fn append_messages(
        &self,
        conversation: i64,
        msgs: &[(&str, String)],
        now: i64,
    ) -> Result<()> {
        let msgs: Vec<(&str, &str)> = msgs.iter().map(|(r, c)| (*r, c.as_str())).collect();
        self.append(conversation, &msgs, now).map(|_| ())
    }

    /// One transaction; returns the first message's seq.
    fn append(&self, conversation: i64, msgs: &[(&str, &str)], now: i64) -> Result<i64> {
        self.with(|c| {
            let tx = c.transaction()?;
            let first: i64 = tx.query_row(
                "SELECT COALESCE(MAX(seq) + 1, 0) FROM message WHERE conversation_id = ?1",
                params![conversation],
                |r| r.get(0),
            )?;
            for (seq, (role, content)) in (first..).zip(msgs) {
                tx.execute(
                    "INSERT INTO message (conversation_id, seq, role, content, at) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![conversation, seq, role, content, now],
                )?;
            }
            tx.execute(
                "UPDATE conversation SET updated_at = ?2 WHERE id = ?1",
                params![conversation, now],
            )?;
            tx.commit()?;
            Ok(first)
        })
    }

    pub fn messages(&self, conversation: i64) -> Result<Vec<MessageRow>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT seq, role, content, at FROM message WHERE conversation_id = ?1 ORDER BY seq",
            )?;
            let rows = s.query_map(params![conversation], |r| {
                Ok(MessageRow {
                    seq: r.get(0)?,
                    role: r.get(1)?,
                    content: r.get(2)?,
                    at: r.get(3)?,
                })
            })?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    pub fn delete_messages_from(&self, conversation: i64, seq: i64) -> Result<()> {
        self.with(|c| {
            c.execute(
                "DELETE FROM message WHERE conversation_id = ?1 AND seq >= ?2",
                params![conversation, seq],
            )?;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversations_round_trip() {
        let db = Db::open_in_memory().unwrap();
        let a = db.create_conversation("first", "chat", 10).unwrap();
        let b = db.create_conversation("second", "recommend", 20).unwrap();
        assert_eq!(
            db.append_message(a, "user", r#"{"role":"user","content":"hi"}"#, 30)
                .unwrap(),
            0
        );
        assert_eq!(db.append_message(a, "assistant", "{}", 31).unwrap(), 1);
        let list = db.conversations().unwrap();
        assert_eq!(list.iter().map(|c| c.id).collect::<Vec<_>>(), vec![a, b]);
        assert_eq!(list[0].updated_at, 31);
        let msgs = db.messages(a).unwrap();
        assert_eq!(
            msgs.iter()
                .map(|m| (m.seq, m.role.as_str()))
                .collect::<Vec<_>>(),
            vec![(0, "user"), (1, "assistant")]
        );
        db.delete_messages_from(a, 1).unwrap();
        assert_eq!(db.messages(a).unwrap().len(), 1);
        assert!(db.delete_conversation(a).unwrap());
        assert!(!db.delete_conversation(a).unwrap());
        assert!(db.messages(a).unwrap().is_empty());
        assert_eq!(db.conversation(b).unwrap().unwrap().kind, "recommend");
        assert!(db.conversation(a).unwrap().is_none());
    }

    #[test]
    fn append_messages_is_one_consecutive_batch() {
        let db = Db::open_in_memory().unwrap();
        let id = db.create_conversation("t", "chat", 10).unwrap();
        db.append_message(id, "user", "{}", 11).unwrap();
        db.append_messages(id, &[("assistant", "{}".into()), ("tool", "{}".into())], 40)
            .unwrap();
        assert_eq!(
            db.messages(id)
                .unwrap()
                .iter()
                .map(|m| (m.seq, m.role.as_str()))
                .collect::<Vec<_>>(),
            vec![(0, "user"), (1, "assistant"), (2, "tool")]
        );
        assert_eq!(db.conversation(id).unwrap().unwrap().updated_at, 40);
    }
}
