uniffi::setup_scaffolding!();

#[global_allocator]
static ALLOC: alloc::BigAlloc = alloc::BigAlloc;

mod access;
mod alloc;
mod apply;
mod archive;
mod crawl;
mod engine;
mod error;
mod fsevents;
#[cfg(test)]
mod helpexamples;
mod index;
mod live;
mod opens;
mod query;
mod rank;
mod session;
mod sort;
mod text;
mod unit;

pub use archive::{
    ArchiveChange, ArchiveClash, ArchiveEditing, ArchiveJob, ArchiveProblem, ArchiveSession,
    ArchiveSummary,
};
pub use engine::Engine;
pub use error::EngineError;
pub use session::EngineSession;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct EngineVolume {
    pub root: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct EngineHit {
    pub name: String,
    pub folder: String,
    pub size: u64,
    pub modified: i64,
    pub created: i64,
    pub opened: i64,
    pub kind: EngineKind,
    pub matches: Vec<EngineMatch>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct EngineMatch {
    pub start: u32,
    pub length: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct EngineSort {
    pub column: EngineColumn,
    pub ascending: bool,
    pub folders_first: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EngineColumn {
    Relevance,
    Name,
    Folder,
    Size,
    Modified,
    Created,
    Opened,
    Kind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EngineKind {
    File,
    Folder,
    Link,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EngineConfig {
    pub root: String,
    pub home: String,
    pub data_folder: String,
    pub socket_folder: Option<String>,
    pub excluded: Vec<String>,
    pub indexed_volumes: Vec<String>,
    #[uniffi(default = false)]
    pub live_updates_paused: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EngineState {
    pub phase: EnginePhase,
    pub boot_phase: EnginePhase,
    pub indexing: Vec<String>,
    pub troubles: Vec<EngineTrouble>,
    pub indexed: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EnginePhase {
    Loading,
    Crawling,
    Finishing,
    Ready,
    Live,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EngineTrouble {
    pub root: String,
    pub kind: EngineTroubleKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EngineTroubleKind {
    Unreadable,
    LiveUpdatesOff,
}

#[uniffi::export(foreign)]
pub trait EngineListener: Send + Sync {
    fn state_changed(&self, state: EngineState) -> Result<(), EngineError>;
    fn results_changed(&self, opened_only: bool) -> Result<(), EngineError>;
    fn results_ready(&self, generation: u64, count: u32) -> Result<(), EngineError>;
    fn search_failed(&self, generation: u64) -> Result<(), EngineError>;
    fn content_progress(
        &self,
        generation: u64,
        read: u64,
        total: u64,
        not_downloaded: u64,
        unreadable: u64,
        done: bool,
    ) -> Result<(), EngineError>;
    fn fault(&self, message: String) -> Result<(), EngineError>;
}
