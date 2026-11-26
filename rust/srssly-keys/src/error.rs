use thiserror::Error;

/// Errors from key management operations.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum Error {
    /// The authenticator failed to produce a PRF output.
    #[error("authenticator error: {0}")]
    Authenticator(String),
}

impl Error {
    /// A stable snake_case name for scripts and other languages to match on.
    pub fn code(&self) -> &'static str {
        match self {
            Error::Authenticator(_) => "authenticator",
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
