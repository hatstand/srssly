//! The part of srssly-keys that the iOS app calls, exported to Swift with
//! UniFFI. Swift sees these as the `SrsslyKeys` module; see
//! `scripts/build-rust-ios.sh`.
//!
//! Keep this thin: types and logic live in srssly-keys, and secrets cross
//! the boundary only where the app must store them.

uniffi::setup_scaffolding!();

/// Format version of the account records the Rust core reads and writes.
#[uniffi::export]
pub fn format_version() -> u32 {
    srssly_keys::FORMAT_VERSION
}

#[cfg(test)]
mod tests {
    #[test]
    fn reports_the_core_format_version() {
        assert_eq!(super::format_version(), srssly_keys::FORMAT_VERSION);
    }
}
