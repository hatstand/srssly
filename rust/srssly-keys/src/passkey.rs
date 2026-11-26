use std::fmt;

use hkdf::Hkdf;
use hmac::{Hmac, KeyInit, Mac};
use hpke::Kem as _;
use hpke::Serializable as _;
use hpke::kem::X25519HkdfSha256;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{Error, Result, b64, random_bytes};

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

/// Something that holds a passkey and can evaluate its WebAuthn PRF.
///
/// [`SoftPasskey`] implements it in software. Hardware security keys, Touch
/// ID and platform passkeys are further implementations.
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
        Ok(Self(
            bytes
                .try_into()
                .map_err(|_| Error::Malformed("credential ID hash"))?,
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
        let mut expected = Sha256::new();
        expected.update(b"WebAuthn PRF\x00");
        expected.update(PRF_INPUT);
        let expected: [u8; 32] = expected.finalize().into();
        assert_eq!(ctap_hmac_secret_salt(PRF_INPUT), expected);
    }

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

    #[test]
    fn key_pair_is_deterministic() {
        let prf = PrfOutput::from_bytes([3; 32]);
        assert_eq!(
            PasskeyKeyPair::from_prf(&prf).public_key(),
            PasskeyKeyPair::from_prf(&prf).public_key()
        );
        let other = PrfOutput::from_bytes([4; 32]);
        assert_ne!(
            PasskeyKeyPair::from_prf(&prf).public_key(),
            PasskeyKeyPair::from_prf(&other).public_key()
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
    }

    /// Expected values from `scripts/known_answers.py`, an independent
    /// implementation of the CTAP salt, hmac-secret and RFC 9180 DeriveKeyPair.
    #[test]
    fn known_answer() {
        let pk = SoftPasskey::from_parts(b"cred".to_vec(), [9; 32]);
        let prf = pk.evaluate_prf(PRF_INPUT).unwrap();
        crate::keys::tests::assert_hex(
            "prf",
            prf.as_bytes(),
            "0763ce60a3fe189c114c48cf3a5ef43bbe48429e10c6384a67de5ead8a96e1f9",
        );
        crate::keys::tests::assert_hex(
            "passkey_public",
            PasskeyKeyPair::from_prf(&prf).public_key(),
            "3819b8a928132364538f0874ebacc1d03b551b8e2d1c3c0af8163d0209babd3e",
        );
    }

    #[test]
    fn debug_hides_secrets() {
        let pk = SoftPasskey::from_parts(vec![1, 2], [9; 32]);
        assert!(!format!("{pk:?}").contains("cred_random"));
        assert_eq!(
            format!("{:?}", PrfOutput::from_bytes([1; 32])),
            "PrfOutput(..)"
        );
    }
}
