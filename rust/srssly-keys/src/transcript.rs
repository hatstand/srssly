//! The byte encoding that signatures and MACs cover. Every field is its
//! length (u32, big-endian) then its bytes, after a domain label, so other
//! implementations can rebuild it exactly and no two field lists collide.

pub(crate) struct Transcript(Vec<u8>);

impl Transcript {
    pub(crate) fn new(label: &[u8]) -> Self {
        let mut t = Self(Vec::new());
        t.field(label);
        t
    }

    pub(crate) fn field(&mut self, bytes: &[u8]) -> &mut Self {
        let len = u32::try_from(bytes.len()).expect("fields are far below 4 GiB");
        self.0.extend_from_slice(&len.to_be_bytes());
        self.0.extend_from_slice(bytes);
        self
    }

    pub(crate) fn bytes(&self) -> &[u8] {
        &self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fields_are_length_prefixed() {
        let mut t = Transcript::new(b"L");
        t.field(b"ab").field(b"");
        assert_eq!(t.bytes(), b"\0\0\0\x01L\0\0\0\x02ab\0\0\0\0");
    }
}
