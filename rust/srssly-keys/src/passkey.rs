use std::fmt;

use sha2::{Digest, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::Result;

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
    fn debug_hides_prf_output() {
        assert_eq!(
            format!("{:?}", PrfOutput::from_bytes([1; 32])),
            "PrfOutput(..)"
        );
    }
}
