# Read-only MotherDuck metals reconciliation

`motherduck.json.gz` records the read-only `duty_calculator` audit from
2026-10-23T19:29:54Z through 19:31:30Z. The decompressed snapshot SHA256 is
`e29cb7803286be426d1ea7fcae69f48e0510a03f795bcbe0230a7a7873a3648f`.
No database writes or active-release changes were made.

The 346,616 grouped scope observations represent 83,187,840 stored rows across
the 17 post-April revisions and 240 origins. Comparing the then-current source
extraction against the stored annex/metal classifications found:

| Finding | Stored rows |
|---|---:|
| Different scope or ordinary tier | 2,024,160 |
| Missing or different complete metal-list membership | 648,480 |

The independent action-attribution sweep covered 267,714,240 rows across all
55 revisions and 240 origins. It found 2,278 disagreements between the Section
232 total and its action columns, and 253,717 positive statutory Section 232
rows without a reporting code. These are structural/source findings, **not**
overpayment counts or independently verified complete duty totals.

`comparison/report.json` records the extractor/script versions used for that
comparison. The later conditional-heading compiler is documented in
[the reporting-heading investigation](../2026-10-23-reporting-headings/README.md).
Retaining the earlier audit's hashes makes its provenance explicit rather than
silently rewriting the evidence after changing the extractor.

The revised calculation uses the exact source lists, preserves overlapping metal
memberships, and clears stale model-action allocations when the new regime
replaces them. Signed unattributed model residuals remain visible and cannot
certify a shipment total. Actual statutory headings and amounts come from the
conditional rule fragment when its shipment facts and source conditions resolve.

Reproduce a fresh source comparison without a rate build:

```sh
python3 scripts/audit_s232_note16.py --out output/new-note16-comparison \
  --snapshot docs/audits/2026-10-23-note16-scope/motherduck.json.gz
```

The full manual rebuild and aggregate before/after reconciliation remain pending.
