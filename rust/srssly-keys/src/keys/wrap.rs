use hpke::aead::AesGcm256;
use hpke::kdf::HkdfSha256;
use hpke::kem::X25519HkdfSha256;
use hpke::{Deserializable as _, OpModeR, OpModeS, Serializable as _};
use serde::{Deserialize, Serialize};

use crate::account::AccountId;
use crate::keys::RootSecret;
use crate::passkey::{CredentialIdHash, PasskeyKeyPair};
use crate::{Error, Result, b64};

type Kem = X25519HkdfSha256;
const INFO: &[u8] = b"srssly/v1/root-wrap";

/// The root secret sealed with HPKE (X25519, HKDF-SHA256, AES-256-GCM) to
/// one passkey's public key.
///
/// The associated data binds it to the account, the key epoch and the
/// passkey, so a wrapped secret can't be replayed into another slot.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WrappedSecret {
    /// The passkey's X25519 public key (see [`PasskeyKeyPair`]).
    #[serde(with = "b64")]
    pub public_key: [u8; 32],
    #[serde(with = "b64")]
    pub encapped_key: [u8; 32],
    /// AES-256-GCM ciphertext of the root secret, tag included.
    #[serde(with = "b64")]
    pub ciphertext: Vec<u8>,
}

fn aad(account: &AccountId, epoch: u32, credential: &CredentialIdHash) -> Vec<u8> {
    let mut aad = b"srssly/v1/root-wrap/".to_vec();
    aad.extend_from_slice(account.as_bytes());
    aad.extend_from_slice(&epoch.to_be_bytes());
    aad.extend_from_slice(credential.as_bytes());
    aad
}

impl WrappedSecret {
    /// Seals `root` to the passkey whose public key is `public_key`.
    pub fn seal(
        root: &RootSecret,
        public_key: &[u8; 32],
        account: &AccountId,
        epoch: u32,
        credential: &CredentialIdHash,
    ) -> Result<Self> {
        let pk = <Kem as hpke::Kem>::PublicKey::from_bytes(public_key)
            .map_err(|_| Error::Malformed("passkey public key"))?;
        let (encapped, ciphertext) = hpke::single_shot_seal::<AesGcm256, HkdfSha256, Kem>(
            &OpModeS::Base,
            &pk,
            INFO,
            root.as_bytes(),
            &aad(account, epoch, credential),
        )
        .map_err(|_| Error::Malformed("passkey public key"))?;
        Ok(Self {
            public_key: *public_key,
            encapped_key: encapped.to_bytes().into(),
            ciphertext,
        })
    }

    /// Opens the wrapped secret with the passkey's key pair.
    pub fn open(
        &self,
        key_pair: &PasskeyKeyPair,
        account: &AccountId,
        epoch: u32,
        credential: &CredentialIdHash,
    ) -> Result<RootSecret> {
        if key_pair.public_key() != &self.public_key {
            return Err(Error::WrongPasskey);
        }
        let encapped = <Kem as hpke::Kem>::EncappedKey::from_bytes(&self.encapped_key)
            .map_err(|_| Error::Malformed("encapsulated key"))?;
        let mut plain = hpke::single_shot_open::<AesGcm256, HkdfSha256, Kem>(
            &OpModeR::Base,
            &key_pair.private,
            &encapped,
            INFO,
            &self.ciphertext,
            &aad(account, epoch, credential),
        )
        .map_err(|_| Error::DecryptionFailed)?;
        let bytes: Option<[u8; 32]> = plain.as_slice().try_into().ok();
        zeroize::Zeroize::zeroize(&mut plain);
        bytes
            .and_then(RootSecret::from_bytes)
            .ok_or(Error::Malformed("root secret"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::passkey::tests::test_prf;

    fn setup() -> (RootSecret, PasskeyKeyPair, AccountId, CredentialIdHash) {
        (
            RootSecret::generate(),
            PasskeyKeyPair::from_prf(&test_prf(5)),
            AccountId::generate(),
            CredentialIdHash::of(b"cred"),
        )
    }

    #[test]
    fn seal_then_open() {
        let (root, kp, account, cred) = setup();
        let w = WrappedSecret::seal(&root, kp.public_key(), &account, 0, &cred).unwrap();
        assert_eq!(w.open(&kp, &account, 0, &cred).unwrap(), root);
        assert!(!w.ciphertext.windows(32).any(|c| c == root.as_bytes()));
    }

    #[test]
    fn sealing_is_randomized() {
        let (root, kp, account, cred) = setup();
        let a = WrappedSecret::seal(&root, kp.public_key(), &account, 0, &cred).unwrap();
        let b = WrappedSecret::seal(&root, kp.public_key(), &account, 0, &cred).unwrap();
        assert_ne!(a.ciphertext, b.ciphertext);
    }

    #[test]
    fn wrong_passkey_is_rejected() {
        let (root, kp, account, cred) = setup();
        let w = WrappedSecret::seal(&root, kp.public_key(), &account, 0, &cred).unwrap();
        let other = PasskeyKeyPair::from_prf(&test_prf(6));
        assert_eq!(w.open(&other, &account, 0, &cred), Err(Error::WrongPasskey));
    }

    #[test]
    fn context_is_bound() {
        let (root, kp, account, cred) = setup();
        let w = WrappedSecret::seal(&root, kp.public_key(), &account, 0, &cred).unwrap();
        let other_cred = CredentialIdHash::of(b"other");
        assert_eq!(
            w.open(&kp, &account, 1, &cred),
            Err(Error::DecryptionFailed)
        );
        assert_eq!(
            w.open(&kp, &AccountId::generate(), 0, &cred),
            Err(Error::DecryptionFailed)
        );
        assert_eq!(
            w.open(&kp, &account, 0, &other_cred),
            Err(Error::DecryptionFailed)
        );
    }

    #[test]
    fn tampering_is_detected() {
        let (root, kp, account, cred) = setup();
        let mut w = WrappedSecret::seal(&root, kp.public_key(), &account, 0, &cred).unwrap();
        w.ciphertext[0] ^= 1;
        assert_eq!(
            w.open(&kp, &account, 0, &cred),
            Err(Error::DecryptionFailed)
        );
    }
}
