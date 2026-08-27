"""Acquisition adapters: one per upstream source, all emitting AcquireResult.

The contract is the seven KEY=VALUE lines latest_revision.R already prints,
plus provenance. resolve() is READ-ONLY and always runs (a resumed run needs
the revision facts even when the fetch is skipped); fetch() does the network
work and is the body of the `acquire` step.
"""
from __future__ import annotations

from dataclasses import dataclass, asdict, field


@dataclass
class AcquireResult:
    rev_id: str                 # e.g. 2026_rev_17
    year: int
    rev_num: int | str          # int, or 'basic' for US basic editions
    effective_date: str         # ISO date
    effective_date_label: str   # e.g. "August 1, 2026"
    source_csv: str             # path to the corpus source file
    source_json: str = ""       # raw dataset (US only today)
    source_url: str = ""
    source_sha256: str = ""
    acquired_at: str = ""
    # Adapter-specific extra artifact paths, merged into the run context
    # (e.g. the EU duties/geo workbooks for build_duty_rates.py).
    extras: dict = field(default_factory=dict)

    def as_env_lines(self) -> str:
        return "\n".join([
            f"REV_ID={self.rev_id}",
            f"YEAR={self.year}",
            f"REV_NUM={self.rev_num}",
            f"EFFECTIVE_DATE={self.effective_date}",
            f"EFFECTIVE_DATE_LABEL={self.effective_date_label}",
            f"CSV_PATH={self.source_csv}",
            f"JSON_PATH={self.source_json}",
        ])

    def as_dict(self) -> dict:
        return asdict(self)


def get_adapter(name: str):
    # Imported lazily so a missing optional dependency (bs4, openpyxl) only
    # breaks the adapter that needs it, never the orchestrator.
    if name == "usitc":
        from . import usitc as mod
    elif name == "manual":
        from . import manual as mod
    elif name == "cbsa":
        from . import cbsa as mod
    elif name == "eu_taric":
        from . import eu_taric as mod
    else:
        raise SystemExit(f"ERROR: unknown acquisition adapter {name!r}")
    return mod
