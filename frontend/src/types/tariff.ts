export interface Country {
  code: string;
  name: string;
  partner: string | null;
  alpha2: string | null;
  alpha3: string | null;
}

export interface RevisionEntry {
  revision: string;
  effectiveDate: string;
  policyEffectiveDate: string | null;
  policyEvent: string | null;
}

export interface DailyOverall {
  date: string;
  revision: string;
  mean_additional_exposed: number;
  mean_total_exposed: number;
  mean_additional_all_pairs: number;
  mean_total_all_pairs: number;
  n_products: number;
  n_countries: number;
  n_pairs: number;
  n_all_pairs: number;
}

export interface DailyByAuthority {
  date: string;
  revision: string;
  mean_232: number;
  mean_301: number;
  mean_ieepa: number;
  mean_fentanyl: number;
  mean_s122: number;
  mean_section_201: number;
  mean_other: number;
}

export interface DailyByCountrySummary {
  country: string;
  country_name: string;
  country_abbr: string | null;
  revision: string;
  date: string;
  mean_additional_all_pairs: number;
  mean_total_all_pairs: number;
  n_products_present: number;
}

/**
 * Rate basis classification per CBP methodology.
 * Determines how duty is calculated:
 *   ad_valorem: percent of customs value (quantity not duty-relevant)
 *   specific: fixed amount per legally specified unit of quantity
 *   compound: ad valorem + specific components
 *   free: no duty
 *   unknown: unparseable rate expression (needs manual review)
 */
export type RateBasis = 'ad_valorem' | 'specific' | 'compound' | 'free' | 'unknown';

/**
 * 19 CFR 159.3 rounding rule codes.
 * ad valorem: value rounded to even dollars
 * specific ≤$1/unit: qty fractions <0.5 disregarded, ≥0.5 = whole unit
 * specific >$1/unit: exact qty, fraction to 2 decimal places
 */
export type RoundingRule =
  | '19cfr159.3_value'
  | '19cfr159.3_specific_lte1'
  | '19cfr159.3_specific_gt1'
  | '19cfr159.3_compound_lte1'
  | '19cfr159.3_compound_gt1'
  | 'unknown';

export type CalcStatus = 'ok' | 'needs_manual_review' | 'missing_duty_basis_unit';

export interface SpecialProgramEntry {
  rate: number | null;
  rate_raw: string;
  programs: string[];
  entry_type: 'rate' | 'reference';
}

export function parseSpecialPrograms(json: string | null | undefined): SpecialProgramEntry[] {
  if (!json) return [];
  try { return JSON.parse(json); } catch { return []; }
}

export interface ProductRate {
  hts10: string;
  country: string;
  base_rate: number;
  statutory_base_rate: number;
  rate_232: number;
  rate_301: number;
  rate_ieepa_recip: number;
  rate_ieepa_fent: number;
  rate_s122: number;
  rate_section_201: number;
  rate_other: number;
  // Statutory rates — pre-scaling, pre-stacking baselines
  statutory_rate_232: number;
  statutory_rate_301: number;
  statutory_rate_ieepa_recip: number;
  statutory_rate_ieepa_fent: number;
  statutory_rate_s122: number;
  statutory_rate_section_201: number;
  statutory_rate_other: number;
  // Specific 8-digit Chapter 99 code driving each authority for this row.
  // Null when the authority is not active for this (product, country).
  // Backfilled by src/helpers.R::resolve_ch99_codes() during rate calculation.
  ch99_code_232?: string | null;
  ch99_code_301?: string | null;
  ch99_code_ieepa_recip?: string | null;
  ch99_code_ieepa_fent?: string | null;
  ch99_code_s122?: string | null;
  ch99_code_s201?: string | null;
  /**
   * Phase 1 stopgap — true when this row was synthesized server-side from
   * product_base_rates rather than pulled from the rates parquet.
   *
   * @deprecated Phase 3d removes this field once the normalized-layer
   *   gapfill path handles missing pairs natively. Do not add new call
   *   sites. The validator in `rate-response.ts` tolerates it during
   *   Phase 2.5–3 and errors on it in Phase 3d.
   */
  __synthesized?: boolean;
  metal_share: number;
  // Per-type metal shares (from BEA metal content analysis)
  steel_share: number;
  aluminum_share: number;
  copper_share: number;
  other_metal_share: number;
  // Section 232 classification
  is_copper_heading: boolean;
  /** Derivative type for 232: 'steel' | 'aluminum' | null */
  deriv_type: string | null;
  /** Section 232 annex classification */
  s232_annex: string | null;
  total_additional: number;
  total_rate: number;
  usmca_eligible: boolean;
  // Rate tiers (Column 1 General / Column 1 Special / Column 2)
  rate_special: number | null;
  rate_special_raw: string | null;
  special_programs_json: string | null;
  rate_column2: number | null;
  rate_column2_raw: string | null;
  // Rate basis and duty math fields.
  // In U.S. HTSUS, quantity affects duty only when the legal rate is specific
  // or compound. The "Unit of Quantity" on a 10-digit statistical reporting
  // number is often required for reporting but is NOT the legal basis of duty.
  rate_basis: RateBasis;
  specific_amount: number | null;
  /** Unit from the legal rate expression (e.g., "kg" from "30.5¢/kg + 8.5%") */
  specific_rate_unit: string | null;
  /** Statistical reporting units (nonlegal — for entry documents, not duty math) */
  reported_unit_1: string | null;
  reported_unit_2: string | null;
  /** Unit that drives duty calculation (= specific_rate_unit when specific/compound; null for ad valorem) */
  duty_basis_unit: string | null;
  /** TRUE only when rate_basis is 'specific' or 'compound' */
  is_qty_duty_relevant: boolean;
  /** Where duty_basis_unit was derived from: 'rate_text', 'chapter_note', or null */
  quantity_source: string | null;
  /** 19 CFR 159.3 rounding rule code */
  rounding_rule: RoundingRule;
  /** Calculation readiness: 'ok', 'needs_manual_review', 'missing_duty_basis_unit' */
  calc_status: CalcStatus;
  // Metadata
  revision: string;
  effective_date: string;
  valid_from: string;
  valid_until: string;
}

/** Map from effective rate key to its statutory counterpart */
export type StatutoryKey =
  | 'statutory_rate_232'
  | 'statutory_rate_301'
  | 'statutory_rate_ieepa_recip'
  | 'statutory_rate_ieepa_fent'
  | 'statutory_rate_s122'
  | 'statutory_rate_section_201'
  | 'statutory_rate_other';

export const STATUTORY_KEY_MAP: Record<AuthorityKey, StatutoryKey> = {
  rate_232: 'statutory_rate_232',
  rate_301: 'statutory_rate_301',
  rate_ieepa_recip: 'statutory_rate_ieepa_recip',
  rate_ieepa_fent: 'statutory_rate_ieepa_fent',
  rate_s122: 'statutory_rate_s122',
  rate_section_201: 'statutory_rate_section_201',
  rate_other: 'statutory_rate_other',
};

/** Returns true if the statutory rate differs from the effective rate for a given authority */
export function hasStatutoryDelta(rate: ProductRate, key: AuthorityKey): boolean {
  const statutoryKey = STATUTORY_KEY_MAP[key];
  const statutory = rate[statutoryKey] ?? 0;
  const effective = rate[key] ?? 0;
  return statutory > 0 && Math.abs(statutory - effective) > 0.00001;
}

export type AuthorityKey =
  | 'rate_232'
  | 'rate_301'
  | 'rate_ieepa_recip'
  | 'rate_ieepa_fent'
  | 'rate_s122'
  | 'rate_section_201'
  | 'rate_other';

export interface AuthorityInfo {
  key: AuthorityKey;
  label: string;
  shortLabel: string;
  description: string;
  color: string;
  bgClass: string;
  textClass: string;
  borderClass: string;
  ch99Prefix?: string;
}

export const AUTHORITIES: AuthorityInfo[] = [
  { key: 'rate_232', label: 'Section 232', shortLabel: 'Section 232', description: 'National-security tariffs on steel, aluminum, autos, copper, and derivative products (Trade Expansion Act of 1962, \u00a7232).', color: '#ff7c43', bgClass: 'bg-orange-100', textClass: 'text-orange-800', borderClass: 'border-orange-200', ch99Prefix: '9903.80-85, 9903.94' },
  { key: 'rate_301', label: 'Section 301', shortLabel: 'Section 301', description: 'Retaliatory tariffs on China-origin goods in response to unfair trade practices (Trade Act of 1974, \u00a7301).', color: '#59a89c', bgClass: 'bg-red-100', textClass: 'text-red-800', borderClass: 'border-red-200', ch99Prefix: '9903.88' },
  { key: 'rate_ieepa_recip', label: 'IEEPA Reciprocal', shortLabel: 'IEEPA Reciprocal', description: 'Reciprocal tariffs imposed under the International Emergency Economic Powers Act to counter trade deficits.', color: '#665191', bgClass: 'bg-purple-100', textClass: 'text-purple-800', borderClass: 'border-purple-200', ch99Prefix: '9903.01.25-76, 9903.02' },
  { key: 'rate_ieepa_fent', label: 'Anti-Fentanyl (IEEPA)', shortLabel: 'Anti-Fentanyl (IEEPA)', description: 'Emergency tariffs on goods from countries linked to fentanyl trafficking (primarily Canada, Mexico, China) under IEEPA.', color: '#d45087', bgClass: 'bg-pink-100', textClass: 'text-pink-800', borderClass: 'border-pink-200', ch99Prefix: '9903.01.01-24' },
  { key: 'rate_s122', label: 'Section 122', shortLabel: 'Section 122', description: 'Temporary blanket tariff on all imports under Trade Act \u00a7122 to address balance-of-payments emergencies. Expires after 150 days.', color: '#f95d6a', bgClass: 'bg-amber-100', textClass: 'text-amber-800', borderClass: 'border-amber-200', ch99Prefix: '9903.03' },
  { key: 'rate_section_201', label: 'Section 201', shortLabel: 'Section 201', description: 'Safeguard tariffs to protect domestic industries from import surges (Trade Act of 1974, \u00a7201). Covers solar panels and washing machines.', color: '#a05195', bgClass: 'bg-indigo-100', textClass: 'text-indigo-800', borderClass: 'border-indigo-200', ch99Prefix: '9903.40-45' },
  { key: 'rate_other', label: 'Other Ch. 99', shortLabel: 'Other Ch. 99', description: 'Additional Chapter 99 provisions not covered by the major authorities above.', color: '#ffa600', bgClass: 'bg-gray-100', textClass: 'text-gray-800', borderClass: 'border-gray-200' },
];

export const AUTHORITY_MAP = Object.fromEntries(AUTHORITIES.map(a => [a.key, a])) as Record<AuthorityKey, AuthorityInfo>;

export const MFN_COLOR = '#008dff';

export const STACK_COLORS: Record<string, string> = {
  base_rate: MFN_COLOR,
  rate_232: '#ff7c43',
  rate_301: '#59a89c',
  rate_ieepa_recip: '#665191',
  rate_ieepa_fent: '#d45087',
  rate_s122: '#f95d6a',
  rate_section_201: '#a05195',
  rate_other: '#ffa600',
};

export function getStackColor(label: string): string {
  const upper = label.toUpperCase();
  if (upper.includes('232') && upper.includes('ALUMINUM')) return '#665191';
  if (upper.includes('232') && upper.includes('STEEL')) return '#a05195';
  for (const [key, color] of Object.entries(STACK_COLORS)) {
    if (upper.includes(key.replace('rate_', '').toUpperCase())) return color;
  }
  const PALETTE = ['#003f5c', '#2f4b7c', '#665191', '#a05195', '#d45087', '#f95d6a', '#ff7c43', '#ffa600'];
  const hash = Array.from(label).reduce((h, c) => ((h << 5) - h + c.charCodeAt(0)) | 0, 0);
  return PALETTE[Math.abs(hash) % PALETTE.length];
}

export interface ShipmentRow {
  id: string;
  customsValue: number;
  date: Date;
  countryCode?: string;
  quantity?: number;
  freight?: number;
  insurance?: number;
  composition?: CompositionOverrides;
}

export interface DutyBreakdown {
  authority: string;
  rate: number;
  statutoryRate?: number;
  dutyAmount: number;
  color: string;
  ch99Code?: string;
  rateBasis?: RateBasis;
  specificAmount?: number;
  /** The legally specified unit from the rate expression */
  dutyBasisUnit?: string;
  quantityUsed?: number;
  /** The raw rate before nonmetal_share scaling (undefined if no scaling) */
  grossRate?: number;
  /** nonmetal_share applied (1.0 if no scaling) */
  nonmetalShare?: number;
  /** Whether this authority's rate was scaled by nonmetal_share */
  isMetalScaled?: boolean;
}

export interface LandedCostResult {
  customsValue: number;
  totalDutyRate: number;
  totalDuty: number;
  baseRate: number;
  baseDuty: number;
  additionalRate: number;
  additionalDuty: number;
  breakdown: DutyBreakdown[];
  mpf: number;
  hmf: number;
  totalFees: number;
  landedCost: number;
  ratePeriod: string;
  rateBasis: RateBasis;
  quantityUsed?: number;
  /** The legally specified unit that drove duty calculation (from rate text) */
  dutyBasisUnit?: string;
}

export type PartnerGroup = 'china' | 'canada' | 'mexico' | 'eu' | 'uk' | 'japan' | 'ftrow';

export const PARTNER_COLORS: Record<string, string> = {
  china: '#EF4444',
  canada: '#3B82F6',
  mexico: '#22C55E',
  eu: '#8B5CF6',
  uk: '#F59E0B',
  japan: '#EC4899',
  ftrow: '#06B6D4',
};

/** Census codes for Column 2 countries (Cuba, North Korea, Belarus, Russia) */
export const COLUMN2_COUNTRY_CODES = new Set(['2390', '5790', '4622', '4621']);

/** Census code for China — used in stacking rules */
export const CTY_CHINA = '5700';

// =============================================================================
// Authority Data Modes & Composition Overrides
// =============================================================================

/**
 * What extra data each authority requires from the importer.
 * Determined by the authority trigger, NOT by classification.
 */
export type AuthorityDataMode =
  | 'NONE'
  | 'VALUE_ONLY'
  | 'US_CONTENT_VALUE'
  | 'METAL_CONTENT_VALUE_AND_KG'
  | 'SCOPE_REVIEW';

/**
 * Declared metal content of a product, supplied by the importer to override the
 * BEA-derived per-type metal shares baked into a ProductRate. Each metal can be
 * declared as a percent (0-1) or as grams; if grams are used, totalWeightGrams
 * is required to convert. When a metal is undefined here, the BEA-derived share
 * on the rate row is used as the fallback for that metal.
 */
export interface DeclaredMetalContent {
  aluminum?: { percent?: number; grams?: number };
  steel?:    { percent?: number; grams?: number };
  copper?:   { percent?: number; grams?: number };
  other?:    { percent?: number; grams?: number };
  /** Required when any metal is declared in grams; ignored when all are declared as percent. */
  totalWeightGrams?: number;
}

/**
 * User-entered composition/content overrides for duty calculation.
 * These supplement the pre-computed rates from the backend.
 */
export interface CompositionOverrides {
  /** US content percent (0-1) for IEEPA reciprocal carveout (EO 14257 threshold: >=0.20) */
  usContentPercent?: number;
  /** US content dollar value — alternative to percent */
  usContentValue?: number;
  /** Metal content value ($) for 232 derivatives (9903.81.91, 9903.85.08) */
  metalContentValue?: number;
  /** Metal content weight in kg for 232 derivative reporting */
  metalContentKg?: number;
  /** Primary country of aluminum smelting (Census code) — 232 aluminum reporting */
  primarySmeltCountry?: string;
  /** Secondary country of aluminum smelting (Census code) — 232 aluminum reporting */
  secondarySmeltCountry?: string;
  /** Country of aluminum casting (Census code) — 232 aluminum reporting */
  castCountry?: string;
  /** Declared per-type metal composition; overrides BEA-derived shares for stacking math. */
  declaredMetalContent?: DeclaredMetalContent;
}

/**
 * Describes what an active authority needs from the importer.
 */
export interface AuthorityTrigger {
  authority: AuthorityKey;
  mode: AuthorityDataMode;
  label: string;
  fields: Array<{
    key: keyof CompositionOverrides;
    label: string;
    type: 'number' | 'percent' | 'country';
    required: boolean;
    hint: string;
  }>;
}

export function formatCh99Code(code: string): string {
  const digits = code.replace(/\D/g, '');
  if (digits.length <= 4) return digits;
  if (digits.length <= 6) return `${digits.slice(0, 4)}.${digits.slice(4)}`;
  return `${digits.slice(0, 4)}.${digits.slice(4, 6)}.${digits.slice(6)}`;
}
