use std::fmt;

use bip39::Mnemonic;
use zeroize::{Zeroize, Zeroizing};

use crate::keys::{RootSecret, looks_random};
use crate::{Error, Result};

/// The root secret written as 24 BIP39 English words, for recovery when
/// every passkey is gone. The words are the root secret, so reading them
/// needs the `export-root-secret` feature; the phrase is wiped on drop.
pub struct RecoveryKey(Mnemonic);

impl RecoveryKey {
    pub fn from_root(root: &RootSecret) -> Self {
        Self(Mnemonic::from_entropy(root.as_bytes()).expect("32 bytes is valid BIP39 entropy"))
    }

    /// Parses words separated by whitespace, ignoring case and extra spaces.
    /// Rejects phrases whose secret is obviously not random, such as
    /// "abandon abandon ... art".
    pub fn parse(words: &str) -> Result<Self> {
        // Any Unicode whitespace separates words (a pasted phrase can carry
        // non-breaking spaces), but BIP39 English words are ASCII. Refusing
        // other words means lowercasing can't lengthen one, so the buffer
        // sized up front never reallocates and leaves no stray copy.
        let mut normalized = Zeroizing::new(String::with_capacity(words.len()));
        for word in words.split_whitespace() {
            if !word.is_ascii() {
                return Err(Error::InvalidRecoveryKey(
                    "not an English BIP39 phrase".into(),
                ));
            }
            if !normalized.is_empty() {
                normalized.push(' ');
            }
            normalized.extend(word.chars().map(|c| c.to_ascii_lowercase()));
        }
        let m = Mnemonic::parse(normalized.as_str())
            .map_err(|e| Error::InvalidRecoveryKey(e.to_string()))?;
        if m.word_count() != 24 {
            return Err(Error::InvalidRecoveryKey(format!(
                "expected 24 words, got {}",
                m.word_count()
            )));
        }
        if !looks_random(&entropy(&m)) {
            return Err(Error::InvalidRecoveryKey("not a random key".into()));
        }
        Ok(Self(m))
    }

    pub fn root_secret(&self) -> RootSecret {
        RootSecret::from_bytes(&mut entropy(&self.0)).expect("checked when parsed")
    }

    /// The 24 words, to show the user once. Only built with
    /// `export-root-secret`, since they are the root secret.
    #[cfg(any(test, feature = "export-root-secret"))]
    pub fn words(&self) -> Zeroizing<String> {
        Zeroizing::new(self.0.to_string())
    }
}

/// The 32 bytes a 24-word phrase encodes.
fn entropy(m: &Mnemonic) -> Zeroizing<[u8; 32]> {
    let (mut entropy, len) = m.to_entropy_array();
    debug_assert_eq!(len, 32);
    let mut bytes = Zeroizing::new([0u8; 32]);
    bytes.copy_from_slice(&entropy[..32]);
    entropy.zeroize();
    bytes
}

impl fmt::Debug for RecoveryKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RecoveryKey(..)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::tests::test_root;

    #[test]
    fn round_trip() {
        let root = RootSecret::generate();
        let key = RecoveryKey::from_root(&root);
        assert_eq!(key.words().split(' ').count(), 24);
        assert_eq!(
            RecoveryKey::parse(key.words().as_str())
                .unwrap()
                .root_secret(),
            root
        );
    }

    #[test]
    fn parsing_is_forgiving_about_case_and_spacing() {
        let root = RootSecret::generate();
        let words = RecoveryKey::from_root(&root)
            .words()
            .to_uppercase()
            .replace(' ', " \u{00a0}\n");
        assert_eq!(RecoveryKey::parse(&words).unwrap().root_secret(), root);
    }

    #[test]
    fn rejects_bad_checksum_and_short_keys() {
        let words = RecoveryKey::from_root(&test_root(0)).words();
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
    fn rejects_non_ascii_phrases() {
        let words = RecoveryKey::from_root(&test_root(0)).words();
        let fancy = words.replacen('a', "\u{0130}", 1);
        assert!(matches!(
            RecoveryKey::parse(&fancy),
            Err(Error::InvalidRecoveryKey(_))
        ));
    }

    #[test]
    fn rejects_non_random_phrases() {
        // Valid BIP39 for 32 zero bytes, but not a key anyone generated.
        let zeros = format!("{}art", "abandon ".repeat(23));
        assert!(matches!(
            RecoveryKey::parse(&zeros),
            Err(Error::InvalidRecoveryKey(_))
        ));
    }

    #[test]
    fn known_vector() {
        // A BIP39 test vector from the reference implementation.
        let bytes = [
            0x68, 0xa7, 0x9e, 0xac, 0xa2, 0x32, 0x48, 0x73, 0xea, 0xcc, 0x50, 0xcb, 0x9c, 0x6e,
            0xca, 0x8c, 0xc6, 0x8e, 0xa5, 0xd9, 0x36, 0xf9, 0x87, 0x87, 0xc6, 0x0c, 0x7e, 0xbc,
            0x74, 0xe6, 0xce, 0x7c,
        ];
        let key = RecoveryKey::from_root(&RootSecret::from_bytes(&mut bytes.clone()).unwrap());
        assert_eq!(
            key.words().as_str(),
            "hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length"
        );
    }
}
