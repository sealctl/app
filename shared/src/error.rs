//! The app crate's error type.

/// Failures of the app rules and the local database.
#[derive(uniffi::Error, thiserror::Error, Debug, Clone, PartialEq, Eq)]
pub enum AppError {
    /// The local database failed.
    #[error("storage: {msg}")]
    Storage {
        /// What failed (no secrets).
        msg: String,
    },
    /// State bytes that do not decode.
    #[error("cannot read this state")]
    Decode,
    /// State written by a newer app.
    #[error("this state comes from a newer app")]
    NewerVersion,
    /// No such record.
    #[error("not found")]
    NotFound,
    /// A value outside its allowed range.
    #[error("invalid: {msg}")]
    Invalid {
        /// Which value.
        msg: String,
    },
}

impl From<rusqlite::Error> for AppError {
    fn from(e: rusqlite::Error) -> Self {
        AppError::Storage { msg: e.to_string() }
    }
}

impl From<serde_json::Error> for AppError {
    fn from(_: serde_json::Error) -> Self {
        AppError::Decode
    }
}

/// Shorthand.
pub type Result<T> = std::result::Result<T, AppError>;
