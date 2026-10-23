# Local integration and rollback

This is an in-progress audit/correction checkpoint, not completion of the full
shipment-duty plan and not a production release. No timeseries rebuild, push,
deployment, workflow dispatch, MotherDuck write or active release change occurred.

| Repository | Original task base | Follow-up source commits | Integrated destination |
| --- | --- | --- | --- |
| tariff-rate-tracker | fca8db2c88fa11370b6dd1c291f36b03dc3bd17a | 1066b768 (audit/code), 270878a8 (logs) | `wjr_dev`: a7b5aad3510136b99acae8b60e131db8f162e2a5 |
| sail-gtx-prerelease | 2260f0787259253f810a8c5d3462ba02c9c5eb72 | 7621132c2 (coverage/claims), 2d0d25b23 (integrates concurrent base) | `pinecone-hts`: 2d0d25b23ef69949629a3d38496677f1157a7fb9 |
| sail-trade-intel-data | bb6a17f23494de60206d8cf39d8752eb9725fadc | No new evidence-pipeline changes in this follow-up | `main`: 766334b6b41dd5f45cfd3df583b7c5d53447ae1a |

All shipment working-branch commits are reachable from the requested destination
branches. The concurrent SAIL base `04b71480bfba812431150ccc9889419379aad157`
and its Chapter 99 UI change were preserved and included in affected tests.
Untracked user files in the original SAIL checkout were preserved. The working
copies remain durable worktrees under `SAIL_Engineering/sor-lanes`.

The tracker runtime is generated from SAIL's shared `shipmentRules.ts`; its source
SHA and identical 38-case conformance fixture tie the two implementations. The
normalized extension, claim/coverage contract, evidence hashes, legal findings,
test limits and manual rebuild commands are recorded in the neighboring report
and tracker documentation. A valid evidence snapshot and complete rule compilation
are still release dependencies; the audit snapshot is not a production database.

For a local code rollback, preserve any subsequent work first. Revert tracker
merge `a7b5aad3510136b99acae8b60e131db8f162e2a5` with `git revert -m 1`.
In SAIL, revert **7621132c2** to remove only this coverage/claim change; do not
revert the integration merge in a way that removes the concurrently edited panel.
No live data rollback is necessary because no live data changed. A future approved
release must retain its previous active release identifier for rollback.
