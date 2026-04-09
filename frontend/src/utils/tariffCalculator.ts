import type { ProductRate, DutyBreakdown, LandedCostResult, AuthorityKey } from '@/types/tariff';
import { AUTHORITY_MAP } from '@/types/tariff';
import { formatDate } from '@/utils/formatters';

export const MPF_RATE = 0.003464;
export const MPF_MIN = 31.67;
export const MPF_MAX = 614.35;
export const HMF_RATE = 0.00125;

export function calculateMPF(customsValue: number): number {
  const raw = customsValue * MPF_RATE;
  return Math.min(Math.max(raw, MPF_MIN), MPF_MAX);
}

export function calculateHMF(customsValue: number): number {
  return customsValue * HMF_RATE;
}

export function calculateLandedCost(
  rate: ProductRate,
  customsValue: number,
  options?: { includeHMF?: boolean; freight?: number; insurance?: number }
): LandedCostResult {
  const includeHMF = options?.includeHMF ?? true;
  const freight = options?.freight ?? 0;
  const insurance = options?.insurance ?? 0;

  const baseDuty = customsValue * rate.base_rate;
  const additionalDuty = customsValue * rate.total_additional;
  const totalDuty = customsValue * rate.total_rate;

  const breakdown: DutyBreakdown[] = [];

  if (rate.base_rate > 0) {
    breakdown.push({
      authority: 'MFN Base Rate',
      rate: rate.base_rate,
      dutyAmount: baseDuty,
      color: '#008dff',
    });
  }

  const authorityKeys: AuthorityKey[] = [
    'rate_232', 'rate_301', 'rate_ieepa_recip',
    'rate_ieepa_fent', 'rate_s122', 'rate_section_201', 'rate_other',
  ];

  for (const key of authorityKeys) {
    const value = rate[key];
    if (value > 0) {
      const info = AUTHORITY_MAP[key];
      breakdown.push({
        authority: info.label,
        rate: value,
        dutyAmount: customsValue * value,
        color: info.color,
        ch99Code: info.ch99Prefix,
      });
    }
  }

  const mpf = calculateMPF(customsValue);
  const hmf = includeHMF ? calculateHMF(customsValue) : 0;
  const totalFees = mpf + hmf;
  const landedCost = customsValue + totalDuty + totalFees + freight + insurance;

  return {
    customsValue,
    totalDutyRate: rate.total_rate,
    totalDuty,
    baseRate: rate.base_rate,
    baseDuty,
    additionalRate: rate.total_additional,
    additionalDuty,
    breakdown,
    mpf,
    hmf,
    totalFees,
    landedCost,
    ratePeriod: `${formatDate(rate.valid_from)} – ${formatDate(rate.valid_until)}`,
  };
}

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
      .filter(b => b.authority !== 'MFN Base Rate')
      .flatMap(b => [`${b.authority} Rate (%)`, `${b.authority} Duty (USD)`]) ?? [],
    'Total Rate (%)', 'Total Duty (USD)',
    'MPF (USD)', 'HMF (USD)', 'Total Fees (USD)',
    'Landed Cost (USD)',
  ];

  const csvRows = rows.map(({ date, result: r }) => {
    const mfnLine = r.breakdown.find(b => b.authority === 'MFN Base Rate');
    const punitive = r.breakdown.filter(b => b.authority !== 'MFN Base Rate');
    return [
      date.toISOString().slice(0, 10), htsCode, countryName,
      r.customsValue.toFixed(2), r.ratePeriod,
      ((mfnLine?.rate ?? 0) * 100).toFixed(2), (mfnLine?.dutyAmount ?? 0).toFixed(2),
      ...punitive.flatMap(b => [(b.rate * 100).toFixed(2), b.dutyAmount.toFixed(2)]),
      (r.totalDutyRate * 100).toFixed(2), r.totalDuty.toFixed(2),
      r.mpf.toFixed(2), r.hmf.toFixed(2), r.totalFees.toFixed(2),
      r.landedCost.toFixed(2),
    ];
  });

  // Totals row
  const totals = rows.reduce(
    (acc, { result: r }) => ({
      cv: acc.cv + r.customsValue, duty: acc.duty + r.totalDuty,
      mpf: acc.mpf + r.mpf, hmf: acc.hmf + r.hmf,
      fees: acc.fees + r.totalFees, landed: acc.landed + r.landedCost,
    }),
    { cv: 0, duty: 0, mpf: 0, hmf: 0, fees: 0, landed: 0 }
  );

  const totalsRow = ['TOTALS', '', '', totals.cv.toFixed(2), '',
    '', '', // MFN placeholders
    ...rows[0]?.result.breakdown.filter(b => b.authority !== 'MFN Base Rate').flatMap(() => ['', '']) ?? [],
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
