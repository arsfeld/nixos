//! The Cylon Bot screens. The Slint components live in `ui/`; this crate holds the logic that feeds
//! them and the headless harness that renders them on the host.

slint::include_modules!();

pub mod audio;
pub mod controller;
pub mod frame;
pub mod headless;
pub mod link;
pub mod power;
pub mod rim;
pub mod theme;
pub mod touch;
pub mod view;
