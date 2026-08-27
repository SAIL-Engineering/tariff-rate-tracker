"""Source-row conservation: every coded source row reaches the tree, and the
tree invents nothing. This is the strongest intra-build 'no code is missed'
guarantee and it must hold on every fixture and both source formats."""
from conftest import build


def _assert_conserved(b):
    assert b.stats.coded_digits == set(b.nodes)


def test_usitc_slices_conserve_rows(fixtures, us_chapters):
    for name in ("us_rev17_0101_slice.csv", "us_rev17_0103_slice.csv",
                 "us_rev17_3004_slice.csv"):
        _assert_conserved(build(fixtures / name, us_chapters))


def test_cbsa_slices_conserve_rows(fixtures, ca_chapters):
    for name in ("ca_ch99_orphan_slice.csv", "ca_dupe_slice.csv"):
        _assert_conserved(build(fixtures / name, ca_chapters,
                                source_format="cbsa", jurisdiction="CA"))


def test_missing_direction_detects_loss(fixtures, us_chapters):
    """The comparison must catch a coded source row absent from the tree."""
    b = build(fixtures / "us_rev17_0101_slice.csv", us_chapters)
    b.stats.coded_digits.add("9999999999")  # simulate a row the tree lost
    missing = sorted(b.stats.coded_digits - set(b.nodes))
    assert missing == ["9999999999"]


def test_extra_direction_detects_invention(fixtures, us_chapters):
    """...and a tree node with no source row."""
    b = build(fixtures / "us_rev17_0101_slice.csv", us_chapters)
    extra = sorted((set(b.nodes) | {"8888888888"}) - b.stats.coded_digits)
    assert extra == ["8888888888"]
