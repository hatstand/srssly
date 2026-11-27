# srssly-keys

Key management for Srssly's end-to-end encrypted sync: passkey PRF wrapping,
recovery keys and key rotation. It is the first piece of the shared Rust sync
core; Swift, Kotlin and WebAssembly bindings come later.

```sh
cd rust
cargo test --all-features                            # unit tests and CLI end-to-end tests
python3 srssly-keys/scripts/known_answers.py         # independent check of the pinned test vectors (needs `cryptography`)
cargo run -q -p srssly-keys --features cli -- --help # the CLI
```

## How it works

Each account has one random 32-byte **root secret**. It never leaves a device
unencrypted. `RootSecret` has no public way to read its bytes; code that must
store them (the platform keychain, the CLI's test device file) enables the
`export-root-secret` feature and calls `RootSecret::export`. The same feature
gates `RecoveryKey::words`, since the words are the secret.
Every way of making a `RootSecret` (generating, unsealing, a recovery phrase,
raw bytes) rejects bytes with fewer than 8 distinct values. That can't prove a
secret is random, but it catches zeros, repeated bytes, short patterns and a
broken RNG, and a truly random secret fails it with probability about 10⁻³⁷. The relay stores an `AccountKeys` record that is safe for it to
see: public keys, a key check and sealed secrets.

| Piece | How it's made |
| --- | --- |
| Passkey PRF | WebAuthn `prf` extension, input `srssly/v1/passkey-prf` (the same for every credential, so sign-in needs no username). |
| Passkey key pair | X25519 via RFC 9180 `DeriveKeyPair` from `HKDF-SHA256(salt="srssly/v1/passkey-kem", ikm=PRF output, info="x25519")`. The public key is stored on the relay. |
| Wrapped secret | The root secret sealed with HPKE base mode (DHKEM X25519, HKDF-SHA256, AES-256-GCM), `info="srssly/v1/root-wrap"`, associated data = `"srssly/v1/root-wrap/" ‖ account ID ‖ epoch (u32 BE) ‖ SHA-256(credential ID)`. One per passkey. |
| Derived keys | `HKDF-SHA256(salt="srssly/v1/root/" ‖ account ID, ikm=root)`: `key-check` (16 bytes, public), `data-key` (AES-256-GCM for records), `auth-key` (Ed25519 seed for relay authentication). |
| Recovery key | The root secret as 24 BIP39 English words. Optional. |
| Relay request signature | Ed25519 by the auth key over `srssly/v2/relay-auth` ‖ request, length-prefixed. `AuthKey::sign_relay_request` is the only public way to sign, so a request the relay chooses can't come back as a record or link signature. |
| Record signature | Ed25519 by the current auth key over every field of the record, each length-prefixed (u32 BE) after the label `srssly/v2/record`. |
| Epoch link | One per epoch: key check and auth public key. Each after the first is signed by the previous epoch's auth key over `srssly/v2/link` ‖ account ‖ epoch ‖ key check ‖ auth public key. |
| Passkey binding | `HMAC-SHA256(HKDF-SHA256(salt="srssly/v1/passkey-kem", ikm=PRF output, info="binding-mac"), "srssly/v2/binding" ‖ account ‖ epoch ‖ key check ‖ auth public key ‖ credential hash ‖ passkey public key)`, at the epoch the passkey was bound. |

Because each passkey is represented by a public key, the root secret can be
sealed to every passkey without asking each one again. That is what makes
these work:

- **Multiple passkeys.** Add one from any unlocked device; each gets its own
  wrapped copy, found by its credential ID hash.
- **Removal.** Deletes that passkey's wrapped copy. It can't undo a device
  that already unlocked the secret; rotation does that.
- **Rotation.** A new root secret and epoch, re-sealed to every registered
  passkey. Devices holding only the old root, old wrapped copies and the old
  recovery key stop working, so show a new recovery key after every
  rotation. (Synced records then need re-encrypting under the new data key;
  that's for the sync layer.)
- **Recovering from a compromised device.** Rotation re-seals to the same
  passkey public keys, so anything that kept a passkey's PRF output opens
  the new root too; with a synced passkey, that is every device it reached.
  Verify the record and check the passkey list for entries the user doesn't
  recognise (that device held the root and could have added its own).
  Register a fresh credential, then call `remove_and_rotate` with every
  passkey the device used, so they never receive the new root. The fresh
  credential comes first: with one synced passkey there is nothing else
  left to unlock with.

## Why the relay can't forge the record

The relay can rewrite the record it stores, so the record authenticates
itself (format version 2):

- **Changes need the root.** Every change is signed with the current auth
  key. `add_passkey`, `remove_passkey` and `rotate` check that signature
  with the key derived from the caller's root, so an entry the relay slips
  in never receives a rotated secret.
- **Reading needs the root too.** A fetched record is unauthenticated
  until `AccountKeys::verify(&root)` passes (key check, record signature,
  epoch chain); check it before showing passkeys or trusting the revision.
  `srssly-keys list` verifies only when given `--device`.
- **A new device trusts its passkey, not the relay.** Anyone can seal a
  secret to a stored public key, so unlocking first checks the passkey's
  binding, which only that passkey's PRF can make. The binding vouches for
  its epoch, the signed epoch links for each rotation after it, and the
  record signature for the rest.
- **Lazy rebind.** `unlock_and_rebind` moves a passkey's binding to the
  current epoch the first time it unlocks after a rotation; store the record
  when it says so. This keeps bindings fresh but does not stop a fork: a
  binding MAC can't be revoked, so a relay that kept a record from before a
  rotation can serve one that a former root holder rotated differently, and
  an old binding vouches for it.
- **Devices that have seen the account check for forks.** `verify(&root)`
  and `verify_successor` return a `KnownEpoch` (public values: epoch, key
  check, auth public key, revision). Store it beside the root, but only for a
  record the relay holds (one just fetched, or an upload it accepted): a
  local change it never got would make its record look stale. Before
  trusting a fetched record, and above all before unlocking with a passkey
  again because the root no longer matches, call `verify_successor(&known)`.
  It refuses a record whose chain doesn't pass through the known epoch's keys
  (`tampered`) or whose revision is lower (`stale`). So a fork made with any
  root older than the known epoch fails; a device is protected from a
  former root holder only once it has seen the rotation that evicted them.
- **Not covered:** a brand-new device has nothing to compare, so its first
  sign-in trusts the relay not to collude with a former root holder, and not
  to serve an older, validly signed record. A comparison code shown on an
  existing device and the new one would close this; it isn't built yet.

## Authenticators

Authenticators implement `PrfAuthenticator`. Today there is `SoftPasskey`, a
software stand-in that behaves like a CTAP2 authenticator with
`hmac-secret`: `HMAC-SHA-256(credRandom, SHA-256("WebAuthn PRF" ‖ 0x00 ‖ input))`. It is
only compiled in tests or with the `soft-passkey` feature (which the `cli`
feature turns on). No feature is on by default, so app builds never contain
it. CI checks that the FFI crate enables no srssly-keys feature (the real
guard), and, as a backstop, `scripts/check-app-lib.sh` looks for the
test-only symbols in the Linux and iOS libraries. Being a symbol check, it
can't see code that was inlined away.
Anything that can report a credential ID and PRF output (a browser, a
platform passkey API) can also be used directly, through the `*_with_prf`
functions or the CLI's `--credential-id`/`--prf-file` flags.

Planned: YubiKeys over CTAP2 `hmac-secret`, and Touch ID / platform passkeys,
for manual testing.

## CLI

`srssly-keys` drives the whole lifecycle from files, for manual testing and
scripts. Each command prints one JSON object; errors print
`{"error": "<code>", "message": ...}` to stderr and exit 1.

```sh
srssly-keys passkey new --out a.json                 # software passkey (TEST ONLY: holds its secret)
srssly-keys create --account acct.json --device dev.json --passkey a.json --label laptop
srssly-keys passkey new --out b.json
srssly-keys add-passkey --account acct.json --device dev.json --passkey b.json --label phone
srssly-keys list --account acct.json
srssly-keys unlock --account acct.json --passkey b.json --device-out dev2.json
srssly-keys recovery-key --device dev.json
srssly-keys recover --account acct.json --words-file words.txt --device-out dev3.json
srssly-keys rotate --account acct.json --device dev.json
srssly-keys remove-passkey --account acct.json --device dev.json --passkey b.json
srssly-keys verify --account acct.json --device dev.json
# A real authenticator: pass what the browser's PRF extension returned. Secrets
# come from a file or stdin (`-`), never an argument, to keep them out of the
# process list and shell history.
echo <base64url> | srssly-keys unlock --account acct.json --credential-id <base64url> --prf-file -
```

Files are replaced atomically (written beside the old one, then renamed),
so a crash mid-`rotate` can't truncate one. `acct.json` is what the relay would store. `dev.json` stands in for a device's
Keychain and holds the root secret in plain text, so it is for testing only.

Error codes: `wrong_passkey`, `unknown_passkey`, `duplicate_passkey`,
`last_passkey`, `decryption_failed`, `wrong_root_secret`,
`invalid_recovery_key`, `unsupported_version`, `authenticator`, `tampered`, `stale`, `limit_reached`, `malformed`,
`io`, `usage`.
