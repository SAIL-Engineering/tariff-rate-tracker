/*
 * rate-response.ts
 *
 * Runtime validator for the /api/rates ProductRate response shape. Hand-
 * written (no zod / yup / ajv dependency) so the frontend bundle stays
 * lean — ~60 lines of straight predicates check all 58 fields. When a
 * new field is added to ProductRate in tariff.ts, add it to the checks
 * below or the contract drifts silently.
 *
 * Used two ways:
 *   1. Phase 2.5c scaffolding — imported by the Phase 3 cutover to gate
 *      responses from the normalized gapfill path. Violations throw in
 *      development and log-and-continue in production.
 *   2. Test fixtures — validate hand-authored ProductRate literals in
 *      unit tests so the type contract stays in sync with the backend.
 *
 * See docs/adrs/001-denorm-state-pattern.md for the architectural
 * context (the denorm_state contract on the R side is the mirror of
 * this validator on the TS side).
 */

import type { ProductRate } from './tariff';

type ValidationError = { path: string; expected: string; got: unknown };

const isString = (v: unknown): v is string => typeof v === 'string';
const isNumber = (v: unknown): v is number => typeof v === 'number' && !Number.isNaN(v);
const isBoolean = (v: unknown): v is boolean => typeof v === 'boolean';
const isNullableString = (v: unknown): v is string | null =>
  v === null || typeof v === 'string';
const isNullableNumber = (v: unknown): v is number | null =>
  v === null || (typeof v === 'number' && !Number.isNaN(v));

/**
 * Required rate columns — every authority's effective and statutory rate.
 * ProductRate guarantees these are non-null numbers; the R pipeline
 * defaults to 0 when an authority doesn't apply.
 */
const RATE_FIELDS = [
  'base_rate',
  'statutory_base_rate',
  'rate_232',
  'rate_301',
  'rate_ieepa_recip',
  'rate_ieepa_fent',
  'rate_s122',
  'rate_section_201',
  'rate_other',
  'statutory_rate_232',
  'statutory_rate_301',
  'statutory_rate_ieepa_recip',
  'statutory_rate_ieepa_fent',
  'statutory_rate_s122',
  'statutory_rate_section_201',
  'statutory_rate_other',
  'metal_share',
  'steel_share',
  'aluminum_share',
  'copper_share',
  'other_metal_share',
  'total_additional',
  'total_rate',
] as const;

const NULLABLE_CH99_FIELDS = [
  'ch99_code_232',
  'ch99_code_301',
  'ch99_code_ieepa_recip',
  'ch99_code_ieepa_fent',
  'ch99_code_s122',
  'ch99_code_s201',
] as const;

/**
 * 2026 authority rates — number when present, `undefined` on data that predates
 * them. Deliberately NOT in RATE_FIELDS: that group is validated as
 * required-non-null, so listing them there would fail every row served from a
 * pre-2026 rebuild (resolveRatesProjection drops columns the parquets lack, so
 * the API omits them entirely rather than sending 0).
 *
 * Move these into RATE_FIELDS once every served vintage carries them — i.e. after
 * the 2025-01-01-onward rebuild is pushed — so the contract tightens back to
 * required.
 *
 *   rate_s301fl  §301 forced labor, 60 economies (91 FR 47318 / 91 FR 47717,
 *                eff. 2026-07-24). Rolls up to authority 'section_301'.
 *   rate_s301br  §301 Brazil (91 FR 45516, eff. 2026-07-22). Also rolls up to
 *                'section_301' — an origin can owe BOTH, e.g. Brazil pays 25%
 *                under note 50 plus 12.5% under note 52.
 *   rate_s338    §338 Canada (19 U.S.C. 1338, eff. 2026-08-19). Its own statute,
 *                its own ETR line.
 */
const OPTIONAL_RATE_FIELDS = [
  'rate_s301fl',
  'rate_s301br',
  'rate_s338',
] as const;

const STRING_FIELDS = [
  'hts10',
  'country',
  'rate_basis',
  'rounding_rule',
  'calc_status',
  'revision',
  'effective_date',
  'valid_from',
  'valid_until',
] as const;

const NULLABLE_STRING_FIELDS = [
  'deriv_type',
  's232_annex',
  'rate_special_raw',
  'special_programs_json',
  'rate_column2_raw',
  'specific_rate_unit',
  'reported_unit_1',
  'reported_unit_2',
  'duty_basis_unit',
  'quantity_source',
] as const;

const NULLABLE_NUMBER_FIELDS = [
  'rate_special',
  'rate_column2',
  'specific_amount',
] as const;

const BOOLEAN_FIELDS = [
  'is_copper_heading',
  'usmca_eligible',
  'is_qty_duty_relevant',
] as const;

export interface ProductRateValidationResult {
  ok: boolean;
  errors: ValidationError[];
}

/**
 * Validate an unknown value as a ProductRate row. Returns a result with
 * every violation listed — use this in dev for full diagnostics, or
 * wrap in assertProductRate() when you just want a boolean type guard.
 */
export function validateProductRate(value: unknown): ProductRateValidationResult {
  const errors: ValidationError[] = [];
  if (value === null || typeof value !== 'object') {
    return { ok: false, errors: [{ path: '', expected: 'object', got: value }] };
  }
  const obj = value as Record<string, unknown>;

  for (const field of STRING_FIELDS) {
    if (!isString(obj[field])) {
      errors.push({ path: field, expected: 'string', got: obj[field] });
    }
  }
  for (const field of RATE_FIELDS) {
    if (!isNumber(obj[field])) {
      errors.push({ path: field, expected: 'number', got: obj[field] });
    }
  }
  for (const field of OPTIONAL_RATE_FIELDS) {
    const v = obj[field];
    if (v !== undefined && !isNumber(v)) {
      errors.push({ path: field, expected: 'number | undefined', got: v });
    }
  }
  for (const field of NULLABLE_CH99_FIELDS) {
    // ch99 fields are optional on the type — undefined is allowed
    const v = obj[field];
    if (v !== undefined && !isNullableString(v)) {
      errors.push({ path: field, expected: 'string | null | undefined', got: v });
    }
  }
  for (const field of NULLABLE_STRING_FIELDS) {
    if (!isNullableString(obj[field])) {
      errors.push({ path: field, expected: 'string | null', got: obj[field] });
    }
  }
  for (const field of NULLABLE_NUMBER_FIELDS) {
    if (!isNullableNumber(obj[field])) {
      errors.push({ path: field, expected: 'number | null', got: obj[field] });
    }
  }
  for (const field of BOOLEAN_FIELDS) {
    if (!isBoolean(obj[field])) {
      errors.push({ path: field, expected: 'boolean', got: obj[field] });
    }
  }

  // __synthesized is @deprecated and optional. Warn at runtime (not an
  // error) so Phase 3d can detect lingering usage. Stripped from the
  // type definition in Phase 3d.
  if ('__synthesized' in obj && !isBoolean(obj.__synthesized) && obj.__synthesized !== undefined) {
    errors.push({
      path: '__synthesized',
      expected: 'boolean | undefined (deprecated, removal in Phase 3d)',
      got: obj.__synthesized,
    });
  }

  return { ok: errors.length === 0, errors };
}

/**
 * Type guard — returns true when the value validates cleanly. Does not
 * throw. Use this when you want a boolean in a filter or type narrow.
 */
export function isProductRate(value: unknown): value is ProductRate {
  return validateProductRate(value).ok;
}

/**
 * Assertion — throws with a detailed error list on mismatch. Use this
 * in dev mode to catch contract violations loudly, or wrap in a
 * try/catch with log-and-continue in production.
 */
export function assertProductRate(value: unknown, context = 'ProductRate'): asserts value is ProductRate {
  const result = validateProductRate(value);
  if (!result.ok) {
    const summary = result.errors
      .slice(0, 10)
      .map((e) => `  ${e.path}: expected ${e.expected}, got ${typeof e.got === 'object' ? JSON.stringify(e.got) : String(e.got)}`)
      .join('\n');
    const extra = result.errors.length > 10 ? `\n  ... and ${result.errors.length - 10} more` : '';
    throw new Error(`${context} validation failed:\n${summary}${extra}`);
  }
}

/**
 * Validate an array of ProductRate rows. Returns the array typed when
 * every row passes. Used by the /api/rates response handler in Phase 3.
 */
export function validateProductRateArray(value: unknown): ProductRate[] {
  if (!Array.isArray(value)) {
    throw new Error(`Expected array of ProductRate, got ${typeof value}`);
  }
  value.forEach((row, i) => assertProductRate(row, `ProductRate[${i}]`));
  return value as ProductRate[];
}
