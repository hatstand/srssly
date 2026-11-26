//! Serde helpers that store bytes as unpadded base64url strings.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Deserializer, Serializer, de::Error as _};

pub fn encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn decode(s: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(s).ok()
}

pub fn serialize<S: Serializer>(bytes: impl AsRef<[u8]>, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&encode(bytes.as_ref()))
}

pub fn deserialize<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: TryFrom<Vec<u8>>,
{
    let s = String::deserialize(d)?;
    let bytes = decode(&s).ok_or_else(|| D::Error::custom("invalid base64url"))?;
    T::try_from(bytes).map_err(|_| D::Error::custom("wrong length"))
}
