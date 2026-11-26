use std::fmt;

use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::account::AccountId;
use crate::random_bytes;

/// The account's root secret: 32 random bytes from which every other key derives.
///
/// There is deliberately no public way to read the bytes back out, so they
/// can't be logged or sent anywhere by accident.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct RootSecret([u8; 32]);

impl RootSecret {
    /// A new random root secret.
    pub fn generate() -> Self {
        Self::from_bytes(random_bytes()).expect("system random number generator is broken")
    }

    /// `None` if the bytes are obviously not random (see [`looks_random`]).
    pub fn from_bytes(bytes: [u8; 32]) -> Option<Self> {
        looks_random(&bytes).then_some(Self(bytes))
    }

    /// `HKDF-SHA256(salt = "srssly/v1/root/" || account, ikm = root)`.
    pub(crate) fn expand<const N: usize>(&self, account: &AccountId, info: &[u8]) -> [u8; N] {
        let mut salt = b"srssly/v1/root/".to_vec();
        salt.extend_from_slice(account.as_bytes());
        let mut out = [0u8; N];
        Hkdf::<Sha256>::new(Some(&salt), &self.0)
            .expand(info, &mut out)
            .expect("HKDF output length is valid");
        out
    }

    /// The public check value for this secret, which the relay stores so a
    /// client can tell whether a secret (say, from a recovery key) is current.
    pub fn key_check(&self, account: &AccountId) -> KeyCheck {
        KeyCheck(self.expand(account, b"key-check"))
    }
}

/// Whether 32 bytes have at least 8 distinct values. Entropy can't be measured
/// from one sample, but this rejects zeros, repeated bytes and short patterns
/// (a broken RNG, a test value, the all-"abandon" recovery phrase), while 32
/// random bytes fail it with probability about 10^-37.
fn looks_random(bytes: &[u8; 32]) -> bool {
    // A bitmap of seen values in one cache line, rather than a 256-entry table.
    let mut seen = [0u64; 4];
    for &b in bytes {
        seen[usize::from(b >> 6)] |= 1 << (b & 63);
    }
    let distinct: u32 = seen.iter().map(|w| w.count_ones()).sum();
    seen.zeroize();
    distinct >= 8
}

impl fmt::Debug for RootSecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RootSecret(..)")
    }
}

/// A 16-byte public value that identifies a root secret without revealing it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyCheck([u8; 16]);

impl KeyCheck {
    pub fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn account() -> AccountId {
        AccountId::from_bytes([7; 16])
    }

    /// A valid test secret: the bytes `first, first + 1, ..., first + 31`.
    pub(crate) fn test_root(first: u8) -> RootSecret {
        RootSecret::from_bytes(std::array::from_fn(|i| first.wrapping_add(i as u8))).unwrap()
    }

    #[test]
    fn key_check_is_deterministic() {
        let root = test_root(1);
        assert_eq!(root.key_check(&account()), root.key_check(&account()));
    }

    #[test]
    fn key_check_depends_on_account_and_secret() {
        let root = test_root(1);
        let other_account = AccountId::from_bytes([8; 16]);
        assert_ne!(root.key_check(&account()), root.key_check(&other_account));
        let other_root = test_root(2);
        assert_ne!(root.key_check(&account()), other_root.key_check(&account()));
    }

    #[test]
    fn generated_secrets_differ() {
        assert_ne!(RootSecret::generate(), RootSecret::generate());
        assert_ne!(AccountId::generate(), AccountId::generate());
    }

    #[test]
    fn rejects_obviously_non_random_bytes() {
        assert!(RootSecret::from_bytes([0; 32]).is_none());
        assert!(RootSecret::from_bytes([0xff; 32]).is_none());
        let pattern = |n: u8| std::array::from_fn(|i| i as u8 % n);
        assert!(RootSecret::from_bytes(pattern(7)).is_none());
        assert!(RootSecret::from_bytes(pattern(8)).is_some());
        // Values in different 64-bit words of the bitmap all count.
        assert!(RootSecret::from_bytes(std::array::from_fn(|i| (i as u8 % 8) * 32)).is_some());
    }

    #[test]
    fn debug_hides_secret() {
        let root = test_root(0xAB);
        assert_eq!(format!("{root:?}"), "RootSecret(..)");
    }

    /// Pins the derivation so other implementations (Swift, Kotlin, web) can
    /// check they match byte for byte. The expected values come from the
    /// independent Python implementation in `scripts/known_answers.py`.
    #[test]
    fn known_answer() {
        let root = test_root(0);
        assert_hex(
            "key_check",
            root.key_check(&account()).as_bytes(),
            "7d745637d079f47074bfa7e55b88b32e",
        );
    }

    pub(crate) fn assert_hex(name: &str, actual: &[u8], expected: &str) {
        let hex: String = actual.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, expected, "{name}");
    }
}
