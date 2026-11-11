//! Timer tools for the creature: set, list and cancel. Arguments and labels are never logged.

use std::sync::Arc;

use futures_util::FutureExt;
use futures_util::future::BoxFuture;
use serde_json::{Value, json};

use super::{Tool, ToolDef, ToolOutcome};
use crate::timers::{TimerError, Timers, When, when_words};

pub fn tools(timers: Arc<Timers>) -> Vec<Arc<dyn Tool>> {
    vec![
        Arc::new(SetTimer(timers.clone())),
        Arc::new(ListTimers(timers.clone())),
        Arc::new(CancelTimer(timers)),
    ]
}

fn ready(o: ToolOutcome) -> BoxFuture<'static, ToolOutcome> {
    async move { o }.boxed()
}

fn err(e: TimerError) -> ToolOutcome {
    ToolOutcome::Error(e.to_string())
}

struct SetTimer(Arc<Timers>);
impl Tool for SetTimer {
    fn def(&self) -> ToolDef {
        ToolDef {
            name: "set_timer",
            description: "Set a timer or reminder. Give exactly one of in_seconds (how long from now) or at \
                (a local Toronto time as YYYY-MM-DDTHH:MM). The board speaks the label when it is due.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "label": {"type": "string", "description": "What to say when the timer fires"},
                    "in_seconds": {"type": "integer", "minimum": 1},
                    "at": {"type": "string", "description": "YYYY-MM-DDTHH:MM, Toronto local time"},
                },
                "required": ["label"],
            }),
        }
    }
    fn call(&self, args: Value) -> BoxFuture<'static, ToolOutcome> {
        let Some(label) = args.get("label").and_then(Value::as_str) else {
            return ready(err(TimerError::BadLabel));
        };
        let secs = args.get("in_seconds").filter(|v| !v.is_null());
        let at = args.get("at").filter(|v| !v.is_null());
        let when = match (secs, at) {
            (Some(s), None) => match s.as_u64() {
                Some(s) => When::In(s),
                None => return ready(err(TimerError::BadTime("in_seconds must be a whole number of seconds.".into()))),
            },
            (None, Some(a)) => match a.as_str() {
                Some(a) => When::At(a.to_string()),
                None => return ready(err(TimerError::BadTime("at must be a text time.".into()))),
            },
            _ => {
                return ready(err(TimerError::BadTime("Give either in_seconds or at, but not both.".into())));
            }
        };
        ready(match self.0.set(label, when) {
            Ok(t) => ToolOutcome::Text(format!(
                "Timer set: {}, fires at {}.",
                t.label,
                when_words(t.due, self.0.now())
            )),
            Err(e) => err(e),
        })
    }
}

struct ListTimers(Arc<Timers>);
impl Tool for ListTimers {
    fn def(&self) -> ToolDef {
        ToolDef { name: "list_timers", description: "List the pending timers.", input_schema: json!({"type": "object"}) }
    }
    fn call(&self, _args: Value) -> BoxFuture<'static, ToolOutcome> {
        let list = self.0.list();
        let now = self.0.now();
        if list.is_empty() {
            return ready(ToolOutcome::Text("No timers.".into()));
        }
        let lines: Vec<String> = list
            .iter()
            .map(|t| {
                let mins = ((t.due - now).max(0) + 59) / 60;
                format!("{} {}: {}, in {} minutes", t.id, t.label, when_words(t.due, now), mins)
            })
            .collect();
        ready(ToolOutcome::Text(lines.join("\n")))
    }
}

struct CancelTimer(Arc<Timers>);
impl Tool for CancelTimer {
    fn def(&self) -> ToolDef {
        ToolDef {
            name: "cancel_timer",
            description: "Cancel a pending timer by its id or its label.",
            input_schema: json!({
                "type": "object",
                "properties": {"id_or_label": {"type": "string"}},
                "required": ["id_or_label"],
            }),
        }
    }
    fn call(&self, args: Value) -> BoxFuture<'static, ToolOutcome> {
        let Some(sel) = args.get("id_or_label").and_then(Value::as_str) else {
            return ready(err(TimerError::NotFound));
        };
        ready(match self.0.cancel(sel) {
            Ok(t) => ToolOutcome::Text(format!("Timer cancelled: {}.", t.label)),
            Err(e) => err(e),
        })
    }
}
