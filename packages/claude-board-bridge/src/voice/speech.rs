//! Turning reply text into something a speech engine can say, and audio into
//! chunks a socket can carry. Pure functions, no I/O.

/// Fragments shorter than this are carried into the next sentence.
const MIN_SENTENCE: usize = 8;

/// Abbreviations whose trailing `.` does not end a sentence.
const ABBREVIATIONS: [&str; 6] = ["e.g", "i.e", "vs", "dr", "mr", "mrs"];

/// Drops code and markup, replaces URLs and removes symbols a speech engine
/// would read out loud or stumble over.
pub fn clean_for_speech(text: &str) -> String {
    let mut kept = String::new();
    for (i, part) in text.split("```").enumerate() {
        // Odd parts sit inside a fence; an unterminated fence drops to the end.
        if i % 2 == 0 {
            kept.push_str(part);
            kept.push(' ');
        }
    }
    let mut out = String::new();
    for word in kept.split_whitespace() {
        let word = if word.contains("://") { "link" } else { word };
        for c in word.chars() {
            match c {
                '_' => out.push(' '),
                '#' | '*' | '>' | '`' => {}
                '\u{2018}' | '\u{2019}' => out.push('\''),
                c if c.is_alphanumeric() || c.is_ascii_punctuation() => out.push(c),
                // Other symbols, emoji and non-ASCII punctuation become a
                // space so the words around them do not glue together.
                _ => out.push(' '),
            }
        }
        out.push(' ');
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn ends_with_abbreviation(before_dot: &str) -> bool {
    let lower = before_dot.to_lowercase();
    ABBREVIATIONS.iter().any(|a| {
        lower.strip_suffix(a).is_some_and(|rest| {
            !rest.chars().next_back().is_some_and(char::is_alphanumeric)
        })
    })
}

/// Cuts streamed text deltas into cleaned, speakable sentences.
#[derive(Default)]
pub struct SentenceSplitter {
    buf: String,
}

impl SentenceSplitter {
    pub fn new() -> SentenceSplitter {
        SentenceSplitter::default()
    }

    /// Adds a delta and returns the sentences it completed.
    pub fn push(&mut self, delta: &str) -> Vec<String> {
        self.buf.push_str(delta);
        let mut out = Vec::new();
        let mut from = 0;
        let chars: Vec<(usize, char)> = self.buf.char_indices().collect();
        for (n, &(i, c)) in chars.iter().enumerate() {
            let end = i + c.len_utf8();
            let boundary = match c {
                '\n' => true,
                '.' | '!' | '?' => {
                    let next = chars.get(n + 1).map(|&(_, c)| c);
                    next.is_some_and(char::is_whitespace)
                        // Decimals like 3.14 are safe: a boundary needs
                        // whitespace after the dot.
                        && !(c == '.' && ends_with_abbreviation(&self.buf[from..i]))
                }
                _ => false,
            };
            // Never cut inside an open code fence.
            if !boundary || self.buf[from..end].matches("```").count() % 2 == 1 {
                continue;
            }
            let cleaned = clean_for_speech(&self.buf[from..end]);
            if cleaned.chars().count() >= MIN_SENTENCE {
                out.push(cleaned);
                from = end;
            }
        }
        self.buf.drain(..from);
        out
    }

    /// The trailing fragment, if anything speakable is left.
    pub fn finish(&mut self) -> Option<String> {
        let cleaned = clean_for_speech(&std::mem::take(&mut self.buf));
        (!cleaned.is_empty()).then_some(cleaned)
    }
}

/// Splits 16-bit PCM into chunks of at most `max` bytes, never inside a
/// sample. A trailing odd byte is dropped, and a `max` below 2 yields
/// 2-byte chunks.
pub fn chunk_pcm(pcm: &[u8], max: usize) -> impl Iterator<Item = &[u8]> {
    let size = (max & !1).max(2);
    pcm[..pcm.len() & !1].chunks(size)
}
