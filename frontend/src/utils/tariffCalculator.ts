import type { ProductRate, DutyBreakdown, LandedCostResult, AuthorityKey, RateBasis, RoundingRule, CompositionOverrides, DeclaredMetalContent, AuthorityDataMode, AuthorityTrigger } from '@/types/tariff';
import { AUTHORITY_MAP, STATUTORY_KEY_MAP, COLUMN2_COUNTRY_CODES, CTY_CHINA, parseSpecialPrograms } from '@/types/tariff';
import { formatDate } from '@/utils/formatters';
import { resolveCh99Code } from '@/utils/chapter99';
import { programCodesForCountry } from '@/utils/tradeAgreements';

// =============================================================================
// Fee Schedule (FY 2026) — CBP Customs Fees
// =============================================================================
// Note: These are customs fees, distinct from customs duties and excise taxes.
// CBP collects federal excise tax as well as customs duties and other fees on
// certain imports — they are separate liabilities even if collected together.

export const MPF_RATE = 0.003464;   // 0.3464%, all transport modes
export const MPF_MIN = 33.58;       // minimum per entry
export const MPF_MAX = 651.50;      // maximum per entry
export const HMF_RATE = 0.00125;    // 0.125%, ocean freight only, no min/max

export function calculateMPF(customsValue: number): number {
  const raw = customsValue * MPF_RATE;
  return Math.min(Math.max(raw, MPF_MIN), MPF_MAX);
}

export function calculateHMF(customsValue: number): number {
  return customsValue * HMF_RATE;
}

// =============================================================================
// 19 CFR 159.3 Rounding Rules
// =============================================================================
// Per 19 CFR 159.3:
//   Ad valorem: rates applied to values in even dollars. Fractions under
//     $0.50 disregarded, $0.50 or more treated as $1.
//   Specific ≤$1/unit: fractional qty under one-half disregarded, one-half
//     or more treated as whole unit.
//   Specific >$1/unit: duty assessed on exact quantity, fraction expressed
//     as decimal to two places.

/** Round customs value per 19 CFR 159.3 for ad valorem duty. */
export function roundValuePer19CFR159_3(customsValue: number): number {
  const fraction = customsValue - Math.floor(customsValue);
  return fraction >= 0.50 ? Math.ceil(customsValue) : Math.floor(customsValue);
}

/**
 * Round quantity per 19 CFR 159.3 for specific duty.
 * Rule depends on whether the specific rate amount is >$1/unit or ≤$1/unit.
 */
export function roundQuantityPer19CFR159_3(
  quantity: number,
  specificRateAmount: number,
): number {
  if (specificRateAmount > 1.0) {
    // >$1/unit: exact quantity, fraction to 2 decimal places
    return Math.round(quantity * 100) / 100;
  }
  // ≤$1/unit: fractional qty <0.5 disregarded, ≥0.5 = whole unit
  const fraction = quantity - Math.floor(quantity);
  return fraction >= 0.5 ? Math.ceil(quantity) : Math.floor(quantity);
}

// =============================================================================
// Rate Tier Selection
// =============================================================================

/**
 * Select the applicable base rate based on country of origin.
 *
 * Classification under the legal HTSUS provisions determines the rate tier:
 * - Column 2 countries (Cuba, DPRK, Belarus, Russia) use rate_column2
 * - Countries matching special program codes use rate_special
 * - All other countries use base_rate (Column 1 General / MFN)
 *
 * `special_programs_json` lists HTSUS special-program indicators (e.g. "KR",
 * "IL", "S"), not Census country codes. `programCodesForCountry` maps a Census
 * code to the set of HTSUS indicators the country is a party to; we match
 * the product's listed programs against that set.
 */
export function selectApplicableBaseRate(
  rate: ProductRate,
  countryCode?: string,
): { effectiveBaseRate: number; tier: 'general' | 'special' | 'column2' } {
  // Column 2 countries
  if (countryCode && COLUMN2_COUNTRY_CODES.has(countryCode)) {
    const col2Rate = rate.rate_column2;
    if (col2Rate != null && !isNaN(col2Rate)) {
      return { effectiveBaseRate: col2Rate, tier: 'column2' };
    }
  }

  // Check if country qualifies for a special rate
  if (countryCode && rate.special_programs_json) {
    const memberCodes = programCodesForCountry(countryCode);
    if (memberCodes.size > 0) {
      const programs = parseSpecialPrograms(rate.special_programs_json);
      for (const entry of programs) {
        if (entry.entry_type === 'rate' && entry.rate != null) {
          if (entry.programs.some(p => memberCodes.has(p))) {
            return { effectiveBaseRate: entry.rate, tier: 'special' };
          }
        }
      }
    }
  }

  return { effectiveBaseRate: rate.base_rate, tier: 'general' };
}

// =============================================================================
// Base Duty Calculation
// =============================================================================

/**
 * Calculate the base duty amount per U.S. HTSUS methodology.
 *
 * The calculation depends on the rate_basis:
 *   ad_valorem / free: duty = roundedValue × percent (quantity NOT relevant)
 *   specific: duty = roundedQuantity × specificAmount (value NOT relevant)
 *   compound: duty = (roundedQuantity × specificAmount) + (roundedValue × percent)
 *
 * Quantity enters the duty math ONLY when rate_basis is 'specific' or 'compound',
 * and then only in the legally relevant unit (duty_basis_unit from the rate text).
 * The "Unit of Quantity" on the 10-digit statistical line is for reporting, not
 * for duty calculation. See 19 CFR 159.3 for rounding rules.
 */
function calculateBaseDutyAmount(
  rate: ProductRate,
  customsValue: number,
  effectiveBaseRate: number,
  quantity?: number,
): number {
  const rateBasis: RateBasis = rate.rate_basis ?? 'ad_valorem';
  const specificAmount = rate.specific_amount;

  if (rateBasis === 'specific' && specificAmount != null && quantity != null && quantity > 0) {
    const roundedQty = roundQuantityPer19CFR159_3(quantity, specificAmount);
    return specificAmount * roundedQty;
  }

  if (rateBasis === 'compound' && specificAmount != null && quantity != null && quantity > 0) {
    // Compound: specific component + ad valorem component, each with own rounding
    const roundedQty = roundQuantityPer19CFR159_3(quantity, specificAmount);
    const specificPart = specificAmount * roundedQty;
    const roundedValue = roundValuePer19CFR159_3(customsValue);
    const avPart = roundedValue * (effectiveBaseRate ?? 0);
    return specificPart + avPart;
  }

  // Ad valorem (default) or free — duty based on customs value, not quantity
  const roundedValue = roundValuePer19CFR159_3(customsValue);
  return roundedValue * effectiveBaseRate;
}

// =============================================================================
// Mutual Exclusion Stacking Logic
// =============================================================================
// Ported from R backend: src/helpers.R apply_stacking_rules() lines 1399-1496.
// Section 232 and IEEPA reciprocal are mutually exclusive: 232 covers the metal
// portion, while IEEPA/S122 apply only to the non-metal portion. Fentanyl stacks
// fully for China but follows the same content split for non-China countries.

/**
 * Compute the non-metal share for stacking purposes.
 * Replicates the per-type logic from helpers.R:1440-1468.
 *
 * Returns 0 when:
 * - rate_232 is not active (no mutual exclusion needed)
 * - product is pure metal (metal_share = 1.0, 232 takes full precedence)
 *
 * Returns (1 - activeTypeShare) when 232 is active and product has partial metal content.
 */
// =============================================================================
// Declared Metal Content Override
// =============================================================================
// Importers can declare actual per-type metal content via CompositionOverrides
// (declaredMetalContent). When present, the declared values replace the
// BEA-derived per-type shares on the rate row before the stacking math runs.
// This lets a CPU with 0.13% aluminum content get charged S232 on 0.13% of its
// value rather than 100%.

const clamp01 = (n: number): number => Math.max(0, Math.min(1, n));

function resolveMetalShare(
  decl: { percent?: number; grams?: number } | undefined,
  totalWeightGrams: number | undefined,
  fallback: number,
): number {
  if (decl?.percent != null) return clamp01(decl.percent);
  if (decl?.grams != null && totalWeightGrams != null && totalWeightGrams > 0) {
    return clamp01(decl.grams / totalWeightGrams);
  }
  return fallback;
}

/**
 * Apply a DeclaredMetalContent override to a ProductRate, returning a NEW rate
 * with the per-type shares replaced AND the post-stacking rate_232 recomputed
 * from the statutory rate × the user's declared active-type share. Returns the
 * original rate unchanged when no override is supplied.
 *
 * Why we override rate_232 explicitly: the rate_232 returned by the API is
 * already metal-scaled by the R backend (rate_232 = statutory × bea_share for
 * derivatives, statutory × 1.0 for primary metals). Overriding only the share
 * fields would update the IEEPA/S122 nonmetal-portion math but leave rate_232
 * frozen at the API value — so the displayed Section 232 wouldn't reflect the
 * declared content. We recompute it here from statutory_rate_232 × the active-
 * type declared share, mirroring the active-type selection in computeNonmetalShare.
 */
export function applyMetalContentOverride(
  rate: ProductRate,
  override: DeclaredMetalContent | undefined,
): ProductRate {
  if (!override) return rate;
  const { totalWeightGrams } = override;
  const aluminum = resolveMetalShare(override.aluminum, totalWeightGrams, rate.aluminum_share);
  const steel    = resolveMetalShare(override.steel,    totalWeightGrams, rate.steel_share);
  const copper   = resolveMetalShare(override.copper,   totalWeightGrams, rate.copper_share);
  const other    = resolveMetalShare(override.other,    totalWeightGrams, rate.other_metal_share);
  const totalMetal = clamp01(aluminum + steel + copper + other);

  // Pick the active metal type the same way computeNonmetalShare does, then
  // scale the underlying statutory rate by the declared share for that type.
  const ch2 = rate.hts10.substring(0, 2);
  let activeTypeShare: number;
  if (ch2 === '72' || ch2 === '73') {
    activeTypeShare = steel;
  } else if (ch2 === '76') {
    activeTypeShare = aluminum;
  } else if (rate.is_copper_heading) {
    activeTypeShare = copper;
  } else if (rate.deriv_type === 'steel') {
    activeTypeShare = steel;
  } else if (rate.deriv_type === 'aluminum') {
    activeTypeShare = aluminum;
  } else {
    // Ambiguous derivative classification — fall back to aluminum to mirror the
    // R pipeline's behavior (helpers.R fallback at the same branch). The user
    // can still see the effective rate live; if it looks wrong, they iterate.
    activeTypeShare = aluminum;
  }
  // Preserve country-level exemption: if the post-stacking rate_232 was already
  // zero (e.g., USMCA-eligible Canada origin), the user's metal declaration is
  // about *physical* composition and should not bypass the exemption. Only
  // rescale when the rate is actively applied for this (country, date) triple.
  const newRate232 = rate.rate_232 > 0
    ? Math.max(0, rate.statutory_rate_232 * activeTypeShare)
    : 0;

  return {
    ...rate,
    aluminum_share: aluminum,
    steel_share: steel,
    copper_share: copper,
    other_metal_share: other,
    metal_share: totalMetal,
    rate_232: newRate232,
  };
}

export function computeNonmetalShare(rate: ProductRate): number {
  if (rate.rate_232 <= 0) return 0;

  const ch2 = rate.hts10.substring(0, 2);
  const hasPerType = rate.steel_share != null && rate.aluminum_share != null && rate.copper_share != null;

  if (hasPerType) {
    let activeTypeShare: number;
    if (ch2 === '72' || ch2 === '73') {
      activeTypeShare = rate.steel_share;
    } else if (ch2 === '76') {
      activeTypeShare = rate.aluminum_share;
    } else if (rate.is_copper_heading) {
      activeTypeShare = rate.copper_share;
    } else if (rate.deriv_type === 'steel') {
      activeTypeShare = rate.steel_share;
    } else if (rate.deriv_type === 'aluminum') {
      activeTypeShare = rate.aluminum_share;
    } else if (rate.metal_share < 1.0) {
      activeTypeShare = rate.aluminum_share; // fallback per R code
    } else {
      activeTypeShare = 0;
    }
    return activeTypeShare > 0 ? 1 - activeTypeShare : 0;
  }

  // Fallback: aggregate metal_share (backward compat for older data)
  return rate.metal_share < 1.0 ? 1 - rate.metal_share : 0;
}

/**
 * Net authority rates after mutual-exclusion stacking.
 * Replicates the four-branch case_when from helpers.R:1470-1496.
 */
export interface NetAuthorityAmounts {
  rate_232: number;
  rate_301: number;
  rate_ieepa_recip: number;
  rate_ieepa_fent: number;
  rate_s122: number;
  rate_section_201: number;
  rate_other: number;
}

export function computeNetAuthorityAmounts(
  rate: ProductRate,
  countryCode: string,
): NetAuthorityAmounts {
  const nonmetalShare = computeNonmetalShare(rate);
  const isChina = countryCode === CTY_CHINA;
  const has232 = rate.rate_232 > 0;

  if (isChina && has232) {
    // China with 232: fent stacks fully, recip/s122 scale by nonmetal
    return {
      rate_232: rate.rate_232,
      rate_ieepa_recip: rate.rate_ieepa_recip * nonmetalShare,
      rate_ieepa_fent: rate.rate_ieepa_fent,
      rate_301: rate.rate_301,
      rate_s122: rate.rate_s122 * nonmetalShare,
      rate_section_201: rate.rate_section_201,
      rate_other: rate.rate_other,
    };
  }

  if (isChina && !has232) {
    // China without 232: everything at full rate
    return {
      rate_232: 0,
      rate_ieepa_recip: rate.rate_ieepa_recip,
      rate_ieepa_fent: rate.rate_ieepa_fent,
      rate_301: rate.rate_301,
      rate_s122: rate.rate_s122,
      rate_section_201: rate.rate_section_201,
      rate_other: rate.rate_other,
    };
  }

  if (!isChina && has232) {
    // Others with 232: fent also scales by nonmetal (unlike China)
    return {
      rate_232: rate.rate_232,
      rate_ieepa_recip: rate.rate_ieepa_recip * nonmetalShare,
      rate_ieepa_fent: rate.rate_ieepa_fent * nonmetalShare,
      rate_s122: rate.rate_s122 * nonmetalShare,
      rate_301: rate.rate_301,
      rate_section_201: rate.rate_section_201,
      rate_other: rate.rate_other,
    };
  }

  // Others without 232: everything at full rate
  return {
    rate_232: 0,
    rate_ieepa_recip: rate.rate_ieepa_recip,
    rate_ieepa_fent: rate.rate_ieepa_fent,
    rate_301: rate.rate_301,
    rate_s122: rate.rate_s122,
    rate_section_201: rate.rate_section_201,
    rate_other: rate.rate_other,
  };
}

// =============================================================================
// Landed Cost Calculation
// =============================================================================

export function calculateLandedCost(
  rate: ProductRate,
  customsValue: number,
  options?: {
    includeHMF?: boolean;
    freight?: number;
    insurance?: number;
    quantity?: number;
    countryCode?: string;
    composition?: CompositionOverrides;
  }
): LandedCostResult {
  const includeHMF = options?.includeHMF ?? true;
  const freight = options?.freight ?? 0;
  const insurance = options?.insurance ?? 0;
  const quantity = options?.quantity;
  const countryCode = options?.countryCode;
  const composition = options?.composition;

  // Apply declared metal content override (if any) BEFORE share-driven stacking.
  // The override replaces the BEA-derived per-type shares on the rate row;
  // downstream stacking math reads from the effective rate. usContentPercent /
  // usContentValue are independent of metal content and apply below unchanged.
  const effectiveRate = applyMetalContentOverride(rate, composition?.declaredMetalContent);

  const { effectiveBaseRate, tier } = selectApplicableBaseRate(effectiveRate, countryCode);
  const rateBasis: RateBasis = effectiveRate.rate_basis ?? 'ad_valorem';

  // Calculate base duty (Chapters 1-97 rate)
  const baseDuty = calculateBaseDutyAmount(effectiveRate, customsValue, effectiveBaseRate, quantity);

  // ---------------------------------------------------------------------------
  // Additional duties (Chapter 99) with mutual-exclusion stacking.
  // Port of apply_stacking_rules() from helpers.R:1470-1496.
  // ---------------------------------------------------------------------------
  const cc = countryCode ?? effectiveRate.country;
  const netAmounts = computeNetAuthorityAmounts(effectiveRate, cc);
  const nonmetalShare = computeNonmetalShare(effectiveRate);

  // US content carveout for IEEPA reciprocal (EO 14257):
  // Duty applies only to non-U.S. content when >= 20% is U.S. originating.
  let recipDutiableValue = customsValue;
  if (composition?.usContentPercent != null && composition.usContentPercent >= 0.20) {
    recipDutiableValue = customsValue * (1 - composition.usContentPercent);
  } else if (composition?.usContentValue != null && customsValue > 0) {
    const pct = composition.usContentValue / customsValue;
    if (pct >= 0.20) {
      recipDutiableValue = customsValue - composition.usContentValue;
    }
  }

  // Compute additional duty from net (post-stacking) authority amounts.
  // When no user overrides are applied and no US content carveout, this should
  // match rate.total_additional (which was pre-computed by R).
  const additionalDuty =
    customsValue * netAmounts.rate_232 +
    recipDutiableValue * netAmounts.rate_ieepa_recip +
    customsValue * netAmounts.rate_ieepa_fent +
    customsValue * netAmounts.rate_301 +
    customsValue * netAmounts.rate_s122 +
    customsValue * netAmounts.rate_section_201 +
    customsValue * netAmounts.rate_other;

  const totalDuty = baseDuty + additionalDuty;

  // ---------------------------------------------------------------------------
  // Breakdown — per-authority line items with correct stacking amounts
  // ---------------------------------------------------------------------------
  const breakdown: DutyBreakdown[] = [];

  if (effectiveBaseRate > 0 || rate.statutory_base_rate > 0 || baseDuty > 0) {
    const tierLabel = tier === 'column2' ? 'Column 2 Rate'
      : tier === 'special' ? 'Special Preferential Rate'
      : 'MFN Base Rate';
    breakdown.push({
      authority: tierLabel,
      rate: effectiveBaseRate,
      statutoryRate: rate.statutory_base_rate !== effectiveBaseRate ? rate.statutory_base_rate : undefined,
      dutyAmount: baseDuty,
      color: tier === 'column2' ? '#d97706' : tier === 'special' ? '#16a34a' : '#008dff',
      rateBasis,
      specificAmount: rate.specific_amount ?? undefined,
      dutyBasisUnit: rate.duty_basis_unit ?? undefined,
      quantityUsed: quantity,
    });
  }

  const authorityKeys: AuthorityKey[] = [
    'rate_232', 'rate_301', 'rate_ieepa_recip',
    'rate_ieepa_fent', 'rate_s122', 'rate_section_201', 'rate_other',
  ];

  for (const key of authorityKeys) {
    const grossRate = rate[key];
    const netRate = netAmounts[key];
    const statutoryKey = STATUTORY_KEY_MAP[key];
    const statutoryValue = rate[statutoryKey] ?? 0;
    if (grossRate > 0 || statutoryValue > 0) {
      const info = AUTHORITY_MAP[key];
      const isScaled = grossRate > 0 && Math.abs(netRate - grossRate) > 0.00001;
      // IEEPA reciprocal uses the US-content-adjusted dutiable value
      const dutiableValue = key === 'rate_ieepa_recip' ? recipDutiableValue : customsValue;
      breakdown.push({
        authority: info.label,
        rate: netRate,
        statutoryRate: Math.abs(statutoryValue - grossRate) > 0.00001 ? statutoryValue : undefined,
        dutyAmount: dutiableValue * netRate,
        color: info.color,
        ch99Code: resolveCh99Code(rate, info),
        rateBasis: 'ad_valorem',  // Ch99 rates in this system are ad valorem
        grossRate: isScaled ? grossRate : undefined,
        nonmetalShare: isScaled ? nonmetalShare : undefined,
        isMetalScaled: isScaled || undefined,
      });
    }
  }

  const mpf = calculateMPF(customsValue);
  const hmf = includeHMF ? calculateHMF(customsValue) : 0;
  const totalFees = mpf + hmf;
  const landedCost = customsValue + totalDuty + totalFees + freight + insurance;

  // Compute effective total rate from net amounts
  const netAdditionalRate = Object.values(netAmounts).reduce((sum, r) => sum + r, 0);

  return {
    customsValue,
    totalDutyRate: effectiveBaseRate + netAdditionalRate,
    totalDuty,
    baseRate: effectiveBaseRate,
    baseDuty,
    additionalRate: netAdditionalRate,
    additionalDuty,
    breakdown,
    mpf,
    hmf,
    totalFees,
    landedCost,
    ratePeriod: `${formatDate(rate.valid_from)} – ${formatDate(rate.valid_until)}`,
    rateBasis,
    quantityUsed: quantity,
    // duty_basis_unit comes from the legal rate text, NOT from the statistical
    // reporting unit. It is null for ad valorem rates (quantity not relevant).
    dutyBasisUnit: rate.duty_basis_unit ?? undefined,
  };
}

// =============================================================================
// Utilities
// =============================================================================

export function findRateForDate(rates: ProductRate[], dateStr: string): ProductRate | null {
  return rates.find(r => r.valid_from <= dateStr && r.valid_until >= dateStr) ?? null;
}

export function computeRateVolatility(rates: ProductRate[]): 'STABLE' | 'MODERATE' | 'HIGH' {
  if (rates.length < 2) return 'STABLE';
  const totalRates = rates.map(r => r.total_rate);
  const min = Math.min(...totalRates);
  const max = Math.max(...totalRates);
  const spread = max - min;
  if (spread > 0.50) return 'HIGH';
  if (spread > 0.20) return 'MODERATE';
  return 'STABLE';
}

export function exportShipmentsCSV(
  rows: Array<{ date: Date; customsValue: number; result: LandedCostResult }>,
  htsCode: string,
  countryName: string,
): void {
  const header = [
    'Date', 'HTS Code', 'Country', 'Customs Value', 'Rate Period',
    'MFN Rate (%)', 'MFN Duty (USD)',
    ...rows[0]?.result.breakdown
      .filter(b => !BASE_TIER_AUTHORITIES.has(b.authority))
      .flatMap(b => [`${b.authority} Rate (%)`, `${b.authority} Duty (USD)`]) ?? [],
    'Total Rate (%)', 'Total Duty (USD)',
    'MPF (USD)', 'HMF (USD)', 'Total Fees (USD)',
    'Landed Cost (USD)',
  ];

  const csvRows = rows.map(({ date, result: r }) => {
    const baseLine = r.breakdown.find(b => BASE_TIER_AUTHORITIES.has(b.authority));
    const punitive = r.breakdown.filter(b => !BASE_TIER_AUTHORITIES.has(b.authority));
    return [
      date.toISOString().slice(0, 10), htsCode, countryName,
      r.customsValue.toFixed(2), r.ratePeriod,
      ((baseLine?.rate ?? 0) * 100).toFixed(2), (baseLine?.dutyAmount ?? 0).toFixed(2),
      ...punitive.flatMap(b => [(b.rate * 100).toFixed(2), b.dutyAmount.toFixed(2)]),
      (r.totalDutyRate * 100).toFixed(2), r.totalDuty.toFixed(2),
      r.mpf.toFixed(2), r.hmf.toFixed(2), r.totalFees.toFixed(2),
      r.landedCost.toFixed(2),
    ];
  });

  const totals = rows.reduce(
    (acc, { result: r }) => ({
      cv: acc.cv + r.customsValue, duty: acc.duty + r.totalDuty,
      mpf: acc.mpf + r.mpf, hmf: acc.hmf + r.hmf,
      fees: acc.fees + r.totalFees, landed: acc.landed + r.landedCost,
    }),
    { cv: 0, duty: 0, mpf: 0, hmf: 0, fees: 0, landed: 0 }
  );

  const totalsRow = ['TOTALS', '', '', totals.cv.toFixed(2), '',
    '', '',
    ...rows[0]?.result.breakdown.filter(b => !BASE_TIER_AUTHORITIES.has(b.authority)).flatMap(() => ['', '']) ?? [],
    '', totals.duty.toFixed(2),
    totals.mpf.toFixed(2), totals.hmf.toFixed(2), totals.fees.toFixed(2),
    totals.landed.toFixed(2),
  ];

  const csv = [header, ...csvRows, totalsRow].map(r => r.join(',')).join('\n');
  const blob = new Blob([csv], { type: 'text/csv' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `duty_calculation_${htsCode}_${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

const BASE_TIER_AUTHORITIES = new Set(['MFN Base Rate', 'Special Preferential Rate', 'Column 2 Rate']);

// =============================================================================
// Authority Trigger Detection
// =============================================================================
// Determines what extra data each active authority requires from the importer.
// Classification triggers (19 CFR 141.89) are informational — they don't affect
// duty calculation but indicate the HTS classification may depend on composition.

/** HTS chapter prefixes where classification may require composition data per 19 CFR 141.89 */
export const CLASSIFICATION_COMPOSITION_CHAPTERS: Record<string, string> = {
  '32': 'Colors/dyes (heading 3204) — classification may depend on chemical composition per 19 CFR 141.89.',
  '52': 'Cotton fabrics (headings 5208–5212) — classification may require fiber composition.',
  '72': 'Iron & steel (Ch. 72) — classification may require carbon content and alloy composition.',
  '73': 'Steel articles (Ch. 73) — classification may depend on steel composition per legal notes.',
  '74': 'Copper articles (Ch. 74) — classification requires copper content per heading notes.',
  '76': 'Aluminum articles (Ch. 76) — classification may depend on alloy type per legal notes.',
};

/**
 * Detect which active authorities need extra data from the importer.
 * Returns only authorities with non-NONE data modes.
 */
export function detectAuthorityTriggers(
  rate: ProductRate,
  countryCode: string,
): AuthorityTrigger[] {
  const triggers: AuthorityTrigger[] = [];

  // Section 232 derivatives need metal content value + kg
  if (rate.rate_232 > 0 && rate.deriv_type === 'steel') {
    triggers.push({
      authority: 'rate_232',
      mode: 'METAL_CONTENT_VALUE_AND_KG',
      label: 'Section 232 — Steel Derivative (9903.81.91)',
      fields: [
        { key: 'metalContentValue', label: 'Steel content value ($)', type: 'number', required: false, hint: 'Declared value of the steel content. The additional 25% duty applies to this value.' },
        { key: 'metalContentKg', label: 'Steel content weight (kg)', type: 'number', required: false, hint: 'Quantity of steel content in kilograms for CBP reporting.' },
      ],
    });
  } else if (rate.rate_232 > 0 && rate.deriv_type === 'aluminum') {
    triggers.push({
      authority: 'rate_232',
      mode: 'METAL_CONTENT_VALUE_AND_KG',
      label: 'Section 232 — Aluminum Derivative (9903.85.08)',
      fields: [
        { key: 'metalContentValue', label: 'Aluminum content value ($)', type: 'number', required: false, hint: 'Declared value of the aluminum content. The additional 25% duty applies to this value.' },
        { key: 'metalContentKg', label: 'Aluminum content weight (kg)', type: 'number', required: false, hint: 'Quantity of aluminum content in kilograms for CBP reporting.' },
        { key: 'primarySmeltCountry', label: 'Primary country of smelt', type: 'country', required: false, hint: 'Country where the aluminum was primarily smelted (required for 232 aluminum entries).' },
        { key: 'secondarySmeltCountry', label: 'Secondary country of smelt', type: 'country', required: false, hint: 'Secondary smelting country, if applicable.' },
        { key: 'castCountry', label: 'Country of cast', type: 'country', required: false, hint: 'Country where the aluminum was cast.' },
      ],
    });
  } else if (rate.rate_232 > 0 && rate.is_copper_heading) {
    triggers.push({
      authority: 'rate_232',
      mode: 'METAL_CONTENT_VALUE_AND_KG',
      label: 'Section 232 — Copper',
      fields: [
        { key: 'metalContentValue', label: 'Copper content value ($)', type: 'number', required: false, hint: 'Declared value of the copper content. Duty applies only to the copper content; non-copper content is subject to reciprocal/other duties.' },
      ],
    });
  }

  // IEEPA reciprocal: optional US content carveout (EO 14257)
  if (rate.rate_ieepa_recip > 0) {
    triggers.push({
      authority: 'rate_ieepa_recip',
      mode: 'US_CONTENT_VALUE',
      label: 'IEEPA Reciprocal — U.S. Content Carveout (EO 14257)',
      fields: [
        { key: 'usContentPercent', label: 'U.S. content (% of customs value)', type: 'percent', required: false, hint: 'If at least 20% of value is U.S. originating, duty applies only to the non-U.S. content. Leave blank if not claiming.' },
        { key: 'usContentValue', label: 'U.S. content value ($)', type: 'number', required: false, hint: 'Dollar value of U.S. content — alternative to percentage.' },
      ],
    });
  }

  return triggers;
}
