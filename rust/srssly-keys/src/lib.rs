//! Key management for Srssly's end-to-end encrypted sync.
//!
//! Every account has one random 32-byte [`RootSecret`]. It never leaves a
//! device unencrypted. The relay stores an [`AccountKeys`] record holding one
//! [`WrappedSecret`] per passkey: the root secret sealed with HPKE to an X25519
//! key pair derived from that passkey's WebAuthn PRF output. So:
//!
//! - signing in with any registered passkey unlocks the root secret,
//! - adding a passkey needs only the root secret and the new passkey's PRF output,
//! - rotating the root secret re-seals it to every stored public key without
//!   asking each passkey again.
//!
//! The data and relay-authentication keys are derived from the root secret
//! (see [`DerivedKeys`]). A [`RecoveryKey`] encodes the root secret as 24
//! BIP39 words for when every passkey is gone.
//!
//! Authenticators sit behind the [`PrfAuthenticator`] trait. [`SoftPasskey`]
//! is a software stand-in for tests and the CLI; hardware keys and platform
//! passkeys plug in behind the same trait later.

mod account;
mod b64;
mod error;
mod keys;
mod passkey;
mod recovery;
mod wrap;

pub use account::{AccountId, AccountKeys, PasskeyInfo};
pub use error::{Error, Result};
pub use keys::{DerivedKeys, KeyCheck, RootSecret};
pub use passkey::{
    CredentialIdHash, PRF_INPUT, PasskeyKeyPair, PrfAuthenticator, PrfOutput, SoftPasskey,
    ctap_hmac_secret_salt,
};
pub use recovery::RecoveryKey;
pub use wrap::WrappedSecret;
/// Format version of every serialized structure in this crate.
pub const FORMAT_VERSION: u32 = 1;

pub(crate) fn random_bytes<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    getrandom::fill(&mut out).expect("system random number generator failed");
    out
}
