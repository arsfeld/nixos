//! The clients plab's code is generic over, bundled so a signature names one parameter
//! instead of one per client. Production uses `Live`; tests define a marker per set of
//! fakes, next to the fakes.

use crate::codedb::{CodeDb, CodeSearch};
use crate::llm::{Llm, OpenRouter};
use crate::stash::{Stash, StashApi};
use crate::tracker::{Tracker, TrackerApi};
use crate::transmission::{TorrentClient, Transmission};

/// The tracker and the torrent client: what the list refresh, adds, curated runs and the
/// web server use. The `'static` bounds are what axum's router state needs.
pub trait Backends: Send + Sync + 'static {
    type Tracker: TrackerApi + 'static;
    type Torrents: TorrentClient + 'static;
}

/// What an identify pass uses.
pub trait IdentifyBackends: Send + Sync + 'static {
    type Stash: StashApi + 'static;
    type Llm: Llm + 'static;
    type CodeSearch: CodeSearch + 'static;
    type Torrents: TorrentClient + 'static;
}

/// The real clients.
pub struct Live;

impl Backends for Live {
    type Tracker = Tracker;
    type Torrents = Transmission;
}

impl IdentifyBackends for Live {
    type Stash = Stash;
    type Llm = OpenRouter;
    type CodeSearch = CodeDb;
    type Torrents = Transmission;
}
