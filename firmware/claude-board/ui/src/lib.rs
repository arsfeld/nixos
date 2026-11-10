//! The Claude Board screens. The Slint components live in `ui/`; this crate holds the logic that feeds
//! them and the headless harness that renders them on the host.

slint::include_modules!();

pub mod headless;
pub mod rim;
pub mod theme;
pub mod view;
