"""Request headers for the Supabase Data API, for either kind of server key.

Supabase has two kinds of server key. The legacy `service_role` key is a JWT
and has always been sent twice, as `apikey` and as `Authorization: Bearer`.
The newer secret keys (`sb_secret_...`) are not JWTs: Supabase's API-keys
guide says to "send publishable and secret keys on the `apikey` header, not on
`Authorization: Bearer`", because anything that tries to verify one as a JWT
fails. So the key always goes on `apikey`, and on `Authorization` only when it
is a JWT. https://supabase.com/docs/guides/api/api-keys
"""
from __future__ import annotations

import re

# header.payload.signature, base64url; every Supabase JWT starts '{"' -> 'eyJ'
_JWT = re.compile(r"^eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")


def is_jwt(key: str) -> bool:
    return bool(_JWT.match(key or ""))


def headers(key: str, **extra: str) -> dict[str, str]:
    """`apikey` always; `authorization` only for a legacy JWT key."""
    out = {"apikey": key}
    if is_jwt(key):
        out["authorization"] = f"Bearer {key}"
    out.update(extra)
    return out
