pub mod api;
pub mod cmd;
pub mod config;
pub mod creds;
pub mod state;
pub mod connect;
pub mod exits;

/// One line to the journal, prefixed like the Python version's.
pub fn log(msg: &str) {
    eprintln!("pia: {msg}");
}
pub mod portforward;
pub mod watchdog;
