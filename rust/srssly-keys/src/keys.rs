use std::fmt;

use ed25519_dalek::{Signer as _, SigningKey, VerifyingKey};
use hkdf::Hkdf;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::account::AccountId;
use crate::transcript::Transcript;
use crate::{b64, random_bytes};

// Children of this module can read the root secret's bytes; nothing else can.
pub(crate) mod recovery;
pub(crate) mod wrap;

/// The account's root secret: 32 random bytes from which every other key derives.
///
/// There is deliberately no public way to read the bytes back out, so they
/// can't be logged or sent anywhere by accident. Equality is for tests only:
/// it isn't constant-time, and code should compare [`KeyCheck`]s instead.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
#[cfg_attr(test, derive(PartialEq, Eq))]
pub struct RootSecret([u8; 32]);

impl RootSecret {
    /// A new random root secret.
    pub fn generate() -> Self {
        Self::from_bytes(&mut random_bytes()).expect("system random number generator is broken")
    }

    /// `None` if the bytes are obviously not random (see [`looks_random`]).
    /// Takes the bytes by reference and wipes them, so the caller's copy
    /// doesn't linger on the stack.
    pub fn from_bytes(bytes: &mut [u8; 32]) -> Option<Self> {
        let secret = looks_random(bytes).then_some(Self(*bytes));
        bytes.zeroize();
        secret
    }

    /// Private: only this module and its children (which seal the secret) can
    /// read the bytes.
    fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    /// The raw secret, for keeping it in the platform keychain (or the CLI's
    /// test device file). Only built with the `export-root-secret` feature, so
    /// code has to opt in before it can read the bytes.
    #[cfg(feature = "export-root-secret")]
    pub fn export(&self) -> zeroize::Zeroizing<[u8; 32]> {
        zeroize::Zeroizing::new(self.0)
    }

    /// `HKDF-SHA256(salt = "srssly/v1/root/" || account, ikm = root)`.
    /// Wiped on drop, since most outputs are keys.
    pub(crate) fn expand<const N: usize>(
        &self,
        account: &AccountId,
        info: &[u8],
    ) -> Zeroizing<[u8; N]> {
        let mut salt = b"srssly/v1/root/".to_vec();
        salt.extend_from_slice(account.as_bytes());
        let mut out = Zeroizing::new([0u8; N]);
        Hkdf::<Sha256>::new(Some(&salt), &self.0)
            .expand(info, out.as_mut())
            .expect("HKDF output length is valid");
        out
    }

    /// The public check value for this secret, which the relay stores so a
    /// client can tell whether a secret (say, from a recovery key) is current.
    pub fn key_check(&self, account: &AccountId) -> KeyCheck {
        KeyCheck(*self.expand(account, b"key-check"))
    }

    /// The keys derived from this secret for `account`.
    pub fn derive(&self, account: &AccountId) -> DerivedKeys {
        let auth_seed = self.expand(account, b"auth-key");
        let mut data_key = DataKey([0; 32]);
        data_key
            .0
            .copy_from_slice(self.expand::<32>(account, b"data-key").as_ref());
        DerivedKeys {
            data_key,
            auth_key: AuthKey(SigningKey::from_bytes(&auth_seed)),
        }
    }
}

/// Whether 32 bytes have at least 8 distinct values. Entropy can't be measured
/// from one sample, but this rejects zeros, repeated bytes and short patterns
/// (a broken RNG, a test value, the all-"abandon" recovery phrase), while 32
/// random bytes fail it with probability about 10^-37.
pub(crate) fn looks_random(bytes: &[u8; 32]) -> bool {
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

/// Keys derived from the root secret.
pub struct DerivedKeys {
    pub data_key: DataKey,
    /// Ed25519 key that authenticates this account to the relay.
    pub auth_key: AuthKey,
}

impl DerivedKeys {
    /// The relay identifies the account's current key by this public key.
    pub fn auth_public_key(&self) -> AuthPublicKey {
        self.auth_key.public_key()
    }
}

/// The Ed25519 private key that authenticates an account to the relay. Like
/// [`RootSecret`] its bytes can't be read, and it is wiped when dropped.
///
/// It also signs the key record and epoch links, so outside the crate it
/// signs only relay requests, under their own label: no request the relay
/// picks can come back as a record or link signature.
pub struct AuthKey(SigningKey);

impl AuthKey {
    pub fn public_key(&self) -> AuthPublicKey {
        AuthPublicKey(self.0.verifying_key())
    }

    /// A signature of `request` (a login challenge, a request body) for the
    /// relay: Ed25519 over `"srssly/v2/relay-auth"` then `request`, each
    /// length-prefixed. Verify it with [`AuthPublicKey::verify_relay_request`].
    ///
    /// The label only stops a relay request from being reused as a record or
    /// link signature. It doesn't stop replay: `request` should carry the
    /// relay's fresh nonce and say what it authorises.
    pub fn sign_relay_request(&self, request: &[u8]) -> [u8; 64] {
        self.sign(&relay_request_bytes(request))
    }

    /// An Ed25519 signature of a labelled transcript. Crate-private, and it
    /// takes a [`Transcript`] so nothing unlabelled is ever signed.
    pub(crate) fn sign(&self, message: &Transcript) -> [u8; 64] {
        self.0.sign(message.bytes()).to_bytes()
    }
}

fn relay_request_bytes(request: &[u8]) -> Transcript {
    let mut t = Transcript::new(b"srssly/v2/relay-auth");
    t.field(request);
    t
}

impl fmt::Debug for AuthKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AuthKey({:?})", self.public_key())
    }
}

/// The Ed25519 public key that authenticates an account to the relay. Always
/// a valid curve point: parsing rejects bytes that aren't one.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct AuthPublicKey(VerifyingKey);

impl AuthPublicKey {
    pub fn to_bytes(&self) -> [u8; 32] {
        self.0.to_bytes()
    }

    /// Whether `signature` is this key's [`AuthKey::sign_relay_request`]
    /// signature of `request`.
    pub fn verify_relay_request(&self, request: &[u8], signature: &[u8; 64]) -> bool {
        self.verify(&relay_request_bytes(request), signature)
    }

    /// Whether `signature` is this key's Ed25519 signature of `message`
    /// (strict verification: no malleable or small-order signatures).
    pub(crate) fn verify(&self, message: &Transcript, signature: &[u8; 64]) -> bool {
        let signature = ed25519_dalek::Signature::from_bytes(signature);
        self.0.verify_strict(message.bytes(), &signature).is_ok()
    }
}

impl fmt::Debug for AuthPublicKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AuthPublicKey({})", b64::encode(&self.to_bytes()))
    }
}

impl Serialize for AuthPublicKey {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        b64::serialize(self.to_bytes(), s)
    }
}

impl<'de> Deserialize<'de> for AuthPublicKey {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let bytes: [u8; 32] = b64::deserialize(d)?;
        VerifyingKey::from_bytes(&bytes)
            .map(Self)
            .map_err(|_| serde::de::Error::custom("not an Ed25519 public key"))
    }
}

/// The AES-256-GCM key for sync records. Like [`RootSecret`], its bytes can't
/// be read outside this module, and it is wiped when dropped.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct DataKey([u8; 32]);

impl fmt::Debug for DataKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("DataKey(..)")
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

    pub(crate) fn account() -> AccountId {
        AccountId::from_bytes([7; 16])
    }

    /// A valid test secret: the bytes `first, first + 1, ..., first + 31`.
    pub(crate) fn test_root(first: u8) -> RootSecret {
        RootSecret::from_bytes(&mut std::array::from_fn(|i| first.wrapping_add(i as u8))).unwrap()
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
    fn derived_keys_are_deterministic_and_independent() {
        let root = test_root(1);
        let a = root.derive(&account());
        let b = root.derive(&account());
        assert_eq!(a.data_key.0, b.data_key.0);
        assert_eq!(a.auth_public_key(), b.auth_public_key());
        assert_ne!(a.data_key.0, a.auth_key.0.to_bytes());
        assert_ne!(&a.data_key.0[..16], root.key_check(&account()).as_bytes());
        let other = AccountId::from_bytes([8; 16]);
        assert_ne!(a.data_key.0, root.derive(&other).data_key.0);
    }

    #[test]
    fn generated_secrets_differ() {
        assert_ne!(RootSecret::generate(), RootSecret::generate());
        assert_ne!(AccountId::generate(), AccountId::generate());
    }

    #[test]
    fn from_bytes_wipes_its_input() {
        let mut bytes = std::array::from_fn(|i| i as u8);
        assert!(RootSecret::from_bytes(&mut bytes).is_some());
        assert_eq!(bytes, [0; 32]);
        let mut weak = [1; 32];
        assert!(RootSecret::from_bytes(&mut weak).is_none());
        assert_eq!(weak, [0; 32]);
    }

    #[test]
    fn rejects_obviously_non_random_bytes() {
        assert!(RootSecret::from_bytes(&mut [0; 32]).is_none());
        assert!(RootSecret::from_bytes(&mut [0xff; 32]).is_none());
        let pattern = |n: u8| std::array::from_fn(|i| i as u8 % n);
        assert!(RootSecret::from_bytes(&mut pattern(7)).is_none());
        assert!(RootSecret::from_bytes(&mut pattern(8)).is_some());
        // Values in different 64-bit words of the bitmap all count.
        assert!(RootSecret::from_bytes(&mut std::array::from_fn(|i| (i as u8 % 8) * 32)).is_some());
    }

    #[test]
    fn auth_public_key_round_trips_and_rejects_non_points() {
        let key = test_root(0).derive(&account()).auth_public_key();
        let json = serde_json::to_string(&key).unwrap();
        assert_eq!(serde_json::from_str::<AuthPublicKey>(&json).unwrap(), key);
        let not_a_point = (0u8..=255)
            .map(|i| [i; 32])
            .find(|b| VerifyingKey::from_bytes(b).is_err())
            .unwrap();
        let json = format!("\"{}\"", b64::encode(&not_a_point));
        assert!(serde_json::from_str::<AuthPublicKey>(&json).is_err());
    }

    #[test]
    fn debug_hides_secret() {
        let root = test_root(0xAB);
        assert_eq!(format!("{root:?}"), "RootSecret(..)");
        let keys = root.derive(&account());
        assert_eq!(format!("{:?}", keys.data_key), "DataKey(..)");
        let debug = format!("{:?}", keys.auth_key);
        assert!(debug.starts_with("AuthKey(AuthPublicKey("), "{debug}");
    }

    #[test]
    fn auth_key_signs_for_its_public_key() {
        let keys = test_root(0).derive(&account());
        let sig = keys.auth_key.sign(&Transcript::new(b"hi"));
        let sig = ed25519_dalek::Signature::from_bytes(&sig);
        let public = VerifyingKey::from_bytes(&keys.auth_public_key().to_bytes()).unwrap();
        public
            .verify_strict(Transcript::new(b"hi").bytes(), &sig)
            .unwrap();
        assert!(public.verify_strict(b"hi", &sig).is_err());
    }

    #[test]
    fn relay_request_signatures_are_labelled() {
        let keys = test_root(0).derive(&account());
        let public = keys.auth_public_key();
        let sig = keys.auth_key.sign_relay_request(b"challenge");
        assert!(public.verify_relay_request(b"challenge", &sig));
        assert!(!public.verify_relay_request(b"challenge!", &sig));
        // Not a raw signature of the request: the label is part of it.
        assert!(!public.verify(&Transcript::new(b"challenge"), &sig));
        assert_hex(
            "relay_auth_signature",
            &sig,
            "977c95df68278a8845fdf715ac6c49527119dabb99c6b9b19a78925b33b923cddfecb653fe6a2d37963acb912d9ab687694457ebbfad3c71b8187919c9ef8000",
        );
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
        let keys = root.derive(&account());
        assert_hex(
            "data_key",
            &keys.data_key.0,
            "cd83ad81a9fdd0261d66adc35de901016197cef3917079477a6153a7e1fd1678",
        );
        assert_hex(
            "auth_public",
            &keys.auth_public_key().to_bytes(),
            "b73c2d802b74e5438e51c49cbab6873ba403e6a67ceea29abe902a4a72bd3172",
        );
    }

    pub(crate) fn assert_hex(name: &str, actual: &[u8], expected: &str) {
        let hex: String = actual.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, expected, "{name}");
    }
}
