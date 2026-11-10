-- Additive column backfill for main.rates. Apply with explicit approval.
--
-- WHY: the incremental push does `INSERT INTO rates BY NAME SELECT *` over the
-- local parquet union. BY NAME requires the SELECT's columns to be a SUBSET of
-- the table's; any local column the cloud lacks raises
--   Binder Error: Table "rates" does not have a column with name "..."
-- and the revision's transaction rolls back. The cloud table had drifted behind
-- the parquet generation, so the push could not start at all.
--
-- Preflight on 2026-11-10 (scripts/check-motherduck-schema.mjs, read-only):
--   local parquet union: 188 columns
--   cloud main.rates   :  96 columns
--   added here         :  92 columns
-- 96 + 92 = 188, so every existing cloud column also exists locally:
-- this migration only ADDS, and the push drops nothing.
--
-- CORRECTION (2026-11-10, after a partial run): "metadata only" is TRUE in local
-- DuckDB and FALSE on MotherDuck. Each ADD COLUMN there materialises the table,
-- so on `rates` (~613M rows) each statement took ~8.5s and the 29th failed with
--   Out of Memory Error: failed to offload data block (67.0 GiB/67.0 GiB used).
--   Consider using a larger duckling size than Pulse
-- having applied 28. Every added column makes the next one costlier, so the cost
-- grows through the file. No value was changed and nothing was corrupted.
--
-- IF NOT EXISTS still makes the file re-runnable, and that is the recovery: a
-- fresh process gets a fresh memory budget and skips the already-applied columns
-- as no-ops. Expect to run it more than once. If a single statement cannot
-- complete even in a fresh session, use the FULL REBUILD path instead
-- (push-to-motherduck.mjs with no --revision/--only-revisions): seedTable()
-- creates the table from the parquet union with LIMIT 0, which reads parquet
-- metadata only, so it reaches the correct 188-column schema in ONE cheap
-- statement and needs none of these ALTERs.
--
-- NOTE ON NUMBERING: the shipment-duty plan reserves "003" for renaming the live
-- objects to main.aggregate_rates / aggregate_product_base_rates, to be applied
-- LAST. This file is applied first, so that rename becomes 004.

-- DOUBLE (46) -- rate and share columns
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "rate_s301_maritime" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "statutory_rate_s301_maritime" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_s301_scope_share" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_s301_maritime_scope_share" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_s232_unattributed_rate" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_s232_uk_metal_origin_qualification" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_ieepa_reciprocal_parameter" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_ieepa_reciprocal_rate" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_ieepa_country_eo_rate" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_auto_credit" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_auto_assembly_share" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_auto_credit_rate" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_s122_exempt_share" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_mfn_exemption_share" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "usmca_share" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_base_rate" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_232_auto" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_232_steel" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_232_aluminum" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_232_copper" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_232_other" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_s301fl" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_s301br" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_s301_maritime" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_s338" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_total_additional" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_total_rate" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_232" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_ieepa_recip" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_ieepa_fent" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_301" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_s122" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_section_201" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_other" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "published_rate_232_semiconductors" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_semi_qualifying_share" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_semi_end_use_exemption_share" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "statutory_rate_s338_alcohol" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_rate_s338_alcohol" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "statutory_rate_s338_dairy" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_rate_s338_dairy" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "statutory_rate_s338_motor_vehicles" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_rate_s338_motor_vehicles" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_s338_alcohol" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_s338_dairy" DOUBLE;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_rate_s338_motor_vehicles" DOUBLE;

-- VARCHAR (40) -- codes, statuses and JSON payloads
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "ch99_code_s301_maritime" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "s232_action_attribution_status" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_s232_residual_action" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "s232_note16_status" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "s232_note16_lists_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "s232_note16_metals_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "s232_legacy_status" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "ieepa_selected_actions_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "ch99_src_ieepa_country_eo" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "ch99_src_ieepa_fent" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "stacking_era_id" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_duty_provenance_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_rules_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_s232_suppressed_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_pending_activation_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_legacy_statutory_alternatives_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_232" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_301" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_ieepa_recip" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_ieepa_fent" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_s122" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_s201" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_s301fl" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_s301br" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_s301_maritime" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "aggregate_ch99_code_s338" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_status" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_contract_version" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_projection_version" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_source_errors_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_dataset_version" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_evidence_snapshot_id" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_decision_ids_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_bundle_ids_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_missing_inputs_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_quote_profile" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_232_scope_status" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_232_required_facts_json" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_232_scope_source" VARCHAR;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_semi_qualifying_basis" VARCHAR;

-- BOOLEAN (5) -- flags
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "s301_scope_requires_inputs" BOOLEAN;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_s232_note16_combined_metals" BOOLEAN;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_ieepa_reciprocal_exempt" BOOLEAN;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "modeled_ieepa_duty_free" BOOLEAN;
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "shipment_exact_time_required" BOOLEAN;

-- INTEGER (1) -- versions
ALTER TABLE main.rates ADD COLUMN IF NOT EXISTS "stacking_model_version" INTEGER;
