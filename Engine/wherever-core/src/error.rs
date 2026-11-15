use std::path::Path;
use std::{fmt, io};

#[derive(Debug, uniffi::Error)]
pub enum EngineError {
    Io { message: String },
    Stale { generation: u64 },
    Stopped,
    Callback { message: String },
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

impl From<io::Error> for EngineError {
    fn from(e: io::Error) -> Self {
        EngineError::Io {
            message: e.to_string(),
        }
    }
}

pub fn io_error(path: &Path, e: impl fmt::Display) -> EngineError {
    EngineError::Io {
        message: format!("{}: {e}", path.display()),
    }
}

impl From<uniffi::UnexpectedUniFFICallbackError> for EngineError {
    fn from(e: uniffi::UnexpectedUniFFICallbackError) -> Self {
        EngineError::Callback { message: e.reason }
    }
}
