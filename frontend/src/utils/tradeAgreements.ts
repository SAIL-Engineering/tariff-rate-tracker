import type { ProductRate, SpecialProgramEntry } from '@/types/tariff';
import { parseSpecialPrograms } from '@/types/tariff';

// =============================================================================
// Trade Agreement Country Mappings
// =============================================================================
//
// HTSUS Column 1-Special lists preferential rates for specific trade agreements
// and preference programs. The "special" field carries 1–3 letter indicators
// (e.g., "S", "S+", "KR", "IL", "P+", "A", "A*", "A+"), NOT Census country
// codes. Claiming a special rate requires:
//   1. the country is a member of the program, AND
//   2. the product's HTS line lists that program code in its special field.
//
// This file maps each Census country code to the HTSUS program codes that
// country is party to. USMCA is split into Canada-only and Mexico-only
// sub-codes (`CA`, `MX`) in addition to the general `S` / `S+` codes — a
// product marked `MX` alone does NOT grant USMCA treatment to Canada.
//
// Column reference:
//   Column 1-General  — MFN rate; default path, no special indicator.
//   Column 1-Special  — preferential; matched via this file.
//   Column 2          — highest (non-NTR); handled by COLUMN2_COUNTRY_CODES
//                        in types/tariff.ts, not here.
//
// Coverage notes:
//   - GSP (`A`, `A*`, `A+`) is EXCLUDED: GSP authority expired 2020-12-31 and
//     has not been reauthorized. Importers cannot legally claim GSP today.
//     If/when Congress renews, add the beneficiary list.
//   - AGOA (`D`) and CBERA/CBTPA (`E`, `E*`) are EXCLUDED pending
//     beneficiary-country lists. Today those chips would render as MFN.

export type AgreementKey =
  | 'USMCA' | 'KORUS' | 'ISRAEL' | 'JORDAN' | 'OMAN' | 'BAHRAIN' | 'MOROCCO'
  | 'SINGAPORE' | 'AUSTRALIA' | 'CHILE' | 'COLOMBIA' | 'PERU' | 'PANAMA'
  | 'CAFTA_DR' | 'JAPAN';

export interface AgreementMembership {
  key: AgreementKey;
  label: string;
  /** HTSUS special-program indicators that apply to THIS country under this agreement. */
  codes: readonly string[];
}

/** Canonical human labels — used when the UI renders an agreement badge. */
export const AGREEMENT_LABELS: Record<AgreementKey, string> = {
  USMCA: 'USMCA',
  KORUS: 'KORUS',
  ISRAEL: 'Israel FTA',
  JORDAN: 'Jordan FTA',
  OMAN: 'Oman FTA',
  BAHRAIN: 'Bahrain FTA',
  MOROCCO: 'Morocco FTA',
  SINGAPORE: 'SG FTA',
  AUSTRALIA: 'AU FTA',
  CHILE: 'Chile FTA',
  COLOMBIA: 'CO FTA',
  PERU: 'Peru FTA',
  PANAMA: 'Panama FTA',
  CAFTA_DR: 'CAFTA-DR',
  JAPAN: 'US-Japan',
};

/**
 * Census country code → list of agreement memberships with the HTSUS codes
 * that apply to that country specifically. The `codes` array is what we match
 * against the `programs` arrays inside `special_programs_json`.
 *
 * USMCA is deliberately split: Canada gets `S` / `S+` / `CA`; Mexico gets
 * `S` / `S+` / `MX`. A line marked with `CA` only does not qualify Mexico,
 * and vice versa.
 */
export const COUNTRY_MEMBERSHIPS: Record<string, readonly AgreementMembership[]> = {
  // USMCA
  '1220': [{ key: 'USMCA', label: 'USMCA', codes: ['S', 'S+', 'CA'] }],   // Canada
  '2010': [{ key: 'USMCA', label: 'USMCA', codes: ['S', 'S+', 'MX'] }],   // Mexico
  // CAFTA-DR
  '2050': [{ key: 'CAFTA_DR', label: 'CAFTA-DR', codes: ['P', 'P+'] }],   // Guatemala
  '2110': [{ key: 'CAFTA_DR', label: 'CAFTA-DR', codes: ['P', 'P+'] }],   // El Salvador
  '2150': [{ key: 'CAFTA_DR', label: 'CAFTA-DR', codes: ['P', 'P+'] }],   // Honduras
  '2190': [{ key: 'CAFTA_DR', label: 'CAFTA-DR', codes: ['P', 'P+'] }],   // Nicaragua
  '2230': [{ key: 'CAFTA_DR', label: 'CAFTA-DR', codes: ['P', 'P+'] }],   // Costa Rica
  '2470': [{ key: 'CAFTA_DR', label: 'CAFTA-DR', codes: ['P', 'P+'] }],   // Dominican Republic
  // Bilateral FTAs
  '2250': [{ key: 'PANAMA',    label: 'Panama FTA',  codes: ['PA'] }],    // Panama
  '3010': [{ key: 'COLOMBIA',  label: 'CO FTA',      codes: ['CO'] }],    // Colombia
  '3330': [{ key: 'PERU',      label: 'Peru FTA',    codes: ['PE'] }],    // Peru
  '3370': [{ key: 'CHILE',     label: 'Chile FTA',   codes: ['CL'] }],    // Chile
  '5081': [{ key: 'ISRAEL',    label: 'Israel FTA',  codes: ['IL'] }],    // Israel
  '5110': [{ key: 'JORDAN',    label: 'Jordan FTA',  codes: ['JO'] }],    // Jordan
  '5230': [{ key: 'OMAN',      label: 'Oman FTA',    codes: ['OM'] }],    // Oman
  '5250': [{ key: 'BAHRAIN',   label: 'Bahrain FTA', codes: ['BH'] }],    // Bahrain
  '5590': [{ key: 'SINGAPORE', label: 'SG FTA',      codes: ['SG'] }],    // Singapore
  '5800': [{ key: 'KORUS',     label: 'KORUS',       codes: ['KR'] }],    // South Korea
  '5880': [{ key: 'JAPAN',     label: 'US-Japan',    codes: ['JP'] }],    // Japan (limited)
  '6021': [{ key: 'AUSTRALIA', label: 'AU FTA',      codes: ['AU'] }],    // Australia
  '7140': [{ key: 'MOROCCO',   label: 'Morocco FTA', codes: ['MA'] }],    // Morocco
};

/** Flat set of every HTSUS program indicator that applies to this country. */
export function programCodesForCountry(countryCode: string | null | undefined): Set<string> {
  if (!countryCode) return new Set();
  const memberships = COUNTRY_MEMBERSHIPS[countryCode] ?? [];
  const out = new Set<string>();
  for (const m of memberships) for (const c of m.codes) out.add(c);
  return out;
}

/** True iff importing from this country can claim USMCA. */
export function isUSMCACountry(countryCode: string | null | undefined): boolean {
  return countryCode === '1220' || countryCode === '2010';
}

// =============================================================================
// Per-row agreement applicability
// =============================================================================

export type AgreementStatus = 'active' | 'inactive' | 'not_applicable';

export interface AppliedAgreement {
  key: AgreementKey;
  label: string;
  /** The preferential rate offered by the HTS for this program, or null if no rate entry. */
  rate: number | null;
  /** Did the HTS list any code for this agreement that applies to this country? */
  listedOnHTS: boolean;
  /** Agreement status for this (country, product) pair. */
  status: AgreementStatus;
}

/**
 * Return agreement status for every agreement this country is party to.
 *   - `active`       → HTS lists at least one code that applies to this country.
 *   - `inactive`     → country qualifies but the HTS does not cover this product.
 *
 * `not_applicable` would be for agreements the country does not belong to;
 * those are never emitted (we only return memberships), so callers who want
 * to render "Not a party to X" should compare against the full AGREEMENT_LABELS
 * list rather than this function's output. For most UI purposes, silence
 * (no chip) is the right rendering of "not a party".
 */
export function getAgreementStatus(
  countryCode: string | null | undefined,
  rate: Pick<ProductRate, 'special_programs_json'>,
): AppliedAgreement[] {
  if (!countryCode) return [];
  const memberships = COUNTRY_MEMBERSHIPS[countryCode] ?? [];
  if (memberships.length === 0) return [];

  const htsEntries: SpecialProgramEntry[] = parseSpecialPrograms(rate.special_programs_json);

  return memberships.map(m => {
    const applicableCodes: readonly string[] = m.codes;
    let listedOnHTS = false;
    let htsRate: number | null = null;
    for (const entry of htsEntries) {
      if (entry.programs.some(p => applicableCodes.includes(p))) {
        listedOnHTS = true;
        if (entry.entry_type === 'rate' && entry.rate != null) {
          htsRate = entry.rate;
          break;
        }
      }
    }
    return {
      key: m.key,
      label: m.label,
      rate: htsRate,
      listedOnHTS,
      status: listedOnHTS ? 'active' : 'inactive',
    };
  });
}
