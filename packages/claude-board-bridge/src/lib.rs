pub mod protocol;
pub mod asks;
pub mod feed;
pub mod board;
pub mod auth;
pub mod http;
pub mod state;

use axum::Router;

/// Hook endpoints and the board socket on one router.
pub fn app(state: http::AppState) -> Router {
    http::hook_router(state.clone()).merge(board::board_router(state))
}
