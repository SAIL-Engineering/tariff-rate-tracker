"""The Pinecone record schema is a cross-repo contract.

Every jurisdiction MUST emit exactly these fields (sail-gtx-prerelease
`server/src/plugins/pinecone.ts` RETURN_FIELDS projects a subset of them, and
the classification prompt renders display_text). A field added or removed here
without a coordinated consumer change is a production incident — this test is
the tripwire. The schema is identical for every jurisdiction by design
(user requirement 2026-08-27).
"""
from conftest import build

# The exact contract. chunk_text is embedded; everything else lands in Pinecone
# metadata. Order-insensitive: JSON objects don't guarantee order.
EXPECTED_FIELDS = {
    "_id", "chunk_text", "display_text", "code", "chapter", "heading",
    "subheading", "depth", "unit", "is_basket", "jurisdiction", "revision",
    "kind",
}

# Fields sail-gtx's RETURN_FIELDS requests (minus chunk_text which it also
# projects). Must stay a subset of what we emit.
CONSUMER_RETURN_FIELDS = {
    "chunk_text", "display_text", "code", "chapter", "heading", "subheading",
    "depth", "unit", "is_basket", "revision", "jurisdiction",
}


def test_every_record_has_exactly_the_contract_fields(fixtures, us_chapters, ca_chapters):
    for name, chapters, fmt, jur in (
        ("us_rev17_0101_slice.csv", us_chapters, "usitc", "US"),
        ("ca_dupe_slice.csv", ca_chapters, "cbsa", "CA"),
    ):
        b = build(fixtures / name, chapters, source_format=fmt, jurisdiction=jur)
        for r in b.records:
            assert set(r) == EXPECTED_FIELDS, f"{name}: {set(r) ^ EXPECTED_FIELDS}"


def test_consumer_return_fields_are_a_subset():
    assert CONSUMER_RETURN_FIELDS <= EXPECTED_FIELDS


def test_golden_record_snapshot(fixtures, us_chapters):
    """One full record, asserted verbatim. Exercises basket expansion (Other),
    condition-chain folding (Horses:), the id scheme, and both text forms."""
    b = build(fixtures / "us_rev17_0101_slice.csv", us_chapters,
              jurisdiction="US", revision="2026_rev_17")
    r = b.by_code["0101.29.00.90"]
    assert r == {
        "_id": "US|2026_rev_17|0101290090",
        "chunk_text": "Live animals > Live horses, asses, mules and hinnies > "
                      "Horses > Other, other than: Purebred breeding animals > "
                      "Other, other than: Imported for immediate slaughter",
        "display_text": "0101.29.00.90 = 01 Live animals | 0101 Live horses, "
                        "asses, mules and hinnies | 0101.29.00 Other | "
                        "0101.29.00.90 Other",
        "code": "0101.29.00.90",
        "chapter": "01",
        "heading": "0101",
        "subheading": "010129",
        "depth": 10,
        "unit": "No.",
        "is_basket": True,
        "jurisdiction": "US",
        "revision": "2026_rev_17",
        "kind": "line",
    }
