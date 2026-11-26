//! Key management for Srssly's end-to-end encrypted sync.
//!
//! Every account has one random 32-byte [`RootSecret`], from which every
//! other key derives. See `README.md` for the design.

mod account;
mod b64;
mod error;
mod keys;
mod passkey;

// Keep `crate::recovery` and `crate::wrap` as short paths inside the crate.
use keys::{recovery, wrap};

pub use account::AccountId;
pub use error::{Error, Result};
pub use keys::{DataKey, DerivedKeys, KeyCheck, RootSecret};
pub use passkey::{
    CredentialIdHash, PRF_INPUT, PasskeyKeyPair, PrfAuthenticator, PrfOutput, SoftPasskey,
    ctap_hmac_secret_salt,
};
pub use recovery::RecoveryKey;
pub use wrap::WrappedSecret;

pub(crate) fn random_bytes<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    getrandom::fill(&mut out).expect("system random number generator failed");
    out
}
