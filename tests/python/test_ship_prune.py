"""sail_gtx_commit._prune_old_revisions: newest N per series, by number, and
language variants pruned with their own series instead of outliving it."""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"))

import sail_gtx_commit as sgc  # noqa: E402

NAMES = [
    "tw_2026_revision_729.json", "tw_2026_revision_910.json",
    "tw_2026_revision_1029.json", "tw_2026_revision_1106.json",
    "tw_2026_revision_729.zh.json", "tw_2026_revision_910.zh.json",
    "tw_2026_revision_1029.zh.json", "tw_2026_revision_1106.zh.json",
    "eu_2026_revision_9.json", "eu_2026_revision_10.json", "eu_2026_revision_11.json",
    "eu_2026_revision_9.de.json", "eu_2026_revision_11.de.json",
    "vn_2026_revision_405.vi.json", "vn_2026_revision_405.json",
]


def test_prunes_by_number_and_takes_language_variants_along(tmp_path):
    data = tmp_path / "server" / "data" / "hts"
    data.mkdir(parents=True)
    for n in NAMES:
        (data / n).write_text("{}")
    for cmd in (["git", "init", "-q"], ["git", "add", "-A"],
                ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                 "commit", "-q", "-m", "seed"]):
        subprocess.run(cmd, cwd=tmp_path, check=True)
    removed = sgc._prune_old_revisions(str(tmp_path), ["server/data/hts/x.json"], keep=2)
    left = sorted(p.name for p in data.iterdir())
    assert sorted(Path(r).name for r in removed) == sorted([
        "tw_2026_revision_729.json", "tw_2026_revision_910.json",
        "tw_2026_revision_729.zh.json", "tw_2026_revision_910.zh.json",
        "eu_2026_revision_9.json"])
    assert "eu_2026_revision_9.de.json" in left       # keep=2 of the de series
    assert {"vn_2026_revision_405.json", "vn_2026_revision_405.vi.json"} <= set(left)
