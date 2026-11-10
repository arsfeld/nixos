use claude_board_bridge::voice::{SentenceSplitter, chunk_pcm, clean_for_speech};

#[test]
fn splitter_cuts_at_sentence_ends() {
    let mut s = SentenceSplitter::new();
    assert_eq!(
        s.push("Hello there. How are you? Fine"),
        vec!["Hello there.".to_string(), "How are you?".to_string()]
    );
    assert_eq!(s.finish(), Some("Fine".to_string()));
    assert_eq!(s.finish(), None);
}

#[test]
fn splitter_does_not_cut_decimals_or_abbreviations() {
    let mut s = SentenceSplitter::new();
    assert!(s.push("Pi is 3.14 today, e.g. now.").is_empty());
    assert_eq!(s.finish(), Some("Pi is 3.14 today, e.g. now.".to_string()));

    let mut s = SentenceSplitter::new();
    assert!(s.push("Ask Dr. Smith about it vs. waiting ").is_empty());
}

#[test]
fn splitter_joins_deltas_split_mid_word() {
    let mut s = SentenceSplitter::new();
    assert!(s.push("The build pas").is_empty());
    assert!(s.push("sed with no warn").is_empty());
    assert!(s.push("ings.").is_empty());
    assert_eq!(s.push(" Next"), vec!["The build passed with no warnings.".to_string()]);
    assert_eq!(s.finish(), Some("Next".to_string()));
}

#[test]
fn splitter_ignores_empty_and_whitespace_only_input() {
    let mut s = SentenceSplitter::new();
    assert!(s.push("").is_empty());
    assert!(s.push("  \n \t").is_empty());
    assert_eq!(s.finish(), None);
}

#[test]
fn splitter_carries_short_fragments_and_cuts_at_newlines() {
    let mut s = SentenceSplitter::new();
    assert_eq!(
        s.push("Yes. It works fine now\nNext line "),
        vec!["Yes. It works fine now".to_string()]
    );
    assert_eq!(s.finish(), Some("Next line".to_string()));
}

#[test]
fn clean_drops_code_blocks_and_keeps_inline_code_text() {
    let text = "Run this:\n```bash\nnix build .#foo\n```\nthen call `just deploy` to finish.";
    assert_eq!(clean_for_speech(text), "Run this: then call just deploy to finish.");
}

#[test]
fn clean_replaces_urls_with_link() {
    assert_eq!(
        clean_for_speech("See https://claude-board.arsfeld.one/v1/feed?x=1 for details."),
        "See link for details."
    );
}

#[test]
fn clean_removes_emoji_and_markdown_markers() {
    assert_eq!(
        clean_for_speech("## Done \u{1F389}\n> **All** tests _pass_ \u{2705}"),
        "Done All tests pass"
    );
}

#[test]
fn chunk_pcm_never_splits_a_sample_and_respects_max() {
    let pcm: Vec<u8> = (0..11).collect();
    let chunks: Vec<&[u8]> = chunk_pcm(&pcm, 5).collect();
    assert!(chunks.iter().all(|c| c.len() % 2 == 0 && c.len() <= 5));
    assert_eq!(chunks[0].len(), 4);
    assert_eq!(chunks.concat(), pcm[..10].to_vec());
}

#[test]
fn chunk_pcm_of_empty_input_yields_nothing() {
    assert_eq!(chunk_pcm(&[], 4096).count(), 0);
}
