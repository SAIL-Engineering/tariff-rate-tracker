"""Supabase keys go on `apikey`; only a legacy JWT key also goes on
`Authorization: Bearer` (https://supabase.com/docs/guides/api/api-keys)."""
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"))

import check_upstream                                   # noqa: E402
import supabase_auth                                    # noqa: E402

JWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.c2lnbmF0dXJl"
SECRET = "sb_secret_abcdefghijklmnopqrstuv"


def test_legacy_jwt_goes_on_both_headers():
    assert supabase_auth.headers(JWT) == {"apikey": JWT, "authorization": f"Bearer {JWT}"}


def test_secret_key_goes_on_apikey_only():
    h = supabase_auth.headers(SECRET, prefer="return=minimal")
    assert h == {"apikey": SECRET, "prefer": "return=minimal"}


def test_supabase_latest_sends_no_bearer_with_a_secret_key(monkeypatch):
    seen = {}

    def fake_urlopen(req, timeout):
        seen.update({k.lower(): v for k, v in req.header_items()})
        return io.BytesIO(json.dumps([{"revision_year": 2026,
                                       "revision_number": 405}]).encode())

    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", SECRET)
    monkeypatch.setattr(check_upstream.urllib.request, "urlopen", fake_urlopen)
    assert check_upstream.supabase_latest("VN") == (2026, 405)
    assert seen["apikey"] == SECRET and "authorization" not in seen
