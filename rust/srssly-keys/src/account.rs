use crate::random_bytes;

/// A random 16-byte account identifier. It stays the same when keys rotate.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AccountId([u8; 16]);

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
