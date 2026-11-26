//! Key management for Srssly's end-to-end encrypted sync.
//!
//! Every account has one random 32-byte [`RootSecret`], from which every
//! other key derives. See `README.md` for the design.

mod account;
mod b64;
mod error;
mod keys;
mod passkey;
mod wrap;

pub use account::AccountId;
pub use error::{Error, Result};
pub use keys::{DataKey, DerivedKeys, KeyCheck, RootSecret};
#[cfg(any(test, feature = "soft-passkey"))]
pub use passkey::SoftPasskey;
pub use passkey::{
    CredentialIdHash, PRF_INPUT, PasskeyKeyPair, PrfAuthenticator, PrfOutput, ctap_hmac_secret_salt,
};
pub use wrap::WrappedSecret;

pub(crate) fn random_bytes<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    getrandom::fill(&mut out).expect("system random number generator failed");
    out
}
