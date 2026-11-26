"""Independent reference for the known-answer tests in srssly-keys.

Run with `python3 scripts/known_answers.py` (needs the `cryptography` package).
It reimplements the key derivations from their specs, so the Rust tests are
not checked against themselves.
"""

import hashlib
import hmac

H = lambda k, m: hmac.new(k, m, hashlib.sha256).digest()


def hkdf(salt, ikm, info, n):
    prk = H(salt, ikm)
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = H(prk, t + info + bytes([i]))
        out += t
        i += 1
    return out[:n]


root = bytes(range(32))
acct = bytes([7] * 16)
salt = b"srssly/v1/root/" + acct
results = {
    "key_check": hkdf(salt, root, b"key-check", 16),
}

# The same values are pinned in the Rust tests.
EXPECTED = {
    "key_check": "7d745637d079f47074bfa7e55b88b32e",
}

failed = False
for name, value in results.items():
    ok = value.hex() == EXPECTED[name]
    failed |= not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name} {value.hex()}")
raise SystemExit(1 if failed else 0)
