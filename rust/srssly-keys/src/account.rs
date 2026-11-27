use std::fmt;

use serde::{Deserialize, Serialize};

use crate::keys::{AuthPublicKey, KeyCheck, RecordPublicKey, RootSecret};
use hmac::Mac as _;

use crate::passkey::{
    CredentialIdHash, PRF_INPUT, PasskeyKeyPair, PrfAuthenticator, PrfOutput, binding_mac,
};
use crate::recovery::RecoveryKey;
use crate::transcript::Transcript;
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

/// A passkey's MAC over one epoch's public values (see [`EpochLink`]), made
/// with a key derived from its PRF output. Only that passkey can make or
/// check it, so unlocking with it trusts the record from that epoch on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    pub epoch: u32,
    #[serde(with = "b64")]
    pub mac: [u8; 32],
}

/// One registered passkey and the root secret sealed to it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PasskeyInfo {
    pub credential_id_hash: CredentialIdHash,
    /// A name the user recognises, such as "iPhone (iCloud Keychain)" or "YubiKey 5C".
    pub label: String,
    pub wrapped: WrappedSecret,
    pub binding: Binding,
}

/// One epoch's public values. Every link after the first is signed by the
/// previous epoch's record key, so a device that trusts one epoch can follow
/// the rotations after it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EpochLink {
    pub epoch: u32,
    pub key_check: KeyCheck,
    pub auth_public_key: AuthPublicKey,
    pub record_public_key: RecordPublicKey,
    /// Ed25519 by the previous epoch's record key; empty for the first link.
    #[serde(with = "b64")]
    pub signature: Vec<u8>,
}

impl EpochLink {
    fn signed_bytes(&self, account: &AccountId) -> Transcript {
        let mut t = Transcript::new(b"srssly/v3/link");
        t.field(account.as_bytes())
            .field(&self.epoch.to_be_bytes())
            .field(self.key_check.as_bytes())
            .field(&self.auth_public_key.to_bytes())
            .field(&self.record_public_key.to_bytes());
        t
    }
}

/// What a device remembers about the last record it verified: public values
/// only, so it can be stored beside the root secret without extra care.
/// [`AccountKeys::verify_successor`] uses it to refuse a fork or a rollback.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KnownEpoch {
    pub account_id: AccountId,
    pub epoch: u32,
    pub key_check: KeyCheck,
    pub auth_public_key: AuthPublicKey,
    pub record_public_key: RecordPublicKey,
    pub revision: u64,
}

/// What a passkey's binding covers: `link`'s values, the passkey's credential
/// hash and its public key.
fn binding_bytes(account: &AccountId, link: &EpochLink, p: &PasskeyInfo) -> Transcript {
    let mut t = Transcript::new(b"srssly/v3/binding");
    t.field(account.as_bytes())
        .field(&link.epoch.to_be_bytes())
        .field(link.key_check.as_bytes())
        .field(&link.auth_public_key.to_bytes())
        .field(&link.record_public_key.to_bytes())
        .field(p.credential_id_hash.as_bytes())
        .field(&p.wrapped.public_key);
    t
}

/// Limits on a key record, so one from the relay can't make a sign-in slow or
/// memory-hungry. Records this crate makes always stay within them.
pub const MAX_RECORD_BYTES: usize = 1 << 20;
pub const MAX_PASSKEYS: usize = 32;
pub const MAX_LABEL_BYTES: usize = 128;
/// One link per rotation, so this is a lifetime cap: once an account has
/// this many epochs, rotation is refused for good. Pruning the chain (a link
/// signed by the current root that restarts it) is future work.
pub const MAX_EPOCHS: usize = 1024;

/// The key record the relay stores for an account. Everything in it is safe
/// for the relay to see: public keys, a key check and sealed secrets.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccountKeys {
    pub version: u32,
    pub account_id: AccountId,
    /// Starts at 0 and goes up by one on each key rotation.
    pub epoch: u32,
    /// Goes up by one on every change to the record, so a device can refuse
    /// a record older than one it has already seen.
    pub revision: u64,
    /// Identifies the current root secret.
    pub key_check: KeyCheck,
    /// The current Ed25519 relay-authentication public key.
    pub auth_public_key: AuthPublicKey,
    /// The current Ed25519 key that signs this record and the next epoch
    /// link. Separate from the auth key, so nothing the relay gets signed
    /// at login can ever pass as a record or link signature.
    pub record_public_key: RecordPublicKey,
    /// Every epoch from the first; the last is the current one.
    pub epochs: Vec<EpochLink>,
    pub passkeys: Vec<PasskeyInfo>,
    /// Ed25519 signature of everything above by the current record key, so only
    /// holders of the root secret can change the record.
    #[serde(with = "b64")]
    pub signature: [u8; 64],
}

impl AccountKeys {
    /// Creates an account with a new root secret, registered to one passkey.
    pub fn create(authenticator: &dyn PrfAuthenticator, label: &str) -> Result<(Self, RootSecret)> {
        let prf = authenticator.evaluate_prf(PRF_INPUT)?;
        Self::create_with_prf(authenticator.credential_id(), &prf, label)
    }

    /// [`create`](Self::create), given the PRF output directly (for example
    /// from a browser or a platform passkey API).
    pub fn create_with_prf(
        credential_id: &[u8],
        prf: &PrfOutput,
        label: &str,
    ) -> Result<(Self, RootSecret)> {
        let root = RootSecret::generate();
        let account_id = AccountId::generate();
        let mut keys = Self::empty(account_id, 0, &root);
        keys.sign(&root);
        keys.add_passkey_with_prf(&root, credential_id, prf, label)?;
        Ok((keys, root))
    }

    fn empty(account_id: AccountId, epoch: u32, root: &RootSecret) -> Self {
        let derived = root.derive(&account_id);
        let link = EpochLink {
            epoch,
            key_check: root.key_check(&account_id),
            auth_public_key: derived.auth_public_key(),
            record_public_key: derived.record_public_key(),
            signature: Vec::new(),
        };
        Self {
            version: FORMAT_VERSION,
            account_id,
            epoch,
            revision: 0,
            key_check: link.key_check,
            auth_public_key: link.auth_public_key,
            record_public_key: link.record_public_key,
            epochs: vec![link],
            passkeys: Vec::new(),
            signature: [0; 64],
        }
    }

    /// The bytes the record signature covers: every field but the signature.
    fn signed_bytes(&self) -> Transcript {
        let mut t = Transcript::new(b"srssly/v3/record");
        t.field(&self.version.to_be_bytes())
            .field(self.account_id.as_bytes())
            .field(&self.epoch.to_be_bytes())
            .field(&self.revision.to_be_bytes())
            .field(self.key_check.as_bytes())
            .field(&self.auth_public_key.to_bytes())
            .field(&self.record_public_key.to_bytes())
            .field(&(self.epochs.len() as u32).to_be_bytes());
        for link in &self.epochs {
            t.field(&link.epoch.to_be_bytes())
                .field(link.key_check.as_bytes())
                .field(&link.auth_public_key.to_bytes())
                .field(&link.record_public_key.to_bytes())
                .field(&link.signature);
        }
        t.field(&(self.passkeys.len() as u32).to_be_bytes());
        for p in &self.passkeys {
            t.field(p.credential_id_hash.as_bytes())
                .field(p.label.as_bytes())
                .field(&p.wrapped.public_key)
                .field(&p.wrapped.encapped_key)
                .field(&p.wrapped.ciphertext)
                .field(&p.binding.epoch.to_be_bytes())
                .field(&p.binding.mac);
        }
        t
    }

    fn sign(&mut self, root: &RootSecret) {
        let record_key = root.derive(&self.account_id).record_key;
        self.signature = record_key.sign(&self.signed_bytes());
    }

    /// Checks that `root` is current and that the record is signed by the
    /// record key derived from it. The keys come from the root, not from the
    /// record, so a relay can't substitute its own.
    fn verify_signed(&self, root: &RootSecret) -> Result<()> {
        self.check_key_check(root)?;
        let derived = root.derive(&self.account_id);
        if derived.auth_public_key() != self.auth_public_key {
            return Err(Error::Tampered);
        }
        self.verify_signature_by(&derived.record_public_key())
    }

    fn verify_signature_by(&self, public: &RecordPublicKey) -> Result<()> {
        if *public == self.record_public_key && public.verify(&self.signed_bytes(), &self.signature)
        {
            Ok(())
        } else {
            Err(Error::Tampered)
        }
    }

    fn known_epoch(&self) -> KnownEpoch {
        KnownEpoch {
            account_id: self.account_id,
            epoch: self.epoch,
            key_check: self.key_check,
            auth_public_key: self.auth_public_key,
            record_public_key: self.record_public_key,
            revision: self.revision,
        }
    }

    /// Checks that this record descends from one the device already trusts:
    /// same account, a revision no lower than `known`'s, and an intact chain
    /// that passes through `known`'s epoch with `known`'s keys, then signs the
    /// record. Needs no root, so a device whose root no longer matches (after
    /// another device rotated) can tell a real rotation from a fork made with
    /// a root older than `known`'s epoch. Call it before unlocking with a
    /// passkey again. Returns this record's [`KnownEpoch`] (see
    /// [`verify`](Self::verify) for when to store it).
    pub fn verify_successor(&self, known: &KnownEpoch) -> Result<KnownEpoch> {
        if self.account_id != known.account_id {
            return Err(Error::Tampered);
        }
        if self.revision < known.revision {
            return Err(Error::Stale);
        }
        self.verify_chain()?;
        let link = self.epochs.iter().find(|l| l.epoch == known.epoch);
        match link {
            Some(l)
                if (l.key_check, l.auth_public_key, l.record_public_key)
                    == (
                        known.key_check,
                        known.auth_public_key,
                        known.record_public_key,
                    ) => {}
            _ => return Err(Error::Tampered),
        }
        self.verify_signature_by(&self.record_public_key)?;
        Ok(self.known_epoch())
    }

    /// Checks the whole record with the current root secret: that `root` is
    /// current, that the epoch chain is intact and that the record is signed
    /// by the record key derived from `root`. Until this passes, nothing in a
    /// fetched record (passkeys, labels, epochs, revision) is authenticated,
    /// so call it before showing or acting on one.
    ///
    /// Returns the record's [`KnownEpoch`] for
    /// [`verify_successor`](Self::verify_successor). Store it only for a
    /// record the relay holds (one just fetched, or an upload it accepted):
    /// a local change the relay never got has a higher revision than the
    /// relay's record, which would then be refused as stale.
    pub fn verify(&self, root: &RootSecret) -> Result<KnownEpoch> {
        self.verify_chain()?;
        self.verify_signed(root)?;
        Ok(self.known_epoch())
    }

    /// Checks only that `root`'s key check matches the record's, which the
    /// relay controls. Not record verification: use [`verify`](Self::verify).
    fn check_key_check(&self, root: &RootSecret) -> Result<()> {
        if root.key_check(&self.account_id) == self.key_check {
            Ok(())
        } else {
            Err(Error::WrongRootSecret)
        }
    }

    /// Registers another passkey. Needs the unlocked root secret.
    pub fn add_passkey(
        &mut self,
        root: &RootSecret,
        authenticator: &dyn PrfAuthenticator,
        label: &str,
    ) -> Result<()> {
        let prf = authenticator.evaluate_prf(PRF_INPUT)?;
        self.add_passkey_with_prf(root, authenticator.credential_id(), &prf, label)
    }

    pub fn add_passkey_with_prf(
        &mut self,
        root: &RootSecret,
        credential_id: &[u8],
        prf: &PrfOutput,
        label: &str,
    ) -> Result<()> {
        self.verify_signed(root)?;
        let credential_id_hash = CredentialIdHash::of(credential_id);
        if self.find(&credential_id_hash).is_some() {
            return Err(Error::DuplicatePasskey);
        }
        if label.len() > MAX_LABEL_BYTES {
            return Err(Error::LimitReached("label too long"));
        }
        if self.passkeys.len() >= MAX_PASSKEYS {
            return Err(Error::LimitReached("too many passkeys"));
        }
        let key_pair = PasskeyKeyPair::from_prf(prf);
        let wrapped = WrappedSecret::seal(
            root,
            key_pair.public_key(),
            &self.account_id,
            self.epoch,
            &credential_id_hash,
        )?;
        self.revision = self.next_revision()?;
        let mut info = PasskeyInfo {
            credential_id_hash,
            label: label.to_owned(),
            wrapped,
            binding: Binding {
                epoch: self.epoch,
                mac: [0; 32],
            },
        };
        info.binding = self.current_binding(&info, prf);
        self.passkeys.push(info);
        self.sign(root);
        Ok(())
    }

    /// A binding for `info` at the current epoch.
    fn current_binding(&self, info: &PasskeyInfo, prf: &PrfOutput) -> Binding {
        let link = self.epochs.last().expect("a record has at least one epoch");
        let message = binding_bytes(&self.account_id, link, info);
        let mac = binding_mac(prf).chain_update(message.bytes()).finalize();
        Binding {
            epoch: self.epoch,
            mac: mac.into_bytes().into(),
        }
    }

    /// Unlocks with a passkey, then rebinds it to the current epoch if its
    /// binding is from before a rotation. Returns the root and whether the
    /// record changed; if it did, store the new record on the relay, and once
    /// the relay accepts it, [`verify`](Self::verify) it for a [`KnownEpoch`]. Use this
    /// rather than [`unlock`](Self::unlock) wherever the app can write back.
    /// Rebinding does not stop a fork: a relay that kept an older record can
    /// serve one rotated by a former root holder. A device that has seen the
    /// account before must call [`verify_successor`](Self::verify_successor)
    /// first.
    pub fn unlock_and_rebind(
        &mut self,
        authenticator: &dyn PrfAuthenticator,
    ) -> Result<(RootSecret, bool)> {
        let prf = authenticator.evaluate_prf(PRF_INPUT)?;
        self.unlock_and_rebind_with_prf(authenticator.credential_id(), &prf)
    }

    pub fn unlock_and_rebind_with_prf(
        &mut self,
        credential_id: &[u8],
        prf: &PrfOutput,
    ) -> Result<(RootSecret, bool)> {
        let root = self.unlock_with_prf(credential_id, prf)?;
        let hash = CredentialIdHash::of(credential_id);
        let index = self
            .passkeys
            .iter()
            .position(|p| p.credential_id_hash == hash);
        let index = index.expect("unlock found it");
        if self.passkeys[index].binding.epoch == self.epoch {
            return Ok((root, false));
        }
        self.revision = self.next_revision()?;
        self.passkeys[index].binding = self.current_binding(&self.passkeys[index], prf);
        self.sign(&root);
        Ok((root, true))
    }

    pub fn find(&self, credential_id_hash: &CredentialIdHash) -> Option<&PasskeyInfo> {
        self.passkeys
            .iter()
            .find(|p| &p.credential_id_hash == credential_id_hash)
    }
    /// Unlocks the root secret with a registered passkey. It returns no
    /// [`KnownEpoch`]: a device that keeps the root should call
    /// [`verify`](Self::verify) right after, to get one to store.
    pub fn unlock(&self, authenticator: &dyn PrfAuthenticator) -> Result<RootSecret> {
        let prf = authenticator.evaluate_prf(PRF_INPUT)?;
        self.unlock_with_prf(authenticator.credential_id(), &prf)
    }

    pub fn unlock_with_prf(&self, credential_id: &[u8], prf: &PrfOutput) -> Result<RootSecret> {
        let hash = CredentialIdHash::of(credential_id);
        let info = self.find(&hash).ok_or(Error::UnknownPasskey)?;
        let root = info.wrapped.open(
            &PasskeyKeyPair::from_prf(prf),
            &self.account_id,
            self.epoch,
            &hash,
        )?;
        // The relay can seal a root of its own to the passkey's public key,
        // so trust nothing until the passkey's own binding checks out: it
        // vouches for its epoch, the chain for every epoch after that, and
        // the current epoch for the root and the record signature.
        let link = self.epochs.iter().find(|l| l.epoch == info.binding.epoch);
        let link = link.ok_or(Error::Tampered)?;
        let message = binding_bytes(&self.account_id, link, info);
        binding_mac(prf)
            .chain_update(message.bytes())
            .verify_slice(&info.binding.mac)
            .map_err(|_| Error::Tampered)?;
        self.verify_chain()?;
        self.verify_signed(&root)?;
        Ok(root)
    }

    /// Unlocks the root secret from a recovery key, checking it is current.
    pub fn unlock_with_recovery_key(&self, key: &RecoveryKey) -> Result<RootSecret> {
        let root = key.root_secret();
        self.verify_signed(&root)?;
        Ok(root)
    }

    /// Removes a passkey from the record. That is not revocation: a device
    /// that already unlocked the root secret keeps it, and the removed passkey
    /// still opens any older copy of the record (a backup, or one the relay
    /// kept) until the next [`rotate`](Self::rotate). For a lost passkey use
    /// [`remove_and_rotate`](Self::remove_and_rotate) instead. Refuses to
    /// remove the last passkey.
    /// Needs the unlocked root secret, to re-sign the record.
    pub fn remove_passkey(
        &mut self,
        root: &RootSecret,
        credential_id_hash: &CredentialIdHash,
    ) -> Result<PasskeyInfo> {
        self.verify_signed(root)?;
        let index = self
            .passkeys
            .iter()
            .position(|p| &p.credential_id_hash == credential_id_hash)
            .ok_or(Error::UnknownPasskey)?;
        if self.passkeys.len() == 1 {
            return Err(Error::LastPasskey);
        }
        self.revision = self.next_revision()?;
        let removed = self.passkeys.remove(index);
        self.sign(root);
        Ok(removed)
    }

    /// Replaces the root secret with a new one, sealed to every registered
    /// passkey, and returns it. The old secret and any device holding only it
    /// no longer unlock the account. The caller must re-encrypt synced records
    /// under the new keys.
    ///
    /// The recovery key is the root secret, so rotation always invalidates it:
    /// show the user a new one ([`RecoveryKey::from_root`]) straight away.
    ///
    /// Rotation does not evict a passkey: the new root is sealed to the same
    /// passkey public keys, and anything that kept a passkey's PRF output
    /// (a compromised device that unlocked with it, or any device a synced
    /// passkey reached) opens the new one too. To recover from a compromised
    /// device: [`verify`](Self::verify) the record and check its passkey list
    /// for entries the user doesn't recognise (that device held the root and
    /// could have added its own), register a fresh credential, then call
    /// [`remove_and_rotate`](Self::remove_and_rotate) with every passkey the
    /// device used. Fresh credential first: with one synced passkey, removing
    /// it first would leave none.
    pub fn rotate(&mut self, current: &RootSecret) -> Result<RootSecret> {
        self.remove_and_rotate(current, &[])
    }

    /// Removes `remove` and rotates, in one signed change, so the removed
    /// passkeys never receive the new root. Refuses to remove every passkey.
    pub fn remove_and_rotate(
        &mut self,
        current: &RootSecret,
        remove: &[CredentialIdHash],
    ) -> Result<RootSecret> {
        // Only entries a root holder signed get the new secret.
        self.verify_signed(current)?;
        if remove.iter().any(|h| self.find(h).is_none()) {
            return Err(Error::UnknownPasskey);
        }
        let kept: Vec<_> = (self.passkeys.iter())
            .filter(|p| !remove.contains(&p.credential_id_hash))
            .collect();
        if kept.is_empty() {
            return Err(Error::LastPasskey);
        }
        if self.epochs.len() >= MAX_EPOCHS {
            return Err(Error::LimitReached("too many epochs"));
        }
        let root = RootSecret::generate();
        let epoch = self.epoch.checked_add(1).ok_or(Error::Malformed("epoch"))?;
        let mut next = Self::empty(self.account_id, epoch, &root);
        next.revision = self.next_revision()?;
        // The old record key vouches for the new epoch, extending the chain.
        let mut link = next.epochs.pop().expect("a new record has one link");
        let old_key = current.derive(&self.account_id).record_key;
        link.signature = old_key.sign(&link.signed_bytes(&self.account_id)).to_vec();
        next.epochs = self.epochs.clone();
        next.epochs.push(link);
        for p in kept {
            let wrapped = WrappedSecret::seal(
                &root,
                &p.wrapped.public_key,
                &self.account_id,
                epoch,
                &p.credential_id_hash,
            )?;
            next.passkeys.push(PasskeyInfo {
                wrapped,
                ..p.clone()
            });
        }
        next.sign(&root);
        *self = next;
        Ok(root)
    }

    /// The revision for the next change. The relay controls the stored value,
    /// so overflow is an error rather than a panic.
    fn next_revision(&self) -> Result<u64> {
        self.revision
            .checked_add(1)
            .ok_or(Error::Malformed("revision"))
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("AccountKeys always serializes")
    }

    /// Parses a stored record, refusing versions this code doesn't know.
    pub fn from_json(json: &str) -> Result<Self> {
        if json.len() > MAX_RECORD_BYTES {
            return Err(Error::Malformed("record too large"));
        }
        #[derive(Deserialize)]
        struct Version {
            version: u32,
        }
        let v: Version =
            serde_json::from_str(json).map_err(|_| Error::Malformed("account keys"))?;
        if v.version != FORMAT_VERSION {
            return Err(Error::UnsupportedVersion(v.version));
        }
        let keys: Self =
            serde_json::from_str(json).map_err(|_| Error::Malformed("account keys"))?;
        keys.validate()?;
        Ok(keys)
    }

    /// Checks what serde can't: the size limits, at least one passkey, no
    /// credential twice, and every wrapped secret the length a sealed root
    /// secret has. The limits go first, before the chain's signatures.
    fn validate(&self) -> Result<()> {
        if self.epochs.len() > MAX_EPOCHS {
            return Err(Error::Malformed("too many epochs"));
        }
        if self.passkeys.len() > MAX_PASSKEYS {
            return Err(Error::Malformed("too many passkeys"));
        }
        if self
            .passkeys
            .iter()
            .any(|p| p.label.len() > MAX_LABEL_BYTES)
        {
            return Err(Error::Malformed("label too long"));
        }
        self.verify_chain()?;
        if self.passkeys.is_empty() {
            return Err(Error::Malformed("no passkeys"));
        }
        for (i, p) in self.passkeys.iter().enumerate() {
            if self.passkeys[..i]
                .iter()
                .any(|q| q.credential_id_hash == p.credential_id_hash)
            {
                return Err(Error::DuplicatePasskey);
            }
            if p.wrapped.ciphertext.len() != WrappedSecret::CIPHERTEXT_LEN {
                return Err(Error::Malformed("wrapped secret"));
            }
        }
        Ok(())
    }

    /// Checks the epoch chain: consecutive epochs, each link signed by the
    /// one before, ending at the record's current epoch and keys.
    fn verify_chain(&self) -> Result<()> {
        let (first, rest) = self
            .epochs
            .split_first()
            .ok_or(Error::Malformed("epochs"))?;
        let last = self.epochs.last().expect("not empty");
        if !first.signature.is_empty()
            || (
                last.epoch,
                last.key_check,
                last.auth_public_key,
                last.record_public_key,
            ) != (
                self.epoch,
                self.key_check,
                self.auth_public_key,
                self.record_public_key,
            )
        {
            return Err(Error::Malformed("epochs"));
        }
        let mut previous = first;
        for link in rest {
            let signature: &[u8; 64] = (link.signature.as_slice().try_into())
                .map_err(|_| Error::Malformed("epoch signature"))?;
            let signed = link.signed_bytes(&self.account_id);
            if Some(link.epoch) != previous.epoch.checked_add(1)
                || !previous.record_public_key.verify(&signed, signature)
            {
                return Err(Error::Tampered);
            }
            previous = link;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::passkey::SoftPasskey;

    struct Failing;
    impl PrfAuthenticator for Failing {
        fn credential_id(&self) -> &[u8] {
            b"failing"
        }
        fn evaluate_prf(&self, _: &[u8]) -> Result<PrfOutput> {
            Err(Error::Authenticator("user cancelled".into()))
        }
    }

    #[test]
    fn create_registers_one_passkey() {
        let pk = SoftPasskey::generate();
        let (keys, root) = AccountKeys::create(&pk, "laptop").unwrap();
        assert_eq!(
            (keys.version, keys.epoch, keys.revision),
            (FORMAT_VERSION, 0, 1)
        );
        assert_eq!(keys.passkeys.len(), 1);
        assert_eq!(keys.passkeys[0].label, "laptop");
        assert!(
            keys.find(&CredentialIdHash::of(pk.credential_id()))
                .is_some()
        );
        keys.verify(&root).unwrap();
        let derived = root.derive(&keys.account_id);
        assert_eq!(keys.auth_public_key, derived.auth_public_key());
    }

    #[test]
    fn add_more_passkeys() {
        let (mut keys, root) = AccountKeys::create(&SoftPasskey::generate(), "a").unwrap();
        keys.add_passkey(&root, &SoftPasskey::generate(), "b")
            .unwrap();
        keys.add_passkey(&root, &SoftPasskey::generate(), "c")
            .unwrap();
        let labels: Vec<_> = keys.passkeys.iter().map(|p| p.label.as_str()).collect();
        assert_eq!(labels, ["a", "b", "c"]);
    }

    #[test]
    fn adding_needs_the_current_root_and_a_new_passkey() {
        let a = SoftPasskey::generate();
        let (mut keys, root) = AccountKeys::create(&a, "a").unwrap();
        let wrong_root = RootSecret::generate();
        assert_eq!(keys.verify(&wrong_root), Err(Error::WrongRootSecret));
        assert_eq!(
            keys.add_passkey(&wrong_root, &SoftPasskey::generate(), "x"),
            Err(Error::WrongRootSecret)
        );
        assert_eq!(
            keys.add_passkey(&root, &a, "again"),
            Err(Error::DuplicatePasskey)
        );
    }

    #[test]
    fn authenticator_errors_propagate() {
        assert_eq!(
            AccountKeys::create(&Failing, "x").map(|_| ()),
            Err(Error::Authenticator("user cancelled".into()))
        );
    }

    fn record(root: &RootSecret) -> AccountKeys {
        let account_id = AccountId::generate();
        let credential_id_hash = CredentialIdHash::of(b"cred");
        let key_pair = PasskeyKeyPair::from_prf(&crate::passkey::tests::test_prf(3));
        let wrapped = WrappedSecret::seal(
            root,
            key_pair.public_key(),
            &account_id,
            0,
            &credential_id_hash,
        )
        .unwrap();
        let mut keys = AccountKeys::empty(account_id, 0, root);
        keys.passkeys = vec![PasskeyInfo {
            credential_id_hash,
            label: "laptop".into(),
            wrapped,
            binding: Binding {
                epoch: 0,
                mac: [0; 32],
            },
        }];
        keys.sign(root);
        keys
    }

    #[test]
    fn verify_checks_root_and_signature() {
        let root = RootSecret::generate();
        let keys = record(&root);
        keys.verify(&root).unwrap();
        assert_eq!(
            keys.verify(&RootSecret::generate()),
            Err(Error::WrongRootSecret)
        );
        // Fresh review finding 4: a relay edit that leaves the key check alone
        // is caught, as is a broken chain.
        let mut renamed = keys.clone();
        renamed.passkeys[0].label = "relay".into();
        assert_eq!(renamed.verify(&root), Err(Error::Tampered));
        let mut no_chain = keys.clone();
        no_chain.epochs.clear();
        assert_eq!(no_chain.verify(&root), Err(Error::Malformed("epochs")));
    }

    #[test]
    fn json_round_trip_and_version_check() {
        let keys = record(&RootSecret::generate());
        assert_eq!(AccountKeys::from_json(&keys.to_json()).unwrap(), keys);
        let future = keys.to_json().replace("\"version\": 3", "\"version\": 4");
        assert_eq!(
            AccountKeys::from_json(&future),
            Err(Error::UnsupportedVersion(4))
        );
        let extra = keys.to_json().replacen('{', "{\"extra\": 1,", 1);
        assert_eq!(
            AccountKeys::from_json(&extra),
            Err(Error::Malformed("account keys"))
        );
        assert_eq!(
            AccountKeys::from_json("{}"),
            Err(Error::Malformed("account keys"))
        );
    }

    #[test]
    fn from_json_rejects_inconsistent_records() {
        let keys = record(&RootSecret::generate());
        let parse = |k: &AccountKeys| AccountKeys::from_json(&k.to_json());
        let mut empty = keys.clone();
        empty.passkeys.clear();
        assert_eq!(parse(&empty), Err(Error::Malformed("no passkeys")));
        let mut twice = keys.clone();
        twice.passkeys.push(keys.passkeys[0].clone());
        assert_eq!(parse(&twice), Err(Error::DuplicatePasskey));
        let mut long = keys.clone();
        long.passkeys[0].wrapped.ciphertext.push(0);
        assert_eq!(parse(&long), Err(Error::Malformed("wrapped secret")));
    }

    /// Fresh review finding 6: records from the relay are bounded.
    #[test]
    fn size_limits() {
        let root = RootSecret::generate();
        let keys = record(&root);
        let parse = |k: &AccountKeys| AccountKeys::from_json(&k.to_json());
        let mut long = keys.clone();
        long.passkeys[0].label = "x".repeat(MAX_LABEL_BYTES + 1);
        assert_eq!(parse(&long), Err(Error::Malformed("label too long")));
        let mut many = keys.clone();
        many.passkeys = vec![keys.passkeys[0].clone(); MAX_PASSKEYS + 1];
        assert_eq!(parse(&many), Err(Error::Malformed("too many passkeys")));
        let mut epochs = keys.clone();
        epochs.epochs = vec![keys.epochs[0].clone(); MAX_EPOCHS + 1];
        assert_eq!(parse(&epochs), Err(Error::Malformed("too many epochs")));
        let huge = " ".repeat(MAX_RECORD_BYTES + 1);
        assert_eq!(
            AccountKeys::from_json(&huge),
            Err(Error::Malformed("record too large"))
        );

        // The crate never makes a record it would refuse.
        let (mut keys, root) = AccountKeys::create(&SoftPasskey::generate(), "a").unwrap();
        let too_long = "x".repeat(MAX_LABEL_BYTES + 1);
        let pk = SoftPasskey::generate();
        assert_eq!(
            keys.add_passkey(&root, &pk, &too_long),
            Err(Error::LimitReached("label too long"))
        );
        for _ in 1..MAX_PASSKEYS {
            keys.add_passkey(
                &root,
                &SoftPasskey::generate(),
                &"x".repeat(MAX_LABEL_BYTES),
            )
            .unwrap();
        }
        assert_eq!(
            keys.add_passkey(&root, &pk, "a"),
            Err(Error::LimitReached("too many passkeys"))
        );
        parse(&keys).unwrap();
        keys.passkeys.truncate(1);
        keys.epochs = vec![keys.epochs[0].clone(); MAX_EPOCHS];
        keys.sign(&root);
        assert_eq!(
            keys.rotate(&root),
            Err(Error::LimitReached("too many epochs"))
        );
    }

    #[test]
    fn json_holds_no_secrets() {
        let bytes: [u8; 32] = std::array::from_fn(|i| 0x5a ^ i as u8);
        let root = RootSecret::from_bytes(&mut bytes.clone()).unwrap();
        let json = record(&root).to_json();
        assert!(!json.contains(&b64::encode(&bytes)));
    }

    #[test]
    fn create_then_unlock() {
        let pk = SoftPasskey::generate();
        let (keys, root) = AccountKeys::create(&pk, "laptop").unwrap();
        assert_eq!(keys.epoch, 0);
        assert_eq!(keys.passkeys.len(), 1);
        assert_eq!(keys.passkeys[0].label, "laptop");
        assert_eq!(keys.unlock(&pk).unwrap(), root);
        assert_eq!(
            keys.auth_public_key,
            root.derive(&keys.account_id).auth_public_key()
        );
    }

    #[test]
    fn multiple_passkeys_unlock_the_same_secret() {
        let a = SoftPasskey::generate();
        let b = SoftPasskey::generate();
        let c = SoftPasskey::generate();
        let (mut keys, root) = AccountKeys::create(&a, "a").unwrap();
        keys.add_passkey(&root, &b, "b").unwrap();
        keys.add_passkey(&root, &c, "c").unwrap();
        for pk in [&a, &b, &c] {
            assert_eq!(keys.unlock(pk).unwrap(), root);
        }
    }

    #[test]
    fn unregistered_passkey_is_unknown() {
        let (keys, _) = AccountKeys::create(&SoftPasskey::generate(), "a").unwrap();
        assert_eq!(
            keys.unlock(&SoftPasskey::generate()),
            Err(Error::UnknownPasskey)
        );
    }

    #[test]
    fn wrong_prf_for_known_credential_is_rejected() {
        let pk = SoftPasskey::generate();
        let (keys, _) = AccountKeys::create(&pk, "a").unwrap();
        let impostor = SoftPasskey::from_parts(pk.credential_id().to_vec(), [0; 32]);
        assert_eq!(keys.unlock(&impostor), Err(Error::WrongPasskey));
    }

    #[test]
    fn recovery_key_unlocks() {
        let (keys, root) = AccountKeys::create(&SoftPasskey::generate(), "a").unwrap();
        let recovery = RecoveryKey::from_root(&root);
        assert_eq!(keys.unlock_with_recovery_key(&recovery).unwrap(), root);
        let other = RecoveryKey::from_root(&RootSecret::generate());
        assert_eq!(
            keys.unlock_with_recovery_key(&other),
            Err(Error::WrongRootSecret)
        );
    }

    #[test]
    fn unlocks_after_json_round_trip() {
        let pk = SoftPasskey::generate();
        let (keys, root) = AccountKeys::create(&pk, "a").unwrap();
        let back = AccountKeys::from_json(&keys.to_json()).unwrap();
        assert_eq!(back.unlock(&pk).unwrap(), root);
    }

    #[test]
    fn remove_passkey() {
        let a = SoftPasskey::generate();
        let b = SoftPasskey::generate();
        let (mut keys, root) = AccountKeys::create(&a, "a").unwrap();
        keys.add_passkey(&root, &b, "b").unwrap();
        let removed = keys
            .remove_passkey(&root, &CredentialIdHash::of(b.credential_id()))
            .unwrap();
        assert_eq!(removed.label, "b");
        assert_eq!(keys.unlock(&b), Err(Error::UnknownPasskey));
        assert_eq!(keys.unlock(&a).unwrap(), root);
        assert_eq!(
            keys.remove_passkey(&root, &CredentialIdHash::of(a.credential_id())),
            Err(Error::LastPasskey)
        );
        assert_eq!(
            keys.remove_passkey(&root, &CredentialIdHash::of(b"nope")),
            Err(Error::UnknownPasskey)
        );
    }

    #[test]
    fn rotate_reseals_for_every_passkey_without_asking_them() {
        let a = SoftPasskey::generate();
        let b = SoftPasskey::generate();
        let (mut keys, old) = AccountKeys::create(&a, "a").unwrap();
        keys.add_passkey(&old, &b, "b").unwrap();
        let before = keys.clone();

        let new = keys.rotate(&old).unwrap();
        assert_ne!(new, old);
        assert_eq!(keys.epoch, 1);
        assert_eq!(keys.account_id, before.account_id);
        assert_ne!(keys.auth_public_key, before.auth_public_key);
        assert_eq!(keys.unlock(&a).unwrap(), new);
        assert_eq!(keys.unlock(&b).unwrap(), new);
        assert_eq!(keys.verify(&old), Err(Error::WrongRootSecret));
        assert_eq!(keys.rotate(&old), Err(Error::WrongRootSecret));
        let labels: Vec<_> = keys.passkeys.iter().map(|p| p.label.as_str()).collect();
        assert_eq!(labels, ["a", "b"]);
    }

    /// Fresh review finding 3: a passkey whose PRF output leaked keeps
    /// opening the root after a plain rotation, but not after it is removed
    /// in the same step.
    #[test]
    fn remove_and_rotate_evicts_leaked_passkeys() {
        let a = SoftPasskey::generate();
        let b = SoftPasskey::generate();
        let c = SoftPasskey::generate();
        let (mut keys, root) = AccountKeys::create(&a, "a").unwrap();
        keys.add_passkey(&root, &b, "b").unwrap();
        keys.add_passkey(&root, &c, "c").unwrap();
        let leaked = b.evaluate_prf(PRF_INPUT).unwrap();
        let b_hash = CredentialIdHash::of(b.credential_id());
        let c_hash = CredentialIdHash::of(c.credential_id());

        let mut plain = keys.clone();
        let new = plain.rotate(&root).unwrap();
        assert_eq!(
            plain.unlock_with_prf(b.credential_id(), &leaked).unwrap(),
            new
        );

        let revision = keys.revision;
        let new = keys.remove_and_rotate(&root, &[b_hash, c_hash]).unwrap();
        assert_eq!(keys.revision, revision + 1);
        assert_eq!(keys.unlock(&a).unwrap(), new);
        assert_eq!(
            keys.unlock_with_prf(b.credential_id(), &leaked),
            Err(Error::UnknownPasskey)
        );
        let a_hash = CredentialIdHash::of(a.credential_id());
        assert_eq!(
            keys.remove_and_rotate(&new, &[a_hash]),
            Err(Error::LastPasskey)
        );
        assert_eq!(
            keys.remove_and_rotate(&new, &[b_hash]),
            Err(Error::UnknownPasskey)
        );
        assert_eq!(AccountKeys::from_json(&keys.to_json()).unwrap(), keys);
    }

    #[test]
    fn old_wrapped_secrets_dont_open_at_new_epoch() {
        let a = SoftPasskey::generate();
        let (mut keys, old) = AccountKeys::create(&a, "a").unwrap();
        let stale = keys.passkeys[0].clone();
        keys.rotate(&old).unwrap();
        keys.passkeys[0] = stale;
        assert_eq!(keys.unlock(&a), Err(Error::DecryptionFailed));
    }

    #[test]
    fn recovery_key_unlocks_until_rotation() {
        let (mut keys, root) = AccountKeys::create(&SoftPasskey::generate(), "a").unwrap();
        let recovery = RecoveryKey::from_root(&root);
        assert_eq!(keys.unlock_with_recovery_key(&recovery).unwrap(), root);
        let new = keys.rotate(&root).unwrap();
        assert_eq!(
            keys.unlock_with_recovery_key(&recovery),
            Err(Error::WrongRootSecret)
        );
        assert_eq!(
            keys.unlock_with_recovery_key(&RecoveryKey::from_root(&new))
                .unwrap(),
            new
        );
    }

    /// Review finding 2: a relay that appends its own passkey entry must not
    /// receive the next rotated secret.
    #[test]
    fn injected_passkey_is_refused() {
        let (mut keys, root) = AccountKeys::create(&SoftPasskey::generate(), "a").unwrap();
        let relay = SoftPasskey::generate();
        let mut forged = keys.clone();
        let prf = relay.evaluate_prf(PRF_INPUT).unwrap();
        let kp = PasskeyKeyPair::from_prf(&prf);
        let hash = CredentialIdHash::of(relay.credential_id());
        let wrapped = WrappedSecret::seal(&root, kp.public_key(), &keys.account_id, 0, &hash);
        forged.passkeys.push(PasskeyInfo {
            credential_id_hash: hash,
            label: "relay".into(),
            wrapped: wrapped.unwrap(),
            binding: keys.passkeys[0].binding,
        });
        assert_eq!(forged.clone().rotate(&root), Err(Error::Tampered));
        let other = SoftPasskey::generate();
        assert_eq!(forged.add_passkey(&root, &other, "x"), Err(Error::Tampered));
        assert_eq!(forged.unlock(&relay), Err(Error::Tampered));
        keys.passkeys[0].label = "renamed".into();
        assert_eq!(keys.rotate(&root), Err(Error::Tampered));
    }

    #[test]
    fn rotation_extends_a_signed_epoch_chain() {
        let (mut keys, root) = AccountKeys::create(&SoftPasskey::generate(), "a").unwrap();
        let root = keys.rotate(&root).unwrap();
        keys.rotate(&root).unwrap();
        let epochs: Vec<_> = keys.epochs.iter().map(|l| l.epoch).collect();
        assert_eq!(epochs, [0, 1, 2]);
        assert_eq!(AccountKeys::from_json(&keys.to_json()).unwrap(), keys);

        // A link the relay forged, or one it dropped, breaks the chain.
        let mut forged = keys.clone();
        forged.epochs[2].key_check = forged.epochs[1].key_check;
        let parse = |k: &AccountKeys| AccountKeys::from_json(&k.to_json());
        assert!(matches!(
            parse(&forged),
            Err(Error::Tampered | Error::Malformed(_))
        ));
        forged.epochs[2] = keys.epochs[2].clone();
        forged.epochs[2].signature[0] ^= 1;
        assert_eq!(parse(&forged), Err(Error::Tampered));
        let mut gap = keys.clone();
        gap.epochs.remove(1);
        assert_eq!(parse(&gap), Err(Error::Tampered));
        let mut unsigned_first = keys.clone();
        unsigned_first.epochs.remove(0);
        assert_eq!(parse(&unsigned_first), Err(Error::Malformed("epochs")));
    }

    /// Review finding 1: a relay that seals a root of its own to the stored
    /// public keys, and signs a record to match, can't fool a new device.
    #[test]
    fn substituted_root_is_refused_at_unlock() {
        let a = SoftPasskey::generate();
        let (real, _) = AccountKeys::create(&a, "a").unwrap();
        let relay_root = RootSecret::generate();
        let mut forged = AccountKeys::empty(real.account_id, 0, &relay_root);
        let p = &real.passkeys[0];
        let wrapped = WrappedSecret::seal(
            &relay_root,
            &p.wrapped.public_key,
            &real.account_id,
            0,
            &p.credential_id_hash,
        );
        forged.passkeys.push(PasskeyInfo {
            wrapped: wrapped.unwrap(),
            ..p.clone()
        });
        forged.sign(&relay_root);
        assert_eq!(forged.unlock(&a), Err(Error::Tampered));
        // Same with a binding the relay made up, or one pointing at no epoch.
        forged.passkeys[0].binding.mac = [1; 32];
        forged.sign(&relay_root);
        assert_eq!(forged.unlock(&a), Err(Error::Tampered));
        forged.passkeys[0].binding = real.passkeys[0].binding;
        forged.passkeys[0].binding.epoch = 5;
        forged.sign(&relay_root);
        assert_eq!(forged.unlock(&a), Err(Error::Tampered));
    }

    /// Fresh review finding 1: a relay login challenge that is byte for byte
    /// a link (or record) transcript must not yield a signature that verifies
    /// as one.
    #[test]
    fn relay_request_signature_is_not_a_link_signature() {
        let a = SoftPasskey::generate();
        let (real, root) = AccountKeys::create(&a, "a").unwrap();
        let relay_root = RootSecret::generate();
        let mut forged = real.clone();
        let mut link = AccountKeys::empty(real.account_id, 1, &relay_root).epochs[0].clone();
        let challenge = link.signed_bytes(&real.account_id);
        let derived = root.derive(&real.account_id);
        let auth_key = &derived.auth_key;
        link.signature = auth_key.sign_relay_request(challenge.bytes()).to_vec();
        forged.epoch = 1;
        forged.key_check = link.key_check;
        forged.auth_public_key = link.auth_public_key;
        forged.record_public_key = link.record_public_key;
        forged.epochs.push(link);
        forged.sign(&relay_root);
        let parse = AccountKeys::from_json(&forged.to_json());
        assert_eq!(parse, Err(Error::Tampered));
        // Since the keys are split, not even a raw auth key signature of the
        // challenge passes as a link signature.
        let link = forged.epochs.last_mut().unwrap();
        link.signature = auth_key.sign(&challenge).to_vec();
        let parse = AccountKeys::from_json(&forged.to_json());
        assert_eq!(parse, Err(Error::Tampered));
        // Positive control: a record key signature of the same link (which
        // only a root holder can make) does let the forgery through.
        let link = forged.epochs.last_mut().unwrap();
        link.signature = derived.record_key.sign(&challenge).to_vec();
        let p = &real.passkeys[0];
        forged.passkeys[0].wrapped = WrappedSecret::seal(
            &relay_root,
            &p.wrapped.public_key,
            &real.account_id,
            1,
            &p.credential_id_hash,
        )
        .unwrap();
        forged.sign(&relay_root);
        let forged = AccountKeys::from_json(&forged.to_json()).unwrap();
        assert_eq!(forged.unlock(&a).unwrap(), relay_root);
        let record = real.signed_bytes();
        let signature = auth_key.sign_relay_request(record.bytes());
        assert!(!real.record_public_key.verify(&record, &signature));
        assert!(
            !real
                .record_public_key
                .verify(&record, &auth_key.sign(&record))
        );
    }

    #[test]
    fn bindings_from_older_epochs_still_unlock() {
        let a = SoftPasskey::generate();
        let (mut keys, root) = AccountKeys::create(&a, "a").unwrap();
        let root = keys.rotate(&root).unwrap();
        let b = SoftPasskey::generate();
        keys.add_passkey(&root, &b, "b").unwrap();
        let root = keys.rotate(&root).unwrap();
        let bound: Vec<_> = keys.passkeys.iter().map(|p| p.binding.epoch).collect();
        assert_eq!(bound, [0, 1]);
        assert_eq!(keys.unlock(&a).unwrap(), root);
        assert_eq!(keys.unlock(&b).unwrap(), root);
    }

    #[test]
    fn unlock_rebinds_passkeys_bound_before_a_rotation() {
        let a = SoftPasskey::generate();
        let (mut keys, root) = AccountKeys::create(&a, "a").unwrap();
        assert_eq!(keys.unlock_and_rebind(&a).unwrap(), (root.clone(), false));
        let root = keys.rotate(&root).unwrap();
        let revision = keys.revision;
        assert_eq!(keys.unlock_and_rebind(&a).unwrap(), (root.clone(), true));
        assert_eq!(
            (keys.passkeys[0].binding.epoch, keys.revision),
            (1, revision + 1)
        );
        let back = AccountKeys::from_json(&keys.to_json()).unwrap();
        assert_eq!(back.unlock(&a).unwrap(), root);
        assert_eq!(keys.unlock_and_rebind(&a).unwrap(), (root, false));
    }

    /// Fresh review finding 2: a former root holder and the relay fork the
    /// account from a record kept from before a rotation. The rebind doesn't
    /// stop it, but a device that remembers the epoch it knows does.
    #[test]
    fn successor_check_refuses_a_fork_from_a_rotated_away_root() {
        let a = SoftPasskey::generate();
        let (mut keys, old_root) = AccountKeys::create(&a, "a").unwrap();
        let kept = keys.clone();
        let root = keys.rotate(&old_root).unwrap();
        keys.unlock_and_rebind(&a).unwrap();
        let known = keys.verify(&root).unwrap();

        let mut fork = kept;
        let fork_root = fork.rotate(&old_root).unwrap();
        for _ in 0..3 {
            fork.add_passkey(&fork_root, &SoftPasskey::generate(), "x")
                .unwrap();
        }
        let fork = AccountKeys::from_json(&fork.to_json()).unwrap();
        assert!(fork.revision > known.revision);
        assert_eq!(fork.unlock(&a).unwrap(), fork_root, "the attack works");
        assert_eq!(fork.verify_successor(&known), Err(Error::Tampered));

        // Real changes after the known epoch pass; older records don't.
        let older = keys.clone();
        keys.add_passkey(&root, &SoftPasskey::generate(), "b")
            .unwrap();
        let root = keys.rotate(&root).unwrap();
        assert_eq!(keys.verify_successor(&known), keys.verify(&root));
        let newest = keys.verify(&root).unwrap();
        assert_eq!(older.verify_successor(&newest), Err(Error::Stale));
        let mut other = known.clone();
        other.account_id = AccountId::from_bytes([1; 16]);
        assert_eq!(older.verify_successor(&other), Err(Error::Tampered));
        // A relay edit after the chain is caught by the record signature.
        let mut renamed = keys.clone();
        renamed.passkeys[0].label = "relay".into();
        assert_eq!(renamed.verify_successor(&known), Err(Error::Tampered));
    }

    /// Rolling back to an earlier epoch is refused even if the relay raises
    /// the revision it shows, since the record signature covers it.
    #[test]
    fn successor_check_refuses_a_rollback_to_an_earlier_epoch() {
        let (mut keys, root) = AccountKeys::create(&SoftPasskey::generate(), "a").unwrap();
        let mut old = keys.clone();
        let root = keys.rotate(&root).unwrap();
        let known = keys.verify(&root).unwrap();
        assert_eq!(old.verify_successor(&known), Err(Error::Stale));
        old.revision = known.revision;
        assert_eq!(old.verify_successor(&known), Err(Error::Tampered));
    }

    /// Store a KnownEpoch only for a record the relay holds: one taken from a
    /// local change whose upload failed locks the device out as stale.
    #[test]
    fn known_epoch_of_a_lost_upload_is_ahead_of_the_relay() {
        let a = SoftPasskey::generate();
        let (mut relay, root) = AccountKeys::create(&a, "a").unwrap();
        let root = relay.rotate(&root).unwrap();
        let fetched = relay.verify(&root).unwrap();
        let mut local = relay.clone();
        assert!(local.unlock_and_rebind(&a).unwrap().1);
        let unsent = local.verify(&root).unwrap();
        // The upload is lost; the relay still serves its record.
        assert_eq!(relay.verify_successor(&unsent), Err(Error::Stale));
        assert_eq!(relay.verify_successor(&fetched), Ok(fetched));
    }

    /// Pins the binding MAC and the link signature byte for byte; the same
    /// values come from the independent Python in `scripts/known_answers.py`.
    #[test]
    fn binding_and_link_known_answers() {
        use crate::keys::tests::{account, assert_hex, test_root};
        let link = |root: &RootSecret, epoch| EpochLink {
            epoch,
            key_check: root.key_check(&account()),
            auth_public_key: root.derive(&account()).auth_public_key(),
            record_public_key: root.derive(&account()).record_public_key(),
            signature: Vec::new(),
        };
        let pk = SoftPasskey::from_parts(b"cred".to_vec(), [9; 32]);
        let prf = pk.evaluate_prf(PRF_INPUT).unwrap();
        let info = PasskeyInfo {
            credential_id_hash: CredentialIdHash::of(b"cred"),
            label: String::new(),
            wrapped: WrappedSecret {
                public_key: *PasskeyKeyPair::from_prf(&prf).public_key(),
                encapped_key: [0; 32],
                ciphertext: Vec::new(),
            },
            binding: Binding {
                epoch: 0,
                mac: [0; 32],
            },
        };
        let message = binding_bytes(&account(), &link(&test_root(0), 0), &info);
        let mac = binding_mac(&prf).chain_update(message.bytes()).finalize();
        assert_hex(
            "binding",
            &mac.into_bytes(),
            "b0a1c7c129c5b92c2236d1cdc7c0b0d358e6be5df316dde7b65eaab0114d1fab",
        );
        let next = link(&test_root(1), 1).signed_bytes(&account());
        let signature = test_root(0).derive(&account()).record_key.sign(&next);
        assert_hex(
            "link_signature",
            &signature,
            "82b9ee112d049cd2de6c9b354a838ac9a0ad1db9be09a5f75ccec15f68961ed0103a873418d8369b795e6c041b3ae9be25560c6ce051fcefc825822f259b200e",
        );
    }

    #[test]
    fn every_change_bumps_the_revision() {
        let (mut keys, root) = AccountKeys::create(&SoftPasskey::generate(), "a").unwrap();
        let b = SoftPasskey::generate();
        keys.add_passkey(&root, &b, "b").unwrap();
        assert_eq!(keys.revision, 2);
        let root = keys.rotate(&root).unwrap();
        assert_eq!(keys.revision, 3);
        keys.remove_passkey(&root, &CredentialIdHash::of(b.credential_id()))
            .unwrap();
        assert_eq!(keys.revision, 4);
        keys.revision = u64::MAX;
        assert_eq!(keys.rotate(&root), Err(Error::Tampered));
        keys.sign(&root);
        assert_eq!(keys.rotate(&root), Err(Error::Malformed("revision")));
    }

    #[test]
    fn account_id_displays_as_base64url() {
        let id = AccountId::from_bytes([0; 16]);
        assert_eq!(id.to_string(), "AAAAAAAAAAAAAAAAAAAAAA");
        assert_eq!(format!("{id:?}"), "AccountId(AAAAAAAAAAAAAAAAAAAAAA)");
    }
}
