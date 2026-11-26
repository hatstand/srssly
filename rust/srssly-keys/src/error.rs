use thiserror::Error;

/// Errors from key management operations.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum Error {
    /// The authenticator failed to produce a PRF output.
    #[error("authenticator error: {0}")]
    Authenticator(String),
    /// A stored field has the wrong length or encoding.
    #[error("malformed {0}")]
    Malformed(&'static str),
}

impl Error {
    /// A stable snake_case name for scripts and other languages to match on.
    pub fn code(&self) -> &'static str {
        match self {
            Error::Authenticator(_) => "authenticator",
            Error::Malformed(_) => "malformed",
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
