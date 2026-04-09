import React, { useState } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { TariffProgramBadge } from './TariffProgramBadge';
import type { ProductRate, AuthorityKey } from '@/types/tariff';
import { AUTHORITIES, AUTHORITY_MAP, MFN_COLOR, STACK_COLORS, STATUTORY_KEY_MAP, hasStatutoryDelta } from '@/types/tariff';
import { formatRate, formatRateShort, formatHtsCode, formatDate } from '@/utils/formatters';
import {
  Layers, Shield, Info, ChevronDown, ChevronUp, ShieldCheck,
  AlertTriangle, Scale, FileText,
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
      <div className="h-3 bg-gray-100 rounded-full overflow-hidden flex">
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
            <span className="text-[10px] text-gray-500">{s.label} {formatRateShort(s.value)}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function PunitiveCard({
  authorityKey, rate, statutoryRate, label, ch99Prefix, color, bgClass, textClass, borderClass,
}: {
  authorityKey: AuthorityKey; rate: number; statutoryRate?: number; label: string;
  ch99Prefix?: string; color: string; bgClass: string; textClass: string; borderClass: string;
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

export function DutyStackBreakdown({ rate, countryName, label }: DutyStackBreakdownProps) {
  const activeAuthorities = AUTHORITIES.filter(a => rate[a.key] > 0);
  const exemptAuthorities = AUTHORITIES.filter(a => rate[a.key] === 0 && a.key !== 'rate_other' && a.key !== 'rate_section_201');
  const [showExempt, setShowExempt] = useState(false);

  return (
    <Card>
      <CardContent className="p-5 space-y-4">
        {/* Header */}
        <div className="flex items-start justify-between">
          <div>
            <div className="flex items-center gap-2 mb-1">
              <Layers className="h-4 w-4 text-[#353CED]" />
              <h3 className="font-semibold text-sm text-gray-900">
                {label ?? 'Duty Breakdown'}
              </h3>
            </div>
            <div className="text-2xl font-bold font-mono text-gray-900 tracking-wide">
              {formatHtsCode(rate.hts10)}
            </div>
            <div className="text-xs text-gray-500 mt-0.5">
              {countryName} &middot; {formatDate(rate.valid_from)} – {formatDate(rate.valid_until)}
            </div>
          </div>
          <div className="text-right">
            <div className="text-[10px] font-medium text-gray-400 uppercase tracking-wider">Revision</div>
            <div className="text-xs font-mono text-gray-600">{rate.revision}</div>
          </div>
        </div>

        {/* Total Effective Bar */}
        <TotalEffectiveBar rate={rate} />

        {/* MFN Base Rate */}
        <div className="rounded-lg border border-blue-200 p-3">
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
                    Statutory: {formatRateShort(rate.statutory_base_rate)} → Effective: {formatRateShort(rate.base_rate)}
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
              return (
                <PunitiveCard
                  key={a.key}
                  authorityKey={a.key}
                  rate={rate[a.key]}
                  statutoryRate={Math.abs(statutoryVal - rate[a.key]) > 0.00001 ? statutoryVal : undefined}
                  label={a.label}
                  ch99Prefix={a.ch99Prefix}
                  color={a.color}
                  bgClass={a.bgClass}
                  textClass={a.textClass}
                  borderClass={a.borderClass}
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
            <Shield className="h-3 w-3 mr-1" /> Ad Valorem basis
          </Badge>
          {activeAuthorities.length > 0 && (
            <Badge variant="outline" className="text-[10px] bg-gray-50 text-gray-600 border-gray-200">
              Mutual exclusion stacking
            </Badge>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
