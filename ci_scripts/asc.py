#!/usr/bin/env python3
"""
Minimal App Store Connect API client — no third-party deps.

Signs the ES256 JWT with the `openssl` CLI (PyJWT/cryptography aren't installed)
and converts openssl's DER signature into the raw r||s form JWS requires.

Credentials come from the environment — nothing about the account is hardcoded,
so this file is safe to keep in a public repo:

  ASC_KEY_ID     key id from App Store Connect -> Users and Access -> Integrations
  ASC_ISSUER_ID  issuer id from that same page (omit only for an individual key)
  ASC_KEY_PATH   optional; defaults to ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8

Usage:
  ASC_KEY_ID=... ASC_ISSUER_ID=... asc.py /v1/apps
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

KEY_ID = os.environ.get("ASC_KEY_ID")
if not KEY_ID:
    sys.exit("ASC_KEY_ID no está definido (ver el docstring de este archivo).")
KEY_PATH = os.path.expanduser(
    os.environ.get("ASC_KEY_PATH", f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
)
ISSUER_ID = os.environ.get("ASC_ISSUER_ID") or None
BASE = "https://api.appstoreconnect.apple.com"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """ECDSA DER (SEQUENCE of two INTEGERs) -> fixed 64-byte r||s for JWS."""
    if der[0] != 0x30:
        raise ValueError("not a DER SEQUENCE")
    # Skip SEQUENCE tag + length (short or long form).
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("expected DER INTEGER")
        length = der[i + 1]
        val = der[i + 2 : i + 2 + length]
        i += 2 + length
        val = val.lstrip(b"\x00")           # drop the sign padding byte
        out += val.rjust(32, b"\x00")       # left-pad to the P-256 field size
    return out


def make_jwt() -> str:
    header = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    now = int(time.time())
    payload = {"aud": "appstoreconnect-v1", "iat": now, "exp": now + 900}
    if ISSUER_ID:
        payload["iss"] = ISSUER_ID          # team key
    else:
        payload["sub"] = "user"             # individual key
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", KEY_PATH],
        input=signing_input.encode(), capture_output=True, check=True,
    ).stdout
    return f"{signing_input}.{b64url(der_to_raw(der))}"


def request(path: str, method: str = "GET", body: dict | None = None):
    url = path if path.startswith("http") else BASE + path
    headers = {"Authorization": f"Bearer {make_jwt()}"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {"status": resp.status}
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode()
        print(f"HTTP {e.code}", file=sys.stderr)
        try:
            print(json.dumps(json.loads(body_txt), indent=2), file=sys.stderr)
        except json.JSONDecodeError:
            print(body_txt, file=sys.stderr)
        sys.exit(1)


def get(path: str):
    return request(path)


if __name__ == "__main__":
    print(json.dumps(get(sys.argv[1] if len(sys.argv) > 1 else "/v1/apps"), indent=2))
