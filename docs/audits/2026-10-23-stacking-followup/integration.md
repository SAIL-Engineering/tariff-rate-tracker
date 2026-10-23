# Local integration and rollback

Tracker base before this pass: `d250a0e12d453d38c9c9af4de8b76146103b983f`.
Implementation commit: `923f96ca23b229c9171f70a32ff4dbaa7dd58547`.
Local merge into `wjr_dev`: `143343dd45936b4679d9c62bbd8706f8da325247`.
Original task base remains `fca8db2c88fa11370b6dd1c291f36b03dc3bd17a`.

The implementation is reachable from the requested destination branch. The
worktree branch is retained for continued work and aligned after integration.
No changes to the Trade Intelligence or SAIL repositories were made in this pass.
Nothing was pushed, deployed, dispatched or published. MotherDuck was read-only.

The versioned aggregate corrections are identified by `stacking_model_version=2`
and `stacking_era_id`. Semiconductor outputs add published conditional-rate,
model-share/calibration and missing-fact/source fields. Unknown statutory rates
and totals remain null. These wide fields do not by themselves qualify the
complete shipment API or any legacy consumer. Full rule compilation, normalized
parity and serving-path integration remain release gates.

No timeseries rebuild was run. WJR's exact commands remain in
[the manual rebuild runbook](../../shipment-duty-manual-rebuild.md).

If rollback is required locally, review and run from a clean tracker `wjr_dev`:

```sh
git revert -m 1 143343dd45936b4679d9c62bbd8706f8da325247
```

Do not reset or overwrite later unrelated work. This revert is not executed by
this handoff. No production rollback is needed because no production release
changed. A later approved release must retain its prior active identifier as
specified in the release tooling.
