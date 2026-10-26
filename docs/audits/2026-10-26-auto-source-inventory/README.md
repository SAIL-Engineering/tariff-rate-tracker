# Automobile source investigation in progress

This is research evidence for Task2, not a new executable automobile compiler or
an authority-coverage attestation. Current tracker base: `509aeb11`. No data was
published or written to MotherDuck. The final timeseries rebuild stays on hold.

The official Federal Register discovery query for references to Proclamation10908
within the October22,2026 publication cutoff returned120 records. This query is
not a complete legal-action inventory, and not every result changes a duty.
The exact selected IDs and URLs are retained in `official-index.json.gz`.

A READ_ONLY transaction in `trade_intel_fr.documents` reused28 matching stored
records, all with nonempty text, including the original2025-05930.92 discovery
results were not in this selected FR table; that is not a count of missing legal
amendments or proof of absence from other Trade Intelligence catalogs. The
selection records source versions/hashes, object paths, public URLs, query and
capture time, and rolled back. It is a reproducible research selection, not the
full published evidence snapshot required to pin a production build. Repeat the selection (current source versions may have changed since this audit):

```bash
zcat official-index.json.gz > /tmp/auto-index.json
node corpus-selection-query.cjs /tmp/auto-index.json /tmp/auto-corpus.json
```

The reader locates the tracker `.env` without printing credentials. It opens only
a READ_ONLY connection and a read-only transaction. Production storage remains
MotherDuck.

## Source coverage findings

Trade Intelligence's `content_sha256` is the search header/abstract hash for
Federal Register records (`chunk.content_sha256`); it is not the legal full-text
hash. `source_hash` separately covers the detail+text source payload. This
selection additionally records the exact exported full-text hash. Do not equate
these fields or substitute a successful embedding match for legal-text coverage.

The original proclamation's stored full text explicitly omits six annex graphics.
The primary official PDF was therefore retrieved through gstack. Its six annex
pages were rendered, OCRed and visually inspected. Exact bytes, metadata and
hashes are under `original/`. The native PDF text also lacks the annex image text;
OCR is a derived extraction, with the PDF retained as its authority. Original
source: [Proclamation10908](https://www.govinfo.gov/content/pkg/FR-2025-04-03/pdf/2025-05930.pdf).

## Decisions requiring executable reconciliation

Original Annex I note33(g) lists the whole8471 heading among potential automobile
parts, while33(h)(ii) covers articles in the listed provisions that are not parts
of the specified passenger vehicles/light trucks. Membership alone therefore
cannot impose the automobile tariff on every computer or machine component.
The same distinction matters to the separately sourced semiconductor action and
IEEPA exclusions. Additional use facts belong only on matched conditional rules.

The original vehicle scope also separates non-passenger articles, approved U.S.
content and vehicles manufactured in a calendar year at least25 years before the
entry year. That is a manufacture-year criterion, not a rounded elapsed-age test.
The25% ordinary vehicle/parts charges, zero-additional reporting alternatives,
USMCA/Commerce approval, punitive overstatement treatment, Chapter98 terms and
FTZ history need distinct decisions. Later country headings, combined rates,
quotas, offsets and amendments must be reconciled to original instruments before
extending these initial rules across the full history.

No tariff was changed based solely on these observations. Next implementation
must connect source-backed automobile decisions to the same ordinary bundle
assembly and evaluator, preserving claims and interactions rather than adding
another rate lookup or maximum-rate choice.
