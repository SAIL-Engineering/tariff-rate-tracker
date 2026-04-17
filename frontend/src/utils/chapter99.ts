// =============================================================================
// Chapter 99 (Additional Tariffs) utilities
// =============================================================================
// Broker / ACE return files frequently split a single physical line-item
// across multiple rows: one row carries the main chapter 1-97 classification
// (with the MFN base duty) and additional rows carry Chapter 99 codes —
// Section 232, 301, IEEPA, etc. — each with the duty amount that specific
// authority contributed.
//
// Example (one physical line across two broker rows):
//
//   Entry 90247820, Invoice Line 1, Part TCU0115F_A07
//     Row A: HTS 8534.00.95  (Printed circuits)     Duty $0.00
//     Row B: HTS 9903.02.20  (IEEPA Reciprocal 15%) Duty $2,757.90
//
// Row B's HTS does not exist in the rate matrix — 9903 is a tariff program,
// not a classification — so the rate lookup correctly returns nothing. The
// *right* thing to do is:
//   1. Detect chapter 99 rows and skip the rate lookup for them.
//   2. Map the 9903.xx subheading to a SAIL authority key.
//   3. Attribute the row's broker-reported duty to that authority, then fold
//      it into the main row's merged line item for per-authority reconciliation.
//
// Mapping source: the ch99Prefix metadata on each AUTHORITIES entry in
// types/tariff.ts plus the stacking documentation in tariffCalculator.ts.

import type { AuthorityKey, ProductRate, AuthorityInfo } from '@/types/tariff';

/**
 * Resolve the specific 8-digit Chapter 99 code to display for a given
 * authority on a given ProductRate row. Prefers the per-row ch99_code_*
 * field populated by the backend resolver; falls back to the static range
 * label on AuthorityInfo when the row field is missing (e.g., older JSONs
 * regenerated before the backend change). Returns the formatted code.
 */
export function resolveCh99Code(
  rate: ProductRate | undefined | null,
  authority: AuthorityInfo,
): string | undefined {
  if (!rate) return authority.ch99Prefix;
  const keyMap: Partial<Record<AuthorityKey, keyof ProductRate>> = {
    rate_232: 'ch99_code_232',
    rate_301: 'ch99_code_301',
    rate_ieepa_recip: 'ch99_code_ieepa_recip',
    rate_ieepa_fent: 'ch99_code_ieepa_fent',
    rate_s122: 'ch99_code_s122',
    rate_section_201: 'ch99_code_s201',
  };
  const field = keyMap[authority.key];
  const raw = field ? (rate[field] as string | null | undefined) : undefined;
  if (raw && typeof raw === 'string' && raw.length > 0) {
    return formatCh99Display(raw);
  }
  return authority.ch99Prefix;
}

/**
 * True when an HTS code is a Chapter 99 "additional duties" code.
 * Accepts both dot-formatted and digits-only inputs.
 */
export function isChapter99(hts: string | null | undefined): boolean {
  if (!hts) return false;
  return hts.replace(/\./g, '').startsWith('99');
}

/**
 * Map a 10-digit Chapter 99 HTS code to the SAIL authority it represents.
 * Returns null if the code is not a recognised chapter 99 program.
 *
 * Subheading layout within 9903:
 *   9903.01.01 – 9903.01.24  → IEEPA Fentanyl
 *   9903.01.25 – 9903.01.76  → IEEPA Reciprocal
 *   9903.02.xx               → IEEPA Reciprocal
 *   9903.03.xx               → Section 122
 *   9903.40.xx – 9903.45.xx  → Section 201
 *   9903.80.xx – 9903.85.xx  → Section 232
 *   9903.88.xx               → Section 301
 *   9903.94.xx               → Section 232 (derivative articles)
 */
export function ch99ToAuthority(hts: string | null | undefined): AuthorityKey | null {
  if (!hts) return null;
  const d = hts.replace(/\./g, '');
  if (d.length < 6 || !d.startsWith('9903')) return null;

  const heading = Number(d.substring(4, 6));
  const sub = d.length >= 8 ? Number(d.substring(6, 8)) : 0;

  // 9903.01 is split between fentanyl and reciprocal by sub-heading.
  if (heading === 1) {
    if (sub >= 1 && sub <= 24) return 'rate_ieepa_fent';
    if (sub >= 25 && sub <= 76) return 'rate_ieepa_recip';
    return null;
  }
  if (heading === 2) return 'rate_ieepa_recip';
  if (heading === 3) return 'rate_s122';
  if (heading >= 40 && heading <= 45) return 'rate_section_201';
  if (heading >= 80 && heading <= 85) return 'rate_232';
  if (heading === 88) return 'rate_301';
  if (heading === 94) return 'rate_232';
  return null;
}

/**
 * Human-readable label for a chapter 99 authority.
 * Used in variance rows and the detail drawer.
 */
export function authorityLabel(key: AuthorityKey): string {
  switch (key) {
    case 'rate_232':
      return 'Section 232';
    case 'rate_301':
      return 'Section 301';
    case 'rate_ieepa_recip':
      return 'IEEPA Reciprocal';
    case 'rate_ieepa_fent':
      return 'Anti-Fentanyl (IEEPA)';
    case 'rate_s122':
      return 'Section 122';
    case 'rate_section_201':
      return 'Section 201';
    case 'rate_other':
      return 'Other Ch. 99';
  }
}

/**
 * Short authority label for dense grid rows.
 */
export function authorityShortLabel(key: AuthorityKey): string {
  switch (key) {
    case 'rate_232':
      return '§232';
    case 'rate_301':
      return '§301';
    case 'rate_ieepa_recip':
      return 'IEEPA Recip.';
    case 'rate_ieepa_fent':
      return 'IEEPA Fent.';
    case 'rate_s122':
      return '§122';
    case 'rate_section_201':
      return '§201';
    case 'rate_other':
      return 'Other';
  }
}

/**
 * Format a digits-only chapter 99 HTS as 9903.XX.YY.
 */
export function formatCh99Display(hts: string): string {
  const d = hts.replace(/\./g, '');
  if (d.length <= 4) return d;
  if (d.length <= 6) return `${d.slice(0, 4)}.${d.slice(4)}`;
  if (d.length <= 8) return `${d.slice(0, 4)}.${d.slice(4, 6)}.${d.slice(6)}`;
  return `${d.slice(0, 4)}.${d.slice(4, 6)}.${d.slice(6, 8)}`;
}
