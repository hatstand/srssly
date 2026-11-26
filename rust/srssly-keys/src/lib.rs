//! Key management for Srssly's end-to-end encrypted sync.
//!
//! Every account has one random 32-byte [`RootSecret`], from which every
//! other key derives. See `README.md` for the design.

mod account;
mod error;
mod keys;
mod passkey;

pub use account::AccountId;
pub use error::{Error, Result};
pub use keys::{DerivedKeys, KeyCheck, RootSecret};
pub use passkey::{PRF_INPUT, PrfAuthenticator, PrfOutput, ctap_hmac_secret_salt};

pub(crate) fn random_bytes<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    getrandom::fill(&mut out).expect("system random number generator failed");
    out
}
