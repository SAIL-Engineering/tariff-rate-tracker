# Individual Commerce exclusion decisions

`src/section232_grants.py` consumes **reviewed decision evidence**, not a list of
HTS associations or a successful search response. The public Commerce extract
is unavailable as of this audit (the official linked Azure application returns
403, “web app is stopped”). No real individual grant was acquired or approved by
this change. The checked-in grants under `tests/fixtures/section232_grants` are
synthetic regression records and must never be used for a production build.

## Evidence contract

A `sail.section232-grants/v1` snapshot contains `snapshot_id`, offset-bearing
`as_of`, `sources`, and `grants`. Each source has `id`, snapshot-relative `path`,
SHA256, primary `url`, and `citation`. Paths cannot escape the snapshot directory.
The loader checks every artifact, every field citation and the review hash. Source
acquisition/extraction belongs in the trade-intelligence evidence pipeline; this
is its reproducible interchange boundary, not a replacement production database.

Each grant has these **required** fields, including explicit nulls:

| Fields | Meaning |
|---|---|
| `id`, `metal`, `grant_type` | Decision identifier, steel/aluminum, individual/EU STX |
| `hts10`, `countries`, `importers` | Exact statistical products, explicit Census-origin inventory, approved party identities |
| `product_description` | Full product conditions, including dimensions/chemistry and other grant limits |
| `activated_at` | Verified activation, not signature date plus five calendar days |
| `entry_from`, `entry_until` | Reviewed entry interval; start inclusive, end exclusive |
| `quantity`, `quantity_unit` | Positive authorized volume, in kg or metric tons; no unlimited default |
| `actions` | Explicit `ordinary_metal` and/or separately verified `russian_aluminum` authorization |
| `superseded_at`, `revoked_at` | Offset-bearing operative cutoff or explicit null, with evidence |
| `field_evidence` | For every field above, source ID, locator and verbatim retained quote |
| `review_status`, `reviewed_by`, `review_sha256` | Verified interpretation and its content integrity pin |

`review_sha256` is SHA256 of UTF-8 Python canonical JSON
(`json.dumps(..., sort_keys=True, separators=(',', ':'))`) containing the fields
listed by `section232_grants.FIELDS` plus `field_evidence`. It detects changes
after review; **it is not proof that the legal interpretation is correct**.
Matching a quote likewise does not replace review of its meaning. Missing
decisions, unreviewed meanings, duplicated/unreconciled versions, broad HTS8
associations, changed sources and missing fields fail validation.

The loader does not infer worldwide origin permission, a standard one-year
expiry, quantity remaining, a successor HTS code, or Russian-action relief.
Duplicate decision IDs must be reconciled upstream with their correction chain;
the snapshot cannot silently select the latest or largest allowance. The present
compiler stops the earlier decision at an evidenced correction/revocation
instant; independently establishing replacement treatment remains necessary.

## Shipment evaluation and chronology

The legacy metal compiler accepts `SECTION232_GRANT_SNAPSHOT` (an absolute path)
or the R `grant_snapshot` argument. It embeds the snapshot hash and original
decision/policy source references in the emitted fragment. Composition retains
the pin in `evidence_dependencies.section232_grants`. The original snapshot is a
hashed source artifact. Release preparation rejects grant rules without that
pin, mismatched rule identities, and different grant snapshots across revisions.
This supplements the release's existing trade-intelligence evidence pin.

The claim is `section232:grant:<id>`. Only matched grant rules offer it. Relevant
inputs are approved importer identity, satisfaction of every product limit,
quantity on this entry line, previously consumed grant quantity, and confirmation
that utilization has been reconciled. A partially covered entry line must be
split. Neither an exclusion number nor a modeled share establishes entitlement.

The grant's zero action is **priced and validated** before it can suppress a
metal action. An applicability-only dependency would skip quantity constraints
and is insufficient. The dependency on actual metal liability remains intact:
after June 4, removing metal duty can revive Canada/Mexico emergency duty, which
a qualifying USMCA claim may then remove. Section 301 remains independent.

Pre-March reporting reuses the CBP quota/exclusion decisions, including no metal
heading for EU steel, 9903.81.80 for Japanese/UK steel, and the aluminum exclusion
headings. Post-March duty exclusions require the product exclusion identifier
instead of the charged metal heading (CATAIR ESF-194); the grant identifier is
retained on its rule/decision and in the claim label and citations.

The application cutoff is extracted from the retained BIS guidance. Ordinary
activated grants can survive March 12 through their evidenced expiry/volume;
EU STX extensions stop at the country-arrangement termination instant extracted
from Proclamation 10896. Corrections and revocations can cut an interval inside
an HTS revision. The compiler does not apply a later activation retroactively to
an earlier at-entry calculation; refund analysis is outside this path.

## Authority boundaries

An ordinary grant does not remove the separate Russian-aluminum action.
GSP/AGOA eligibility can change when Section 232 is excluded. Accordingly,
`unchanged_claims` may limit base targets through `target_base_treatments`:
only reviewed `base_treatment: column1_general` or `column2` rules qualify.
An untagged or preference-sensitive base rule stays “Claim not priced” until its
interaction is compiled. A tag must describe the actual rule, not be added to
bypass this check. Reciprocal IEEPA, Section 122, Chapter 98, other Section 232
actions, and revised post-April-2026 metal/grant interactions are not attested by
this compiler. They do not inherit a blanket independence statement.

No authority coverage is granted automatically, and no complete total is
certified by these fixtures. The normalized/rule bundle remains v1, release v6;
changed rules require a new dataset version and recomposition before publication.

## Local validation

```sh
python3 src/section232_grants.py /absolute/path/to/reviewed-snapshot/snapshot.json
Rscript tests/test_s232_grants.R
node --test frontend/tests/shipment-grants.test.mjs frontend/tests/shipment-release.test.mjs
```

After a real snapshot has been exported and reviewed, set
`SECTION232_GRANT_SNAPSHOT` before the manual build in
`docs/shipment-duty-manual-rebuild.md`. A missing/corrupt configured snapshot
fails the build. Omitting it preserves explicit unavailable individual claims;
it does not manufacture a grant. No MotherDuck connection or write occurs in
the snapshot validator or compiler.
