"""Independent reference for the known-answer tests in srssly-keys.

Run with `python3 scripts/known_answers.py` (needs the `cryptography` package).
It reimplements the key derivations from their specs, so the Rust tests are
not checked against themselves.
"""

import hashlib
import hmac

from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

H = lambda k, m: hmac.new(k, m, hashlib.sha256).digest()


def hkdf(salt, ikm, info, n):
    prk = H(salt, ikm)
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = H(prk, t + info + bytes([i]))
        out += t
        i += 1
    return out[:n]


raw = lambda k: k.public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
root = bytes(range(32))
acct = bytes([7] * 16)
salt = b"srssly/v1/root/" + acct
results = {
    "key_check": hkdf(salt, root, b"key-check", 16),
    "data_key": hkdf(salt, root, b"data-key", 32),
    "auth_public": raw(
        Ed25519PrivateKey.from_private_bytes(hkdf(salt, root, b"auth-key", 32)).public_key()
    ),
    "ctap_salt": hashlib.sha256(b"WebAuthn PRF\x00" + b"srssly/v1/passkey-prf").digest(),
}
results["prf"] = H(bytes([9] * 32), results["ctap_salt"])

# RFC 9180 DeriveKeyPair for DHKEM(X25519, HKDF-SHA256)
SUITE = b"KEM" + (0x20).to_bytes(2, "big")


def labeled_extract(salt, label, ikm, suite=SUITE):
    return H(salt or bytes(32), b"HPKE-v1" + suite + label + ikm)


def labeled_expand(prk, label, info, length, suite=SUITE):
    labeled_info = length.to_bytes(2, "big") + b"HPKE-v1" + suite + label + info
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = H(prk, t + labeled_info + bytes([i]))
        out += t
        i += 1
    return out[:length]


ikm = hkdf(b"srssly/v1/passkey-kem", results["prf"], b"x25519", 32)
sk = labeled_expand(labeled_extract(b"", b"dkp_prk", ikm), b"sk", b"", 32)
passkey_sk = X25519PrivateKey.from_private_bytes(sk)
results["passkey_public"] = raw(passkey_sk.public_key())

# RFC 9180 base-mode open (DHKEM X25519, HKDF-SHA256, AES-256-GCM) of the
# wrapped secret pinned in wrap.rs: it must give back the test root secret.
HPKE_SUITE = b"HPKE" + bytes([0, 0x20, 0, 1, 0, 2])
enc = bytes.fromhex("e8f3de694a8a6baf4c8f79d68597e65ff59dcb94b3745d59b168f1dca8058945")
ciphertext = bytes.fromhex(
    "8f8c21b665f61dd66c8a9be940cc1725be895afb1396bcdbef7180b46bd501a1032294190c7c185aa8d17468ed94e81d"
)
dh = passkey_sk.exchange(X25519PublicKey.from_public_bytes(enc))
shared = labeled_expand(
    labeled_extract(b"", b"eae_prk", dh), b"shared_secret", enc + results["passkey_public"], 32
)
info = b"srssly/v1/root-wrap"
context = (
    b"\x00"
    + labeled_extract(b"", b"psk_id_hash", b"", HPKE_SUITE)
    + labeled_extract(b"", b"info_hash", info, HPKE_SUITE)
)
secret = labeled_extract(shared, b"secret", b"", HPKE_SUITE)
key = labeled_expand(secret, b"key", context, 32, HPKE_SUITE)
nonce = labeled_expand(secret, b"base_nonce", context, 12, HPKE_SUITE)
aad = b"srssly/v1/root-wrap/" + acct + (0).to_bytes(4, "big") + hashlib.sha256(b"cred").digest()
results["unwrapped_root"] = AESGCM(key).decrypt(nonce, ciphertext, aad)

# Key record authentication (account.rs): the passkey binding at epoch 0 and
# the epoch-1 link signed by epoch 0's auth key. Fields are length-prefixed.
def transcript(label, *fields):
    return b"".join(len(f).to_bytes(4, "big") + f for f in (label, *fields))


def epoch_values(root):
    seed = hkdf(salt, root, b"auth-key", 32)
    return hkdf(salt, root, b"key-check", 16), seed


key_check0, seed0 = epoch_values(root)
auth0 = Ed25519PrivateKey.from_private_bytes(seed0)
binding_key = hkdf(b"srssly/v1/passkey-kem", results["prf"], b"binding-mac", 32)
results["binding"] = H(
    binding_key,
    transcript(
        b"srssly/v2/binding",
        acct,
        (0).to_bytes(4, "big"),
        key_check0,
        raw(auth0.public_key()),
        hashlib.sha256(b"cred").digest(),
        results["passkey_public"],
    ),
)
key_check1, seed1 = epoch_values(bytes(range(1, 33)))
auth1_public = raw(Ed25519PrivateKey.from_private_bytes(seed1).public_key())
results["link_signature"] = auth0.sign(
    transcript(b"srssly/v2/link", acct, (1).to_bytes(4, "big"), key_check1, auth1_public)
)

# The same values are pinned in the Rust tests.
EXPECTED = {
    "key_check": "7d745637d079f47074bfa7e55b88b32e",
    "data_key": "cd83ad81a9fdd0261d66adc35de901016197cef3917079477a6153a7e1fd1678",
    "auth_public": "b73c2d802b74e5438e51c49cbab6873ba403e6a67ceea29abe902a4a72bd3172",
    "prf": "0763ce60a3fe189c114c48cf3a5ef43bbe48429e10c6384a67de5ead8a96e1f9",
    "passkey_public": "3819b8a928132364538f0874ebacc1d03b551b8e2d1c3c0af8163d0209babd3e",
    "unwrapped_root": root.hex(),
    "binding": "b2b55fb8363fee8da86bf171176e45d7442564ecb3f8f1a6d3dd263836e2f41e",
    "link_signature": "22262c84fd317a1fed3c402194add22e402d09886751b98d25a6b38f632fac1d5d0b8cc08efbe06f124414040989a9f8c6af5220d32ff7b295d9cc08e4d00506",
    "ctap_salt": "09cfa2c104ea19b7a59f9472b2b6fd18194db1b560fa3bff1add23bfdd921a42",
}

failed = False
for name, value in results.items():
    ok = value.hex() == EXPECTED[name]
    failed |= not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name} {value.hex()}")
raise SystemExit(1 if failed else 0)
