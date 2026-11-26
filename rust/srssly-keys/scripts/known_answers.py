"""Independent reference for the known-answer tests in srssly-keys.

Run with `python3 scripts/known_answers.py` (needs the `cryptography` package).
It reimplements the key derivations from their specs, so the Rust tests are
not checked against themselves.
"""

import hashlib
import hmac

from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

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
results = {
    "key_check": hkdf(salt, root, b"key-check", 16),
    "data_key": hkdf(salt, root, b"data-key", 32),
    "auth_public": raw(
        Ed25519PrivateKey.from_private_bytes(hkdf(salt, root, b"auth-key", 32)).public_key()
    ),
    "ctap_salt": hashlib.sha256(b"WebAuthn PRF\x00" + b"srssly/v1/passkey-prf").digest(),
}
results["prf"] = H(bytes([9] * 32), results["ctap_salt"])

# The same values are pinned in the Rust tests.
EXPECTED = {
    "key_check": "569b212342900e7981bf6ebcc19865bc",
    "data_key": "c3f98b38d6afda017c359a1192342d596b85d1d2f60c657fa37475df84d2c2ce",
    "auth_public": "b0745fcd50b58602711805695ec13ef10693ce25c623962a3ab9628d9f1529fc",
    "prf": "0763ce60a3fe189c114c48cf3a5ef43bbe48429e10c6384a67de5ead8a96e1f9",
    "ctap_salt": "09cfa2c104ea19b7a59f9472b2b6fd18194db1b560fa3bff1add23bfdd921a42",
}

failed = False
for name, value in results.items():
    ok = value.hex() == EXPECTED[name]
    failed |= not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name} {value.hex()}")
raise SystemExit(1 if failed else 0)
