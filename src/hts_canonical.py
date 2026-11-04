"""Canonical HTS10 identity, shared by the executable-rule compilers.

An HTS8 line with no statistical children IS the tariff line, so
normalize_hts() (src/helpers.R) pads it to ten digits with 00 and
04_parse_products.R keeps it on that basis. Every product reaching a compiler
therefore carries the padded form. A validator that builds its revision-valid
set from the schedule's literal htsno values rejects those lines unless it
applies the same rule -- which cost 2025_rev_1 and 2025_rev_2 a whole revision
each. ieepa_reciprocal_rules.py carried the rule alone; it is stated here once
so the next compiler inherits it instead of rediscovering it.
"""
from __future__ import annotations


def revision_valid_hts10(codes) -> set[str]:
    """The ten-digit codes of a revision, including padded HTS8 leaves.

    `codes` is any iterable of htsno values, dotted or not. An HTS8 that does
    have statistical children is a grouping row, not a product, so its padded
    form is deliberately absent.
    """
    flat = {c.replace('.', '') for c in codes if c}
    ten = {c for c in flat if len(c) == 10}
    statistical_parents = {c[:8] for c in ten}
    return ten | {c + '00' for c in flat
                  if len(c) == 8 and c not in statistical_parents}
