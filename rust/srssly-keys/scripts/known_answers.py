"""Independent reference for the known-answer tests in srssly-keys.

Run with `python3 scripts/known_answers.py` (needs the `cryptography` package).
It reimplements the key derivation, the CTAP hmac-secret salt and RFC 9180
DeriveKeyPair from their specs, so the Rust tests are not checked against
themselves.
"""
import hmac, hashlib
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization as s

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
root = bytes([1] * 32)
acct = bytes([7] * 16)
salt = b"srssly/v1/root/" + acct
seed = hkdf(salt, root, b"auth-key", 32)
results = {
    "key_check": hkdf(salt, root, b"key-check", 16),
    "data_key": hkdf(salt, root, b"data-key", 32),
    "auth_public": raw(Ed25519PrivateKey.from_private_bytes(seed).public_key()),
}

inp = b"srssly/v1/passkey-prf"
ctap = hashlib.sha256(b"WebAuthn PRF\x00" + inp).digest()
prf = H(bytes([9] * 32), ctap)
results["prf"] = prf

# RFC 9180 DeriveKeyPair for DHKEM(X25519, HKDF-SHA256)
ikm = hkdf(b"srssly/v1/passkey-kem", prf, b"x25519", 32)
suite = b"KEM" + (0x20).to_bytes(2, "big")


def lext(salt, label, ikm):
    return H(salt or bytes(32), b"HPKE-v1" + suite + label + ikm)


def lexp(prk, label, info, L):
    li = L.to_bytes(2, "big") + b"HPKE-v1" + suite + label + info
    out, t, i = b"", b"", 1
    while len(out) < L:
        t = H(prk, t + li + bytes([i]))
        out += t
        i += 1
    return out[:L]


sk = lexp(lext(b"", b"dkp_prk", ikm), b"sk", b"", 32)
results["passkey_public"] = raw(X25519PrivateKey.from_private_bytes(sk).public_key())

# The same values are pinned in src/keys.rs and src/passkey.rs.
EXPECTED = {
    "key_check": "569b212342900e7981bf6ebcc19865bc",
    "data_key": "c3f98b38d6afda017c359a1192342d596b85d1d2f60c657fa37475df84d2c2ce",
    "auth_public": "b0745fcd50b58602711805695ec13ef10693ce25c623962a3ab9628d9f1529fc",
    "prf": "0763ce60a3fe189c114c48cf3a5ef43bbe48429e10c6384a67de5ead8a96e1f9",
    "passkey_public": "3819b8a928132364538f0874ebacc1d03b551b8e2d1c3c0af8163d0209babd3e",
}

failed = False
for name, value in results.items():
    ok = value.hex() == EXPECTED[name]
    failed |= not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name} {value.hex()}")
raise SystemExit(1 if failed else 0)
