use std::fmt;

use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{Result, b64, random_bytes};

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

/// A passkey held in software, for tests and the CLI.
///
/// It behaves like a CTAP2 authenticator with `hmac-secret`: the PRF output
/// is `HMAC-SHA-256(credRandom, ctap_hmac_secret_salt(input))`.
#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct SoftPasskey {
    #[serde(with = "b64")]
    credential_id: Vec<u8>,
    #[serde(with = "b64")]
    cred_random: [u8; 32],
}

impl SoftPasskey {
    /// A new passkey with a random 16-byte credential ID.
    pub fn generate() -> Self {
        Self {
            credential_id: random_bytes::<16>().to_vec(),
            cred_random: random_bytes(),
        }
    }

    pub fn from_parts(credential_id: Vec<u8>, cred_random: [u8; 32]) -> Self {
        Self {
            credential_id,
            cred_random,
        }
    }
}

impl fmt::Debug for SoftPasskey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SoftPasskey")
            .field("credential_id", &b64::encode(&self.credential_id))
            .finish_non_exhaustive()
    }
}

impl PrfAuthenticator for SoftPasskey {
    fn credential_id(&self) -> &[u8] {
        &self.credential_id
    }

    fn evaluate_prf(&self, input: &[u8]) -> Result<PrfOutput> {
        let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(&self.cred_random)
            .expect("HMAC accepts any key length");
        mac.update(&ctap_hmac_secret_salt(input));
        Ok(PrfOutput(mac.finalize().into_bytes().into()))
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
    fn soft_passkey_prf_is_deterministic_per_input() {
        let pk = SoftPasskey::generate();
        assert_eq!(
            pk.evaluate_prf(b"a").unwrap(),
            pk.evaluate_prf(b"a").unwrap()
        );
        assert_ne!(
            pk.evaluate_prf(b"a").unwrap(),
            pk.evaluate_prf(b"b").unwrap()
        );
    }

    #[test]
    fn soft_passkeys_differ() {
        let a = SoftPasskey::generate();
        let b = SoftPasskey::generate();
        assert_ne!(a.credential_id(), b.credential_id());
        assert_ne!(
            a.evaluate_prf(PRF_INPUT).unwrap(),
            b.evaluate_prf(PRF_INPUT).unwrap()
        );
    }

    #[test]
    fn soft_passkey_round_trips_through_json() {
        let pk = SoftPasskey::generate();
        let json = serde_json::to_string(&pk).unwrap();
        let back: SoftPasskey = serde_json::from_str(&json).unwrap();
        assert_eq!(back.credential_id(), pk.credential_id());
        assert_eq!(
            back.evaluate_prf(PRF_INPUT).unwrap(),
            pk.evaluate_prf(PRF_INPUT).unwrap()
        );
    }

    /// Expected value from `scripts/known_answers.py`, which implements
    /// CTAP2 hmac-secret independently.
    #[test]
    fn soft_passkey_known_answer() {
        let pk = SoftPasskey::from_parts(b"cred".to_vec(), [9; 32]);
        crate::keys::tests::assert_hex(
            "prf",
            pk.evaluate_prf(PRF_INPUT).unwrap().as_bytes(),
            "0763ce60a3fe189c114c48cf3a5ef43bbe48429e10c6384a67de5ead8a96e1f9",
        );
    }

    #[test]
    fn debug_hides_secrets() {
        assert_eq!(
            format!("{:?}", PrfOutput::from_bytes([1; 32])),
            "PrfOutput(..)"
        );
        let pk = SoftPasskey::from_parts(vec![1, 2], [9; 32]);
        assert!(!format!("{pk:?}").contains("cred_random"));
    }
}
