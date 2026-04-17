import React, { useState } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { TariffProgramBadge } from './TariffProgramBadge';
import type { ProductRate, AuthorityKey, SpecialProgramEntry } from '@/types/tariff';
import { AUTHORITIES, AUTHORITY_MAP, MFN_COLOR, STACK_COLORS, STATUTORY_KEY_MAP, hasStatutoryDelta, parseSpecialPrograms } from '@/types/tariff';
import { formatRate, formatRateShort, formatHtsCode, formatDate } from '@/utils/formatters';
import { computeNonmetalShare, computeNetAuthorityAmounts, CLASSIFICATION_COMPOSITION_CHAPTERS } from '@/utils/tariffCalculator';
import { resolveCh99Code } from '@/utils/chapter99';
import {
  Layers, Shield, Info, ChevronDown, ChevronUp, ShieldCheck,
  AlertTriangle, Scale, FileText, Beaker,
} from 'lucide-react';
import { cn } from '@/lib/utils';

interface DutyStackBreakdownProps {
  rate: ProductRate;
  countryName: string;
  label?: string;
}

function TotalEffectiveBar({ rate }: { rate: ProductRate }) {
  const total = rate.total_rate;
  if (total <= 0) return null;

  const segments: Array<{ key: string; value: number; color: string; label: string }> = [];

  if (rate.base_rate > 0) {
    segments.push({ key: 'mfn', value: rate.base_rate, color: MFN_COLOR, label: 'MFN' });
  }

  for (const a of AUTHORITIES) {
    const v = rate[a.key];
    if (v > 0) {
      segments.push({ key: a.key, value: v, color: a.color, label: a.shortLabel });
    }
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between">
        <span className="text-xs font-medium text-gray-700">Total Effective Rate</span>
        <span className="text-lg font-bold text-[#353CED]">{formatRateShort(total)}</span>
      </div>
      <div className="h-2.5 bg-gray-100 rounded-full overflow-hidden flex">
        {segments.map((s, i) => (
          <div key={s.key}
            className={cn('h-full transition-all duration-500', i === 0 && 'rounded-l-full', i === segments.length - 1 && 'rounded-r-full')}
            style={{ width: `${(s.value / total) * 100}%`, backgroundColor: s.color }}
          />
        ))}
      </div>
      <div className="flex flex-wrap gap-x-3 gap-y-1">
        {segments.map(s => (
          <div key={s.key} className="flex items-center gap-1.5">
            <div className="w-2 h-2 rounded-sm" style={{ backgroundColor: s.color }} />
            <span className="text-[10px] text-gray-500">{s.label} {s.key === 'mfn' ? formatRate(s.value) : formatRateShort(s.value)}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function PunitiveCard({
  authorityKey, rate, statutoryRate, label, ch99Prefix, color, bgClass, textClass, borderClass,
  netRate, nonmetalShare,
}: {
  authorityKey: AuthorityKey; rate: number; statutoryRate?: number; label: string;
  ch99Prefix?: string; color: string; bgClass: string; textClass: string; borderClass: string;
  netRate?: number; nonmetalShare?: number;
}) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className={cn('rounded-lg border p-3 transition-all', borderClass, expanded && 'shadow-sm')}>
      <div className="flex items-center justify-between cursor-pointer" onClick={() => setExpanded(!expanded)}>
        <div className="flex items-center gap-2 min-w-0">
          <div className="w-1 h-8 rounded-full flex-shrink-0" style={{ backgroundColor: color }} />
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <Badge variant="outline" className={cn('text-[10px] font-medium', bgClass, textClass, borderClass)}>
                Ch. 99
              </Badge>
              <span className="text-sm font-medium text-gray-900">{label}</span>
            </div>
            {ch99Prefix && (
              <span className="text-[10px] font-mono text-[#353CED] mt-0.5 block">{ch99Prefix}</span>
            )}
            {statutoryRate != null && Math.abs(statutoryRate - rate) > 0.00001 && (
              <span className="text-[10px] text-gray-400 mt-0.5 block">
                Statutory: {formatRateShort(statutoryRate)} → Effective: {formatRateShort(rate)}
              </span>
            )}
            {netRate != null && nonmetalShare != null && Math.abs(netRate - rate) > 0.00001 && (
              <span className="text-[10px] text-amber-600 mt-0.5 block">
                Net: {formatRateShort(netRate)} (scaled by {(nonmetalShare * 100).toFixed(0)}% non-metal)
              </span>
            )}
          </div>
        </div>
        <div className="flex items-center gap-2 flex-shrink-0">
          <span className="text-sm font-bold font-mono text-gray-900">{formatRate(rate)}</span>
          {ch99Prefix && (
            expanded
              ? <ChevronUp className="h-3.5 w-3.5 text-gray-400" />
              : <ChevronDown className="h-3.5 w-3.5 text-gray-400" />
          )}
        </div>
      </div>

      {expanded && ch99Prefix && (
        <div className="mt-3 pt-3 border-t border-gray-100 space-y-2 ml-3 pl-3 border-l-2 border-gray-100">
          <div className="flex items-center gap-1.5 text-xs text-gray-600">
            <FileText className="h-3 w-3 text-gray-400" />
            <span className="font-medium">Chapter 99 Reference:</span>
            <span className="font-mono text-[#353CED]">{ch99Prefix}</span>
          </div>
          <div className="flex items-center gap-1.5 text-xs text-gray-600">
            <Scale className="h-3 w-3 text-gray-400" />
            <span>Application: Ad Valorem — {formatRateShort(rate)} of customs value</span>
          </div>
          {authorityKey === 'rate_232' && (
            <div className="flex items-center gap-1.5 text-xs text-sky-600 italic">
              <Info className="h-3 w-3" />
              <span>Takes precedence over IEEPA on metal-covered portion (mutual exclusion)</span>
            </div>
          )}
          {authorityKey === 'rate_301' && (
            <div className="flex items-center gap-1.5 text-xs text-sky-600 italic">
              <Info className="h-3 w-3" />
              <span>Applies to China-origin products only</span>
            </div>
          )}
          {authorityKey === 'rate_s122' && (
            <div className="flex items-center gap-1.5 text-xs text-sky-600 italic">
              <AlertTriangle className="h-3 w-3" />
              <span>Temporary — expires Jul 23, 2026 (150-day statutory limit)</span>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function RateTiersCard({ rate }: { rate: ProductRate }) {
  const specialEntries = parseSpecialPrograms(rate.special_programs_json);
  const hasSpecial = specialEntries.length > 0;
  const hasColumn2 = rate.rate_column2 != null || (rate.rate_column2_raw && rate.rate_column2_raw !== '');

  if (!hasSpecial && !hasColumn2) return null;

  return (
    <div className="rounded-lg border border-gray-200 p-3 space-y-2">
      <div className="text-xs font-medium text-gray-500 uppercase tracking-wider flex items-center gap-1.5">
        <Scale className="h-3 w-3" />
        HTS Rate Tiers
      </div>

      {/* Column 1 General */}
      <div className="flex items-center justify-between text-xs">
        <div className="flex items-center gap-2">
          <div className="w-2 h-2 rounded-full" style={{ backgroundColor: MFN_COLOR }} />
          <span className="text-gray-700">Column 1 (General)</span>
        </div>
        <span className="font-mono font-medium text-gray-900">
          {(rate.rate_basis === 'specific' || rate.rate_basis === 'compound') && rate.specific_amount != null
            ? `$${rate.specific_amount}/${rate.specific_rate_unit ?? 'unit'}${rate.rate_basis === 'compound' ? ` + ${formatRate(rate.base_rate)}` : ''}`
            : formatRate(rate.base_rate)}
        </span>
      </div>

      {/* Column 1 Special */}
      {hasSpecial && (
        <div className="space-y-1">
          {specialEntries.map((entry, idx) => (
            <div key={idx} className="flex items-center justify-between text-xs">
              <div className="flex items-center gap-2 min-w-0 flex-1">
                <div className="w-2 h-2 rounded-full flex-shrink-0" style={{ backgroundColor: '#16a34a' }} />
                <span className="text-gray-700 flex-shrink-0">
                  {idx === 0 ? 'Column 1 (Special)' : ''}
                </span>
                <div className="flex flex-wrap gap-0.5">
                  {entry.programs.map(p => (
                    <Badge key={p} variant="outline" className="text-[9px] px-1 py-0 bg-green-50 text-green-700 border-green-200">
                      {p}
                    </Badge>
                  ))}
                </div>
              </div>
              <span className="font-mono font-medium text-gray-900 flex-shrink-0 ml-2">
                {entry.entry_type === 'reference'
                  ? <span className="text-[10px] text-gray-500 italic">{entry.rate_raw}</span>
                  : entry.rate_raw || (entry.rate != null ? formatRateShort(entry.rate) : '—')}
              </span>
            </div>
          ))}
        </div>
      )}

      {/* Column 2 */}
      {hasColumn2 && (
        <div className="flex items-center justify-between text-xs">
          <div className="flex items-center gap-2">
            <div className="w-2 h-2 rounded-full" style={{ backgroundColor: '#d97706' }} />
            <span className="text-gray-700">Column 2</span>
            <span className="text-[10px] text-gray-400">(CU, KP, BY, RU)</span>
          </div>
          <span className="font-mono font-medium text-gray-900">
            {rate.rate_column2_raw || (rate.rate_column2 != null ? formatRateShort(rate.rate_column2) : '—')}
          </span>
        </div>
      )}
    </div>
  );
}

export function DutyStackBreakdown({ rate, countryName, label }: DutyStackBreakdownProps) {
  const activeAuthorities = AUTHORITIES.filter(a => rate[a.key] > 0);
  const exemptAuthorities = AUTHORITIES.filter(a => rate[a.key] === 0 && a.key !== 'rate_other' && a.key !== 'rate_section_201');
  const [showExempt, setShowExempt] = useState(false);

  // Compute stacking for display
  const nonmetalShare = computeNonmetalShare(rate);
  const netAmounts = computeNetAuthorityAmounts(rate, rate.country);
  const ch2 = rate.hts10.substring(0, 2);
  const classificationNote = CLASSIFICATION_COMPOSITION_CHAPTERS[ch2];

  return (
    <Card>
      <CardContent className="p-5 space-y-4">
        {/* Header */}
        <div className="flex items-start justify-between">
          <div>
            <div className="flex items-center gap-2 mb-1.5">
              <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
                <Layers className="h-3.5 w-3.5 text-[#353CED]" />
              </div>
              <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">
                {label ?? 'Duty Breakdown'}
              </h3>
            </div>
            <div className="text-2xl font-bold font-mono text-gray-900 tracking-tight tabular-nums">
              {formatHtsCode(rate.hts10)}
            </div>
            <div className="text-[11px] text-gray-500 mt-1">
              {countryName} &middot; {formatDate(rate.valid_from)} – {formatDate(rate.valid_until)}
            </div>
          </div>
          <div className="text-right">
            <div className="text-[10px] font-medium text-gray-400 uppercase tracking-wider">Revision</div>
            <div className="text-xs font-mono text-gray-500 mt-0.5">{rate.revision}</div>
          </div>
        </div>

        {/* Total Effective Bar */}
        <TotalEffectiveBar rate={rate} />

        {/* HTS Rate Tiers: Column 1 General / Column 1 Special / Column 2 */}
        <RateTiersCard rate={rate} />

        {/* MFN Base Rate */}
        <div className="rounded-xl border border-blue-200/60 p-3 bg-blue-50/20">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <div className="w-1 h-8 rounded-full" style={{ backgroundColor: MFN_COLOR }} />
              <div>
                <div className="flex items-center gap-2">
                  <Badge variant="outline" className="text-[10px] bg-blue-50 text-blue-700 border-blue-200">Base</Badge>
                  <span className="text-sm font-medium text-gray-900">MFN Duty Rate</span>
                </div>
                {rate.statutory_base_rate !== rate.base_rate && (
                  <span className="text-[10px] text-gray-400 ml-[calc(0.25rem+1px)]">
                    Statutory: {formatRate(rate.statutory_base_rate)} → Effective: {formatRate(rate.base_rate)}
                  </span>
                )}
              </div>
            </div>
            <span className="text-sm font-bold font-mono text-gray-900">{formatRate(rate.base_rate)}</span>
          </div>
        </div>

        {/* Active punitive rates */}
        {activeAuthorities.length > 0 && (
          <div className="space-y-2">
            <div className="text-xs font-medium text-gray-500 uppercase tracking-wider flex items-center gap-1.5">
              <AlertTriangle className="h-3 w-3" />
              Active Additional Duties ({activeAuthorities.length})
            </div>
            {activeAuthorities.map(a => {
              const statutoryKey = STATUTORY_KEY_MAP[a.key];
              const statutoryVal = rate[statutoryKey] ?? 0;
              const netVal = netAmounts[a.key];
              const isScaled = rate[a.key] > 0 && Math.abs(netVal - rate[a.key]) > 0.00001;
              return (
                <PunitiveCard
                  key={a.key}
                  authorityKey={a.key}
                  rate={rate[a.key]}
                  statutoryRate={Math.abs(statutoryVal - rate[a.key]) > 0.00001 ? statutoryVal : undefined}
                  label={a.label}
                  ch99Prefix={resolveCh99Code(rate, a)}
                  color={a.color}
                  bgClass={a.bgClass}
                  textClass={a.textClass}
                  borderClass={a.borderClass}
                  netRate={isScaled ? netVal : undefined}
                  nonmetalShare={isScaled ? nonmetalShare : undefined}
                />
              );
            })}
          </div>
        )}

        {/* Exempt rates (collapsed) */}
        {exemptAuthorities.length > 0 && (
          <div>
            <button onClick={() => setShowExempt(!showExempt)}
              className="flex items-center gap-1.5 text-xs text-gray-400 hover:text-gray-600 transition-colors">
              <ShieldCheck className="h-3.5 w-3.5 text-emerald-500" />
              <span>Exempt — {exemptAuthorities.length} authorities not applicable</span>
              {showExempt ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
            </button>
            {showExempt && (
              <div className="mt-2 space-y-1 ml-5">
                {exemptAuthorities.map(a => (
                  <div key={a.key} className="flex items-center justify-between text-xs text-gray-400 py-1">
                    <div className="flex items-center gap-2">
                      <div className="w-2 h-2 rounded-full bg-gray-200" />
                      <span className="line-through">{a.label}</span>
                    </div>
                    <Badge variant="outline" className="text-[10px] bg-emerald-50 text-emerald-600 border-emerald-200">$0</Badge>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}

        {/* Metadata badges */}
        <div className="flex flex-wrap gap-2 pt-3 border-t border-gray-100">
          {rate.usmca_eligible && (
            <TariffProgramBadge label="USMCA Eligible" className="bg-emerald-50 text-emerald-700 border-emerald-200" />
          )}
          {rate.metal_share < 1 && rate.metal_share > 0 && (
            <Badge variant="outline" className="text-[10px] bg-gray-50 text-gray-600 border-gray-200">
              Metal content: {(rate.metal_share * 100).toFixed(0)}%
            </Badge>
          )}
          <Badge variant="outline" className="text-[10px] bg-gray-50 text-gray-600 border-gray-200">
            <Shield className="h-3 w-3 mr-1" />
            {rate.rate_basis === 'specific' ? 'Specific duty' :
             rate.rate_basis === 'compound' ? 'Compound duty' :
             rate.rate_basis === 'free' ? 'Duty free' : 'Ad Valorem basis'}
          </Badge>
          {rate.is_qty_duty_relevant && rate.duty_basis_unit && (
            <Badge variant="outline" className="text-[10px] bg-amber-50 text-amber-700 border-amber-200">
              Duty unit: {rate.duty_basis_unit}
            </Badge>
          )}
          {rate.reported_unit_1 && (
            <Badge variant="outline" className="text-[10px] bg-gray-50 text-gray-600 border-gray-200">
              Reporting: {rate.reported_unit_1}{rate.reported_unit_2 ? `, ${rate.reported_unit_2}` : ''}
            </Badge>
          )}
          {rate.rate_232 > 0 && nonmetalShare > 0 && (
            <Badge variant="outline" className="text-[10px] bg-amber-50 text-amber-700 border-amber-200">
              232 covers {((1 - nonmetalShare) * 100).toFixed(0)}% metal; IEEPA/S122 on {(nonmetalShare * 100).toFixed(0)}% non-metal
            </Badge>
          )}
          {rate.rate_232 > 0 && nonmetalShare === 0 && rate.metal_share >= 1 && (
            <Badge variant="outline" className="text-[10px] bg-amber-50 text-amber-700 border-amber-200">
              232 takes full precedence (pure metal product)
            </Badge>
          )}
        </div>

        {/* Classification composition info (19 CFR 141.89) — informational only */}
        {classificationNote && (
          <div className="flex items-start gap-2 rounded-lg bg-slate-50 px-3 py-2">
            <Beaker className="h-3.5 w-3.5 text-gray-400 mt-0.5 flex-shrink-0" />
            <div className="text-[10px] text-gray-500 leading-relaxed">
              <span className="font-medium text-gray-600">Classification note:</span> {classificationNote}
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
