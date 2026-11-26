use std::fmt;

use ed25519_dalek::SigningKey;
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::account::AccountId;
use crate::{b64, random_bytes};

/// The account's root secret: 32 random bytes from which every other key derives.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct RootSecret([u8; 32]);

impl RootSecret {
    /// A new random root secret.
    pub fn generate() -> Self {
        Self(random_bytes())
    }

    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    fn hkdf(&self, account: &AccountId) -> Hkdf<Sha256> {
        let mut salt = b"srssly/v1/root/".to_vec();
        salt.extend_from_slice(account.as_bytes());
        Hkdf::<Sha256>::new(Some(&salt), &self.0)
    }

    fn expand<const N: usize>(&self, account: &AccountId, info: &[u8]) -> [u8; N] {
        let mut out = [0u8; N];
        self.hkdf(account)
            .expand(info, &mut out)
            .expect("HKDF output length is valid");
        out
    }

    /// The public check value for this secret, which the relay stores so a
    /// client can tell whether a secret (say, from a recovery key) is current.
    pub fn key_check(&self, account: &AccountId) -> KeyCheck {
        KeyCheck(self.expand(account, b"key-check"))
    }

    /// The keys derived from this secret for `account`.
    pub fn derive(&self, account: &AccountId) -> DerivedKeys {
        let data_key = self.expand(account, b"data-key");
        let auth_seed: [u8; 32] = self.expand(account, b"auth-key");
        DerivedKeys {
            data_key,
            auth_key: SigningKey::from_bytes(&auth_seed),
        }
    }
}

impl fmt::Debug for RootSecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RootSecret(..)")
    }
}

/// Keys derived from the root secret.
pub struct DerivedKeys {
    /// AES-256-GCM key for sync records.
    pub data_key: [u8; 32],
    /// Ed25519 key that authenticates this account to the relay.
    pub auth_key: SigningKey,
}

impl DerivedKeys {
    /// The relay identifies the account's current key by this public key.
    pub fn auth_public_key(&self) -> [u8; 32] {
        self.auth_key.verifying_key().to_bytes()
    }
}

impl Drop for DerivedKeys {
    fn drop(&mut self) {
        self.data_key.zeroize();
    }
}

/// A 16-byte public value that identifies a root secret without revealing it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyCheck(#[serde(with = "b64")] [u8; 16]);

impl KeyCheck {
    pub fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    fn account() -> AccountId {
        AccountId::from_bytes([7; 16])
    }

    #[test]
    fn derivation_is_deterministic() {
        let root = RootSecret::from_bytes([1; 32]);
        let a = root.derive(&account());
        let b = root.derive(&account());
        assert_eq!(a.data_key, b.data_key);
        assert_eq!(a.auth_public_key(), b.auth_public_key());
        assert_eq!(root.key_check(&account()), root.key_check(&account()));
    }

    #[test]
    fn derived_keys_are_independent() {
        let root = RootSecret::from_bytes([1; 32]);
        let keys = root.derive(&account());
        assert_ne!(keys.data_key, keys.auth_key.to_bytes());
        assert_ne!(&keys.data_key[..16], root.key_check(&account()).as_bytes());
    }

    #[test]
    fn derivation_depends_on_account_and_secret() {
        let root = RootSecret::from_bytes([1; 32]);
        let other_account = AccountId::from_bytes([8; 16]);
        assert_ne!(
            root.derive(&account()).data_key,
            root.derive(&other_account).data_key
        );
        let other_root = RootSecret::from_bytes([2; 32]);
        assert_ne!(root.key_check(&account()), other_root.key_check(&account()));
    }

    #[test]
    fn generated_secrets_differ() {
        assert_ne!(RootSecret::generate(), RootSecret::generate());
    }

    #[test]
    fn debug_hides_secret() {
        let root = RootSecret::from_bytes([0xAB; 32]);
        assert_eq!(format!("{root:?}"), "RootSecret(..)");
    }

    /// Pins the derivation so other implementations (Swift, Kotlin, web) can
    /// check they match byte for byte. The expected values come from the
    /// independent Python implementation in `scripts/known_answers.py`.
    #[test]
    fn known_answer() {
        let root = RootSecret::from_bytes([1; 32]);
        let keys = root.derive(&account());
        assert_hex(
            "key_check",
            root.key_check(&account()).as_bytes(),
            KAT_KEY_CHECK,
        );
        assert_hex("data_key", &keys.data_key, KAT_DATA_KEY);
        assert_hex("auth_public", &keys.auth_public_key(), KAT_AUTH_PUBLIC);
    }

    const KAT_KEY_CHECK: &str = "569b212342900e7981bf6ebcc19865bc";
    const KAT_DATA_KEY: &str = "c3f98b38d6afda017c359a1192342d596b85d1d2f60c657fa37475df84d2c2ce";
    const KAT_AUTH_PUBLIC: &str =
        "b0745fcd50b58602711805695ec13ef10693ce25c623962a3ab9628d9f1529fc";

    pub(crate) fn assert_hex(name: &str, actual: &[u8], expected: &str) {
        let hex: String = actual.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, expected, "{name}");
    }
}
