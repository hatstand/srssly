use std::fmt;

use bip39::Mnemonic;

use crate::keys::RootSecret;
use crate::{Error, Result};

/// The root secret written as 24 BIP39 English words, for recovery when
/// every passkey is gone.
pub struct RecoveryKey(Mnemonic);

impl RecoveryKey {
    pub fn from_root(root: &RootSecret) -> Self {
        Self(Mnemonic::from_entropy(root.as_bytes()).expect("32 bytes is valid BIP39 entropy"))
    }

    /// Parses words separated by whitespace, ignoring case and extra spaces.
    pub fn parse(words: &str) -> Result<Self> {
        let normalized = words
            .split_whitespace()
            .map(str::to_lowercase)
            .collect::<Vec<_>>()
            .join(" ");
        let m =
            Mnemonic::parse(normalized).map_err(|e| Error::InvalidRecoveryKey(e.to_string()))?;
        if m.word_count() != 24 {
            return Err(Error::InvalidRecoveryKey(format!(
                "expected 24 words, got {}",
                m.word_count()
            )));
        }
        Ok(Self(m))
    }

    pub fn root_secret(&self) -> RootSecret {
        let (entropy, len) = self.0.to_entropy_array();
        debug_assert_eq!(len, 32);
        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(&entropy[..32]);
        RootSecret::from_bytes(bytes)
    }

    pub fn words(&self) -> String {
        self.0.to_string()
    }
}

impl fmt::Debug for RecoveryKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RecoveryKey(..)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let root = RootSecret::generate();
        let key = RecoveryKey::from_root(&root);
        assert_eq!(key.words().split(' ').count(), 24);
        assert_eq!(
            RecoveryKey::parse(&key.words()).unwrap().root_secret(),
            root
        );
    }

    #[test]
    fn parsing_is_forgiving_about_case_and_spacing() {
        let root = RootSecret::generate();
        let words = RecoveryKey::from_root(&root)
            .words()
            .to_uppercase()
            .replace(' ', "  \n");
        assert_eq!(RecoveryKey::parse(&words).unwrap().root_secret(), root);
    }

    #[test]
    fn rejects_bad_checksum_and_short_keys() {
        let words = RecoveryKey::from_root(&RootSecret::from_bytes([0; 32])).words();
        let mut list: Vec<&str> = words.split(' ').collect();
        list[23] = if list[23] == "zoo" { "abandon" } else { "zoo" };
        assert!(RecoveryKey::parse(&list.join(" ")).is_err());
        let twelve = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        assert!(matches!(
            RecoveryKey::parse(twelve),
            Err(Error::InvalidRecoveryKey(_))
        ));
    }

    #[test]
    fn known_vector() {
        // BIP39 test vector: 32 zero bytes.
        let key = RecoveryKey::from_root(&RootSecret::from_bytes([0; 32]));
        assert_eq!(
            key.words(),
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
        );
    }
}
