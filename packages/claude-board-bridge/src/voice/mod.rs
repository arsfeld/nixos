pub mod backends;
pub mod pipeline;
pub mod speech;

pub use pipeline::{Conn, Out, VoiceConfig};
pub use speech::{SentenceSplitter, chunk_pcm, clean_for_speech};
