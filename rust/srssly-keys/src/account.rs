use std::fmt;

use serde::{Deserialize, Serialize};

use crate::keys::{KeyCheck, RootSecret};
use crate::passkey::CredentialIdHash;
use crate::wrap::WrappedSecret;
use crate::{Error, FORMAT_VERSION, Result, b64, random_bytes};

/// A random 16-byte account identifier. It stays the same when keys rotate.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AccountId(#[serde(with = "b64")] [u8; 16]);

impl AccountId {
    pub fn generate() -> Self {
        Self(random_bytes())
    }

    pub fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }
}

impl fmt::Display for AccountId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&b64::encode(&self.0))
    }
}

impl fmt::Debug for AccountId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "AccountId({self})")
    }
}

/// One registered passkey and the root secret sealed to it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PasskeyInfo {
    pub credential_id_hash: CredentialIdHash,
    /// A name the user recognises, such as "iPhone (iCloud Keychain)" or "YubiKey 5C".
    pub label: String,
    #[serde(flatten)]
    pub wrapped: WrappedSecret,
}

/// The key record the relay stores for an account. Everything in it is safe
/// for the relay to see: public keys, a key check and sealed secrets.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountKeys {
    pub version: u32,
    pub account_id: AccountId,
    /// Starts at 0 and goes up by one on each key rotation.
    pub epoch: u32,
    /// Identifies the current root secret.
    pub key_check: KeyCheck,
    /// The current Ed25519 relay-authentication public key.
    #[serde(with = "b64")]
    pub auth_public_key: [u8; 32],
    pub passkeys: Vec<PasskeyInfo>,
}

impl AccountKeys {
    /// Checks that `root` is this account's current root secret.
    pub fn verify_root(&self, root: &RootSecret) -> Result<()> {
        if root.key_check(&self.account_id) == self.key_check {
            Ok(())
        } else {
            Err(Error::WrongRootSecret)
        }
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("AccountKeys always serializes")
    }

    /// Parses a stored record, refusing versions this code doesn't know.
    pub fn from_json(json: &str) -> Result<Self> {
        #[derive(Deserialize)]
        struct Version {
            version: u32,
        }
        let v: Version =
            serde_json::from_str(json).map_err(|_| Error::Malformed("account keys"))?;
        if v.version != FORMAT_VERSION {
            return Err(Error::UnsupportedVersion(v.version));
        }
        serde_json::from_str(json).map_err(|_| Error::Malformed("account keys"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::passkey::{PasskeyKeyPair, PrfOutput};

    fn record(root: &RootSecret) -> AccountKeys {
        let account_id = AccountId::generate();
        let credential_id_hash = CredentialIdHash::of(b"cred");
        let key_pair = PasskeyKeyPair::from_prf(&PrfOutput::from_bytes([3; 32]));
        let wrapped = WrappedSecret::seal(
            root,
            key_pair.public_key(),
            &account_id,
            0,
            &credential_id_hash,
        )
        .unwrap();
        AccountKeys {
            version: FORMAT_VERSION,
            account_id,
            epoch: 0,
            key_check: root.key_check(&account_id),
            auth_public_key: root.derive(&account_id).auth_public_key(),
            passkeys: vec![PasskeyInfo {
                credential_id_hash,
                label: "laptop".into(),
                wrapped,
            }],
        }
    }

    #[test]
    fn verify_root() {
        let root = RootSecret::generate();
        let keys = record(&root);
        keys.verify_root(&root).unwrap();
        assert_eq!(
            keys.verify_root(&RootSecret::generate()),
            Err(Error::WrongRootSecret)
        );
    }

    #[test]
    fn json_round_trip_and_version_check() {
        let keys = record(&RootSecret::generate());
        assert_eq!(AccountKeys::from_json(&keys.to_json()).unwrap(), keys);
        let future = keys.to_json().replace("\"version\": 1", "\"version\": 2");
        assert_eq!(
            AccountKeys::from_json(&future),
            Err(Error::UnsupportedVersion(2))
        );
        assert_eq!(
            AccountKeys::from_json("{}"),
            Err(Error::Malformed("account keys"))
        );
    }

    #[test]
    fn json_holds_no_secrets() {
        let root = RootSecret::generate();
        assert!(
            !record(&root)
                .to_json()
                .contains(&b64::encode(root.as_bytes()))
        );
    }

    #[test]
    fn account_id_displays_as_base64url() {
        let id = AccountId::from_bytes([0; 16]);
        assert_eq!(id.to_string(), "AAAAAAAAAAAAAAAAAAAAAA");
        assert_eq!(format!("{id:?}"), "AccountId(AAAAAAAAAAAAAAAAAAAAAA)");
    }
}
