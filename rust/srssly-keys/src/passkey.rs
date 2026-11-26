use std::fmt;

use hkdf::Hkdf;
use hpke::Kem as _;
use hpke::Serializable as _;
use hpke::kem::X25519HkdfSha256;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{Error, Result, b64};

// Software passkeys exist only in tests and in builds that ask for them
// (the CLI), never in an app.
#[cfg(any(test, feature = "soft-passkey"))]
mod soft;
#[cfg(any(test, feature = "soft-passkey"))]
pub use soft::SoftPasskey;

/// The PRF input every Srssly client passes to WebAuthn (`prf.eval.first`).
///
/// It is the same for every credential, so a usernameless sign-in can ask
/// for the PRF before it knows which passkey the user will pick.
pub const PRF_INPUT: &[u8] = b"srssly/v1/passkey-prf";

/// The salt a CTAP2 authenticator's `hmac-secret` extension receives for a
/// WebAuthn PRF input: `SHA-256("WebAuthn PRF" || 0x00 || input)`, as the
/// WebAuthn Level 3 spec defines. Browsers and platform APIs apply this for
/// you; code that talks CTAP directly (a YubiKey over USB, say) must apply it
/// itself so its outputs match the ones a browser would get.
pub fn ctap_hmac_secret_salt(prf_input: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"WebAuthn PRF");
    h.update([0u8]);
    h.update(prf_input);
    h.finalize().into()
}

/// The 32-byte output of a passkey's PRF for [`PRF_INPUT`].
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct PrfOutput([u8; 32]);

impl PrfOutput {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl fmt::Debug for PrfOutput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PrfOutput(..)")
    }
}

/// Something that holds a passkey and can evaluate its WebAuthn PRF:
/// a software passkey for tests, a hardware security key, Touch ID or a
/// platform passkey API.
pub trait PrfAuthenticator {
    /// The WebAuthn credential ID.
    fn credential_id(&self) -> &[u8];

    /// Evaluates the PRF for a WebAuthn-level input (not the CTAP salt).
    fn evaluate_prf(&self, input: &[u8]) -> Result<PrfOutput>;
}

/// SHA-256 of a WebAuthn credential ID; the relay indexes passkeys by it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct CredentialIdHash(#[serde(with = "b64")] [u8; 32]);

impl CredentialIdHash {
    pub fn of(credential_id: &[u8]) -> Self {
        Self(Sha256::digest(credential_id).into())
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    pub fn to_base64url(&self) -> String {
        b64::encode(&self.0)
    }

    pub fn from_base64url(s: &str) -> Result<Self> {
        let bytes = b64::decode(s).ok_or(Error::Malformed("credential ID hash"))?;
        let bytes = bytes.try_into();
        Ok(Self(
            bytes.map_err(|_| Error::Malformed("credential ID hash"))?,
        ))
    }
}

/// The X25519 key pair a passkey's PRF output stands for. Its public key is
/// stored on the relay, so the root secret can be sealed to the passkey
/// without asking it again.
pub struct PasskeyKeyPair {
    pub(crate) private: <X25519HkdfSha256 as hpke::Kem>::PrivateKey,
    pub(crate) public: [u8; 32],
}

impl PasskeyKeyPair {
    /// RFC 9180 `DeriveKeyPair` from `HKDF-SHA256(salt =
    /// "srssly/v1/passkey-kem", ikm = PRF output, info = "x25519")`.
    pub fn from_prf(prf: &PrfOutput) -> Self {
        let mut ikm = [0u8; 32];
        Hkdf::<Sha256>::new(Some(b"srssly/v1/passkey-kem"), prf.as_bytes())
            .expand(b"x25519", &mut ikm)
            .expect("HKDF output length is valid");
        let (private, public) = X25519HkdfSha256::derive_keypair(&ikm);
        ikm.zeroize();
        let public: [u8; 32] = public.to_bytes().into();
        Self { private, public }
    }

    pub fn public_key(&self) -> &[u8; 32] {
        &self.public
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ctap_salt_matches_webauthn_definition() {
        // SHA-256("WebAuthn PRF\0srssly/v1/passkey-prf"), from `scripts/known_answers.py`.
        crate::keys::tests::assert_hex("ctap_salt", &ctap_hmac_secret_salt(PRF_INPUT), CTAP_SALT);
    }

    const CTAP_SALT: &str = "09cfa2c104ea19b7a59f9472b2b6fd18194db1b560fa3bff1add23bfdd921a42";

    #[test]
    fn key_pair_is_deterministic_per_prf() {
        let prf = PrfOutput::from_bytes([3; 32]);
        let other = PrfOutput::from_bytes([4; 32]);
        let public = |p| *PasskeyKeyPair::from_prf(p).public_key();
        assert_eq!(public(&prf), public(&prf));
        assert_ne!(public(&prf), public(&other));
    }

    /// Expected value from `scripts/known_answers.py`, which implements
    /// RFC 9180 DeriveKeyPair independently.
    #[test]
    fn key_pair_known_answer() {
        let pk = SoftPasskey::from_parts(b"cred".to_vec(), [9; 32]);
        let prf = pk.evaluate_prf(PRF_INPUT).unwrap();
        crate::keys::tests::assert_hex(
            "passkey_public",
            PasskeyKeyPair::from_prf(&prf).public_key(),
            "3819b8a928132364538f0874ebacc1d03b551b8e2d1c3c0af8163d0209babd3e",
        );
    }

    #[test]
    fn credential_id_hash_round_trips() {
        let h = CredentialIdHash::of(b"cred");
        assert_eq!(
            CredentialIdHash::from_base64url(&h.to_base64url()).unwrap(),
            h
        );
        assert!(CredentialIdHash::from_base64url("short").is_err());
        assert!(CredentialIdHash::from_base64url("!!").is_err());
    }

    #[test]
    fn debug_hides_secrets() {
        assert_eq!(
            format!("{:?}", PrfOutput::from_bytes([1; 32])),
            "PrfOutput(..)"
        );
    }
}
