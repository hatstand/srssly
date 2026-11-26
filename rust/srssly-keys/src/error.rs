use thiserror::Error;

/// Errors from key management operations.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum Error {
    /// The PRF output doesn't belong to the passkey this wrapped secret was sealed to.
    #[error("this passkey does not match the stored passkey record")]
    WrongPasskey,
    /// Decryption failed: the data was tampered with or belongs to another account or epoch.
    #[error("decryption failed")]
    DecryptionFailed,
    /// The recovery words are invalid.
    #[error("invalid recovery key: {0}")]
    InvalidRecoveryKey(String),
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
            Error::WrongPasskey => "wrong_passkey",
            Error::DecryptionFailed => "decryption_failed",
            Error::InvalidRecoveryKey(_) => "invalid_recovery_key",
            Error::Authenticator(_) => "authenticator",
            Error::Malformed(_) => "malformed",
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
