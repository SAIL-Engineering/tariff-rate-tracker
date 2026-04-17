// =============================================================================
// BulkResultsGrid — three-level hierarchical reconciliation tree
// =============================================================================
// Level 1: Entry (or Shipment) — parent group
// Level 2: Merged Line Item — physical line after Chapter 99 reconciliation
// Level 3: Authority Stack Row — Base / 232 / 301 / IEEPA / 122 / 201 /
//          Other Ch. 99 / MPF / HMF — each showing SAIL rate+amount,
//          Broker rate+amount, and variance. Mirrors DutyCalculatorPanel's
//          expandable duty-stack view.
//
// Visual system:
//   - Group rows    → 48px, gradient background, primary accent icon badge
//   - Line rows     → 44px, white, hover reveals expand affordance
//   - Stack rows    → 32px, slate-50/40 background, color-coded auth dots
//   - Column header → 10px uppercase tracking-[0.08em], gray-500, semibold
//   - Numeric cells → font-mono tabular-nums text-[11px]

import React, { useMemo, useRef, useState, useCallback } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import {
  ChevronRight,
  ChevronDown,
  Package,
  Layers,
  AlertTriangle,
  AlertCircle,
  Info,
  TrendingUp,
  TrendingDown,
  Minus,
  Inbox,
} from 'lucide-react';
import type {
  DutyResultRow,
  EntryGroup,
  ShipmentGroup,
  ExceptionFlag,
  MergedLineItem,
  AuthorityStackEntry,
} from '@/types/bulk';
import {
  formatCurrency,
  formatCurrencyCompact,
  formatDate,
  formatHtsCode,
  formatRateShort,
} from '@/utils/formatters';
import { cn } from '@/lib/utils';

// -----------------------------------------------------------------------------
// Public props
// -----------------------------------------------------------------------------

export type ReviewView = 'results' | 'reconciliation' | 'exceptions';
export type GroupBy = 'entry' | 'shipment';

interface Props {
  rows: DutyResultRow[];
  lineItems: MergedLineItem[];
  entries: EntryGroup[];
  shipments: ShipmentGroup[];
  view: ReviewView;
  groupBy: GroupBy;
  onLineClick?: (lineItem: MergedLineItem) => void;
}

// -----------------------------------------------------------------------------
// Tree item — flattened for virtualization
// -----------------------------------------------------------------------------

type TreeItem =
  | { kind: 'group'; group: EntryGroup; expanded: boolean }
  | { kind: 'line'; line: MergedLineItem; expanded: boolean }
  | { kind: 'stack'; stack: AuthorityStackEntry; line: MergedLineItem; last: boolean };

// -----------------------------------------------------------------------------
// Severity helpers
// -----------------------------------------------------------------------------

type Severity = 'match' | 'minor' | 'material' | 'critical' | 'no_upload';

function severityBar(sev: Severity): string {
  switch (sev) {
    case 'critical':
      return 'bg-red-500';
    case 'material':
      return 'bg-amber-500';
    case 'minor':
      return 'bg-yellow-500';
    case 'match':
      return 'bg-emerald-500';
    default:
      return 'bg-gray-200';
  }
}

function severityText(sev: Severity): string {
  switch (sev) {
    case 'critical':
      return 'text-red-600';
    case 'material':
      return 'text-amber-600';
    case 'minor':
      return 'text-yellow-700';
    case 'match':
      return 'text-emerald-600';
    default:
      return 'text-gray-400';
  }
}

function severityTint(sev: Severity): string {
  switch (sev) {
    case 'critical':
      return 'bg-red-50/45';
    case 'material':
      return 'bg-amber-50/35';
    case 'minor':
      return 'bg-yellow-50/30';
    case 'match':
      return 'bg-emerald-50/15';
    default:
      return '';
  }
}

function groupVarianceSeverity(g: EntryGroup): Severity {
  if (g.totalUploadedDuty == null) return 'no_upload';
  const abs = Math.abs(g.dutyVariance ?? 0);
  const pct =
    g.totalUploadedDuty > 0
      ? Math.abs((g.dutyVariance ?? 0) / g.totalUploadedDuty) * 100
      : 0;
  if (abs < 1) return 'match';
  if (abs < 50 && pct < 1) return 'minor';
  if (abs < 500 && pct < 5) return 'material';
  return 'critical';
}

function varianceArrow(v: number | null | undefined) {
  if (v == null || Math.abs(v) < 0.01) return <Minus className="h-3 w-3 text-gray-400" strokeWidth={2} />;
  if (v > 0) return <TrendingUp className="h-3 w-3 text-red-500" strokeWidth={2} />;
  return <TrendingDown className="h-3 w-3 text-emerald-500" strokeWidth={2} />;
}

// -----------------------------------------------------------------------------
// Column layout — locked widths, shared by header and rows
// -----------------------------------------------------------------------------

const COLS = {
  severity: 4, // left indicator bar
  toggle: 32,
  label: 320,
  meta: 72, // # rows / type indicator
  hts: 120,
  origin: 64,
  date: 104,
  cv: 120,
  sailRate: 80,
  sailAmount: 116,
  brokerRate: 80,
  brokerAmount: 116,
  variance: 116,
  flags: 168,
};
const ROW_WIDTH = Object.values(COLS).reduce((s, v) => s + v, 0);

// -----------------------------------------------------------------------------
// Authority visual palette — locked to tariff module colors
// -----------------------------------------------------------------------------

const AUTHORITY_COLOR: Record<AuthorityStackEntry['key'], string> = {
  base: '#008dff',
  mfn: '#008dff',
  rate_232: '#ff7c43',
  rate_301: '#59a89c',
  rate_ieepa_recip: '#665191',
  rate_ieepa_fent: '#d45087',
  rate_s122: '#f95d6a',
  rate_section_201: '#a05195',
  rate_other: '#ffa600',
  mpf: '#94a3b8',
  hmf: '#94a3b8',
};

// =============================================================================
// Component
// =============================================================================

export function BulkResultsGrid({
  rows,
  lineItems,
  entries,
  shipments,
  view,
  groupBy,
  onLineClick,
}: Props) {
  const groups = groupBy === 'entry' ? entries : shipments;

  const lineById = useMemo(() => {
    const m = new Map<string, MergedLineItem>();
    for (const l of lineItems) m.set(l.id, l);
    return m;
  }, [lineItems]);

  const visibleGroups = useMemo(() => {
    if (view === 'results') return groups;
    if (view === 'reconciliation') {
      return groups
        .filter((g) => g.totalUploadedDuty != null)
        .sort(
          (a, b) =>
            Math.abs(b.dutyVariance ?? 0) - Math.abs(a.dutyVariance ?? 0),
        );
    }
    return groups.filter((g) =>
      g.lineItemIds.some((lid) => {
        const l = lineById.get(lid);
        return l && l.flags.length > 0;
      }),
    );
  }, [groups, view, lineById]);

  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(() => {
    const s = new Set<string>();
    for (let i = 0; i < Math.min(10, visibleGroups.length); i++) {
      s.add(visibleGroups[i].id);
    }
    return s;
  });
  const [expandedLines, setExpandedLines] = useState<Set<string>>(new Set());

  const toggleGroup = useCallback((id: string) => {
    setExpandedGroups((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  const toggleLine = useCallback((id: string) => {
    setExpandedLines((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  const expandAll = useCallback(() => {
    setExpandedGroups(new Set(visibleGroups.map((g) => g.id)));
  }, [visibleGroups]);
  const collapseAll = useCallback(() => {
    setExpandedGroups(new Set());
    setExpandedLines(new Set());
  }, []);

  const items: TreeItem[] = useMemo(() => {
    const list: TreeItem[] = [];
    for (const group of visibleGroups) {
      const groupExpanded = expandedGroups.has(group.id);
      list.push({ kind: 'group', group, expanded: groupExpanded });
      if (!groupExpanded) continue;

      for (const lid of group.lineItemIds) {
        const line = lineById.get(lid);
        if (!line) continue;
        if (view === 'exceptions' && line.flags.length === 0) continue;
        const lineExpanded = expandedLines.has(line.id);
        list.push({ kind: 'line', line, expanded: lineExpanded });
        if (!lineExpanded) continue;

        const stack = line.sailStack;
        for (let i = 0; i < stack.length; i++) {
          list.push({
            kind: 'stack',
            stack: stack[i],
            line,
            last: i === stack.length - 1,
          });
        }
      }
    }
    return list;
  }, [visibleGroups, expandedGroups, expandedLines, lineById, view]);

  const parentRef = useRef<HTMLDivElement>(null);
  const virt = useVirtualizer({
    count: items.length,
    getScrollElement: () => parentRef.current,
    estimateSize: (i) => {
      const item = items[i];
      if (!item) return 36;
      if (item.kind === 'group') return 50;
      if (item.kind === 'line') return 44;
      return 30;
    },
    overscan: 16,
  });

  const totalLineItems = visibleGroups.reduce(
    (n, g) => n + g.lineItemIds.length,
    0,
  );

  return (
    <div className="flex flex-col h-full min-h-0 bg-[#FAFAF8]">
      {/* Toolbar */}
      <div className="flex items-center gap-3 px-4 py-2.5 border-b border-gray-100 bg-white">
        <div className="flex items-center gap-2">
          <span className="text-[10px] font-semibold text-gray-500 uppercase tracking-[0.08em]">
            {groupBy === 'entry' ? 'Entries' : 'Shipments'}
          </span>
          <div className="h-3 w-px bg-gray-200" />
          <span className="text-[11px] text-gray-400 font-mono tabular-nums">
            {visibleGroups.length.toLocaleString()} / {totalLineItems.toLocaleString()} lines
          </span>
        </div>
        <div className="ml-auto flex items-center gap-0.5">
          <button
            type="button"
            onClick={expandAll}
            className="text-[10px] font-medium text-gray-500 hover:text-[#353CED] px-2.5 py-1 rounded-md transition-colors uppercase tracking-wider"
          >
            Expand all
          </button>
          <div className="h-3 w-px bg-gray-200" />
          <button
            type="button"
            onClick={collapseAll}
            className="text-[10px] font-medium text-gray-500 hover:text-[#353CED] px-2.5 py-1 rounded-md transition-colors uppercase tracking-wider"
          >
            Collapse all
          </button>
        </div>
      </div>

      {/* Horizontal scroll wrapper — shared by header + body so they stay in lockstep.
          The outer div handles x-scroll; the inner column has a locked ROW_WIDTH so
          header and body always advance together when the user scrolls horizontally. */}
      <div className="flex-1 min-h-0 overflow-x-auto overflow-y-hidden">
        <div
          className="h-full flex flex-col"
          style={{ width: `${ROW_WIDTH}px`, minWidth: `${ROW_WIDTH}px` }}
        >
          {/* Column header — sits inside the ROW_WIDTH column so it shares the
              outer x-scroll with the body. */}
          <div className="flex-shrink-0 flex text-[10px] font-semibold text-gray-500 uppercase tracking-[0.08em] bg-gradient-to-b from-gray-50 to-gray-50/50 border-b border-gray-100">
            <HCell w={COLS.severity} />
            <HCell w={COLS.toggle} />
            <HCell w={COLS.label}>Entry / Line / Authority</HCell>
            <HCell w={COLS.meta} align="right">Rows</HCell>
            <HCell w={COLS.hts}>HTS</HCell>
            <HCell w={COLS.origin}>Origin</HCell>
            <HCell w={COLS.date}>Date</HCell>
            <HCell w={COLS.cv} align="right">Customs Value</HCell>
            <HCell w={COLS.sailRate} align="right">SAIL Rate</HCell>
            <HCell w={COLS.sailAmount} align="right">SAIL Duty</HCell>
            <HCell w={COLS.brokerRate} align="right">Broker Rate</HCell>
            <HCell w={COLS.brokerAmount} align="right">Broker Duty</HCell>
            <HCell w={COLS.variance} align="right">Variance</HCell>
            <HCell w={COLS.flags}>Flags</HCell>
          </div>

          {/* Body — independent vertical scroll. Because it's nested inside the
              ROW_WIDTH column, horizontal scroll is handled by the wrapper above;
              the virtualizer only needs to track vertical scroll here. */}
          {items.length === 0 ? (
            <EmptyState view={view} />
          ) : (
            <div
              ref={parentRef}
              className="flex-1 overflow-y-auto overflow-x-hidden min-h-0 relative"
              style={{ contain: 'strict' }}
            >
              <div
                style={{
                  height: `${virt.getTotalSize()}px`,
                  width: `${ROW_WIDTH}px`,
                  position: 'relative',
                }}
              >
                {virt.getVirtualItems().map((v) => {
                  const item = items[v.index];
                  if (!item) return null;
                  const key =
                    item.kind === 'group'
                      ? `g_${item.group.id}`
                      : item.kind === 'line'
                      ? `l_${item.line.id}`
                      : `s_${item.line.id}_${item.stack.key}`;
                  return (
                    <div
                      key={key}
                      className="absolute left-0"
                      style={{
                        top: 0,
                        transform: `translateY(${v.start}px)`,
                        height: `${v.size}px`,
                        width: `${ROW_WIDTH}px`,
                      }}
                    >
                      {item.kind === 'group' ? (
                        <GroupRow
                          group={item.group}
                          expanded={item.expanded}
                          onToggle={() => toggleGroup(item.group.id)}
                        />
                      ) : item.kind === 'line' ? (
                        <LineItemRow
                          line={item.line}
                          expanded={item.expanded}
                          onToggle={() => toggleLine(item.line.id)}
                          onClick={() => onLineClick?.(item.line)}
                        />
                      ) : (
                        <StackRow
                          stack={item.stack}
                          last={item.last}
                        />
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Empty state
// -----------------------------------------------------------------------------

function EmptyState({ view }: { view: ReviewView }) {
  const message =
    view === 'reconciliation'
      ? 'No broker-reported values to reconcile. Upload a file with Duty / MPF / HMF columns to enable this view.'
      : view === 'exceptions'
      ? 'No exceptions found. Every row passed validation and calculated cleanly.'
      : 'No rows to display.';
  return (
    <div className="flex-1 flex items-center justify-center bg-[#FAFAF8]">
      <div className="flex flex-col items-center gap-3 max-w-md text-center px-6 py-12">
        <div className="w-12 h-12 rounded-2xl bg-white shadow-[0_1px_3px_rgba(15,23,42,0.06)] ring-1 ring-gray-100 flex items-center justify-center">
          <Inbox className="h-5 w-5 text-gray-300" strokeWidth={1.75} />
        </div>
        <p className="text-[12px] text-gray-500 leading-relaxed">{message}</p>
      </div>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Header cell
// -----------------------------------------------------------------------------

function HCell({
  w,
  children,
  align = 'left',
}: {
  w: number;
  children?: React.ReactNode;
  align?: 'left' | 'right';
}) {
  return (
    <div
      className={cn('flex-shrink-0 px-3 py-2.5 truncate', align === 'right' && 'text-right')}
      style={{ width: `${w}px` }}
    >
      {children}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Group row (Level 1 — 50px)
// -----------------------------------------------------------------------------

function GroupRow({
  group,
  expanded,
  onToggle,
}: {
  group: EntryGroup;
  expanded: boolean;
  onToggle: () => void;
}) {
  const severity = groupVarianceSeverity(group);
  const tint = severityTint(severity);
  const hasBroker = group.totalUploadedDuty != null;
  const effectiveRate =
    group.totalCustomsValue > 0
      ? group.totalCalculatedDuty / group.totalCustomsValue
      : 0;
  const brokerRate =
    group.totalCustomsValue > 0 && group.totalUploadedDuty != null
      ? group.totalUploadedDuty / group.totalCustomsValue
      : null;

  return (
    <div
      onClick={onToggle}
      className={cn(
        'flex items-stretch h-full cursor-pointer transition-colors border-b border-gray-200/70',
        'hover:bg-gray-50 bg-gradient-to-b from-white to-gray-50/30',
        tint,
      )}
    >
      {/* Severity indicator bar */}
      <div
        className={cn('flex-shrink-0', severityBar(severity))}
        style={{ width: `${COLS.severity}px` }}
      />
      <div
        className="flex-shrink-0 flex items-center justify-center text-gray-500"
        style={{ width: `${COLS.toggle}px` }}
      >
        {expanded ? (
          <ChevronDown className="h-4 w-4" strokeWidth={2} />
        ) : (
          <ChevronRight className="h-4 w-4" strokeWidth={2} />
        )}
      </div>
      <div
        className="flex-shrink-0 px-3 py-2 flex items-center gap-3 truncate"
        style={{ width: `${COLS.label}px` }}
      >
        <div className="w-7 h-7 rounded-lg bg-[#353CED]/8 flex items-center justify-center flex-shrink-0 ring-1 ring-[#353CED]/10">
          <Package className="h-3.5 w-3.5 text-[#353CED]" strokeWidth={2} />
        </div>
        <div className="flex flex-col min-w-0">
          <span className="text-[13px] font-semibold text-gray-900 truncate tracking-[-0.01em]">
            {group.key ?? <span className="text-gray-400 italic">(unassigned)</span>}
          </span>
          <span className="text-[9px] text-gray-400 uppercase tracking-[0.08em] font-medium">
            {group.kind} · {group.lineItemIds.length} line item
            {group.lineItemIds.length === 1 ? '' : 's'}
          </span>
        </div>
      </div>
      <div
        className="flex-shrink-0 px-3 py-2 text-right text-[10px] font-mono tabular-nums text-gray-400 truncate flex items-center justify-end"
        style={{ width: `${COLS.meta}px` }}
      >
        {group.rowIds.length}
      </div>
      <CellEmpty w={COLS.hts} />
      <CellEmpty w={COLS.origin} />
      <CellEmpty w={COLS.date} />
      <CellMoney w={COLS.cv} value={group.totalCustomsValue} tone="mono" bold />
      <CellRate w={COLS.sailRate} value={effectiveRate} bold />
      <CellMoney w={COLS.sailAmount} value={group.totalCalculatedDuty} tone="duty" bold />
      <CellRate w={COLS.brokerRate} value={brokerRate} />
      <CellMoney w={COLS.brokerAmount} value={group.totalUploadedDuty} tone="mono" />
      <div
        className="flex-shrink-0 px-3 py-2 text-right flex items-center justify-end gap-1.5 truncate"
        style={{ width: `${COLS.variance}px` }}
      >
        {hasBroker ? (
          <>
            {varianceArrow(group.dutyVariance)}
            <span
              className={cn(
                'font-mono text-[11px] font-semibold tabular-nums',
                severityText(severity),
              )}
            >
              {group.dutyVariance != null
                ? formatCurrencyCompact(group.dutyVariance)
                : '—'}
            </span>
          </>
        ) : (
          <span className="text-[9px] text-gray-300 italic uppercase tracking-wider">
            no broker
          </span>
        )}
      </div>
      <CellEmpty w={COLS.flags} />
    </div>
  );
}

// -----------------------------------------------------------------------------
// Line item row (Level 2 — 44px)
// -----------------------------------------------------------------------------

function LineItemRow({
  line,
  expanded,
  onToggle,
  onClick,
}: {
  line: MergedLineItem;
  expanded: boolean;
  onToggle: () => void;
  onClick: () => void;
}) {
  const severity = line.varianceSeverity as Severity;
  const tint = severityTint(severity);
  const hasBroker = line.brokerTotalDuty != null;
  const brokerRate =
    line.brokerTotalDuty != null &&
    line.customsValue != null &&
    line.customsValue > 0
      ? line.brokerTotalDuty / line.customsValue
      : null;

  return (
    <div
      className={cn(
        'group flex items-stretch h-full transition-colors border-b border-gray-100 bg-white hover:bg-[#353CED]/[0.03]',
        tint,
      )}
    >
      {/* Severity indicator bar */}
      <div
        className={cn(
          'flex-shrink-0 opacity-60',
          severity === 'no_upload' ? 'bg-transparent' : severityBar(severity),
        )}
        style={{ width: `${COLS.severity}px` }}
      />
      {/* Expand toggle for the authority stack */}
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation();
          onToggle();
        }}
        aria-label={expanded ? 'Collapse duty stack' : 'Expand duty stack'}
        title={expanded ? 'Collapse duty stack' : 'Expand duty stack'}
        className="flex-shrink-0 flex items-center justify-center text-gray-300 hover:text-[#353CED] transition-colors"
        style={{ width: `${COLS.toggle}px` }}
      >
        {expanded ? (
          <ChevronDown className="h-3.5 w-3.5" strokeWidth={2} />
        ) : (
          <ChevronRight className="h-3.5 w-3.5" strokeWidth={2} />
        )}
      </button>
      {/* Label — click opens detail drawer */}
      <div
        onClick={onClick}
        title="Click to view rate history and duty stack"
        className="flex-shrink-0 px-3 py-2 flex items-center gap-2.5 truncate cursor-pointer"
        style={{ width: `${COLS.label}px` }}
      >
        <div className="w-px self-stretch bg-gray-200" />
        <Layers className="h-3 w-3 text-gray-400 flex-shrink-0" strokeWidth={2} />
        <div className="flex flex-col min-w-0">
          <span
            className="text-[12px] text-gray-800 truncate leading-tight"
            title={line.description ?? undefined}
          >
            {line.description || <span className="text-gray-400 italic">—</span>}
          </span>
          <span className="text-[9px] text-gray-400 truncate leading-tight mt-0.5">
            {line.partNumber ? `Part ${line.partNumber}` : ''}
            {line.invoiceLineNumber ? ` · Line ${line.invoiceLineNumber}` : ''}
            {line.ch99RowIds.length > 0 && (
              <span className="text-[#353CED]/70 font-medium ml-0.5">
                {line.partNumber || line.invoiceLineNumber ? ' · ' : ''}
                +{line.ch99RowIds.length} Ch.99
              </span>
            )}
          </span>
        </div>
      </div>
      <div
        className="flex-shrink-0 px-3 py-2 text-right font-mono tabular-nums text-[10px] text-gray-400 truncate flex items-center justify-end"
        style={{ width: `${COLS.meta}px` }}
      >
        {line.rowIds.length}
      </div>
      <div
        className="flex-shrink-0 px-3 py-2 font-mono text-[11px] text-gray-700 truncate flex items-center"
        style={{ width: `${COLS.hts}px` }}
      >
        {line.hts10 ? formatHtsCode(line.hts10) : '—'}
      </div>
      <div
        className="flex-shrink-0 px-3 py-2 text-[11px] font-semibold text-gray-700 truncate flex items-center"
        style={{ width: `${COLS.origin}px` }}
        title={line.countryOfOriginName ?? line.countryOfOrigin ?? ''}
      >
        {line.countryOfOriginAlpha2 ?? line.countryOfOrigin ?? '—'}
      </div>
      <div
        className="flex-shrink-0 px-3 py-2 text-[10px] text-gray-500 truncate flex items-center"
        style={{ width: `${COLS.date}px` }}
      >
        {line.controllingDate ? formatDate(line.controllingDate) : '—'}
      </div>
      <CellMoney w={COLS.cv} value={line.customsValue} tone="mono" />
      <CellRate
        w={COLS.sailRate}
        value={
          line.sailEffectiveRatePct != null
            ? line.sailEffectiveRatePct / 100
            : null
        }
      />
      <CellMoney w={COLS.sailAmount} value={line.sailTotalDuty} tone="duty" bold />
      <CellRate w={COLS.brokerRate} value={brokerRate} />
      <CellMoney w={COLS.brokerAmount} value={line.brokerTotalDuty} tone="mono" />
      <div
        className="flex-shrink-0 px-3 py-2 text-right truncate flex items-center justify-end"
        style={{ width: `${COLS.variance}px` }}
      >
        {hasBroker ? (
          <div className="flex items-center justify-end gap-1">
            {varianceArrow(line.dutyVariance)}
            <span
              className={cn(
                'font-mono text-[11px] tabular-nums',
                severityText(severity),
                (severity === 'critical' || severity === 'material') && 'font-semibold',
              )}
            >
              {line.dutyVariance != null
                ? formatCurrency(line.dutyVariance)
                : '—'}
            </span>
          </div>
        ) : (
          <span className="text-[10px] text-gray-300">—</span>
        )}
      </div>
      <div
        className="flex-shrink-0 px-3 py-2 truncate flex items-center"
        style={{ width: `${COLS.flags}px` }}
      >
        <FlagPills flags={line.flags} />
      </div>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Stack row (Level 3 — 30px)
// -----------------------------------------------------------------------------

function StackRow({ stack, last }: { stack: AuthorityStackEntry; last: boolean }) {
  const variance = stack.variance;
  const isMaterial = variance != null && Math.abs(variance) >= 1;
  const rowTint =
    isMaterial && variance != null
      ? Math.abs(variance) >= 500
        ? 'bg-red-50/40'
        : Math.abs(variance) >= 50
        ? 'bg-amber-50/25'
        : 'bg-yellow-50/20'
      : '';
  const dotColor = AUTHORITY_COLOR[stack.key] ?? '#94a3b8';

  return (
    <div
      className={cn(
        'flex items-stretch h-full border-b',
        last ? 'border-gray-200/70' : 'border-gray-100/60',
        'bg-slate-50/40',
        rowTint,
      )}
    >
      {/* Severity bar spacer keeps column alignment */}
      <CellEmpty w={COLS.severity} />
      <div
        className="flex-shrink-0 flex items-center justify-center"
        style={{ width: `${COLS.toggle}px` }}
      >
        <div className="w-px h-full bg-gray-200" />
      </div>
      <div
        className="flex-shrink-0 pr-3 py-1.5 flex items-center gap-2 truncate"
        style={{ width: `${COLS.label}px`, paddingLeft: '44px' }}
      >
        <span
          className="w-1.5 h-1.5 rounded-full flex-shrink-0"
          style={{ backgroundColor: dotColor }}
        />
        <span className="text-[11px] text-gray-600 truncate leading-tight">
          {stack.label}
        </span>
        {stack.ch99Codes && stack.ch99Codes.length > 0 && (
          <span
            className="text-[9px] font-mono text-[#353CED]/80 truncate"
            title={stack.ch99Codes.join(', ')}
          >
            {stack.ch99Codes
              .slice(0, 2)
              .map(formatHtsCode)
              .join(', ')}
            {stack.ch99Codes.length > 2 ? '…' : ''}
          </span>
        )}
      </div>
      <CellEmpty w={COLS.meta} />
      <CellEmpty w={COLS.hts} />
      <CellEmpty w={COLS.origin} />
      <CellEmpty w={COLS.date} />
      <CellEmpty w={COLS.cv} />
      <CellRate w={COLS.sailRate} value={stack.sailRate} small />
      <CellMoney w={COLS.sailAmount} value={stack.sailAmount} tone="duty-light" />
      <CellRate w={COLS.brokerRate} value={stack.brokerRate} small />
      <CellMoney w={COLS.brokerAmount} value={stack.brokerAmount} tone="mono-light" />
      <div
        className="flex-shrink-0 px-3 py-1.5 text-right truncate flex items-center justify-end"
        style={{ width: `${COLS.variance}px` }}
      >
        {variance != null ? (
          <div className="flex items-center justify-end gap-1">
            {varianceArrow(variance)}
            <span
              className={cn(
                'font-mono text-[10px] tabular-nums',
                Math.abs(variance) < 1
                  ? 'text-emerald-600'
                  : Math.abs(variance) < 50
                  ? 'text-yellow-700'
                  : Math.abs(variance) < 500
                  ? 'text-amber-600'
                  : 'text-red-600 font-semibold',
              )}
            >
              {formatCurrency(variance)}
            </span>
          </div>
        ) : (
          <span className="text-[10px] text-gray-300">—</span>
        )}
      </div>
      <CellEmpty w={COLS.flags} />
    </div>
  );
}

// -----------------------------------------------------------------------------
// Flag pills
// -----------------------------------------------------------------------------

function FlagPills({ flags }: { flags: ExceptionFlag[] }) {
  if (flags.length === 0) return null;
  const byKind = new Map<string, ExceptionFlag>();
  for (const f of flags) {
    if (!byKind.has(f.kind)) byKind.set(f.kind, f);
  }
  const unique = Array.from(byKind.values());
  const pills = unique.slice(0, 2);
  const more = unique.length - pills.length;
  return (
    <div className="flex items-center gap-1">
      {pills.map((f, i) => {
        const Icon =
          f.severity === 'error'
            ? AlertCircle
            : f.severity === 'warning'
            ? AlertTriangle
            : Info;
        const tone =
          f.severity === 'error'
            ? 'bg-red-100/80 text-red-700 ring-red-200/50'
            : f.severity === 'warning'
            ? 'bg-amber-100/70 text-amber-800 ring-amber-200/50'
            : 'bg-blue-100/60 text-blue-700 ring-blue-200/50';
        return (
          <span
            key={i}
            title={f.message}
            className={cn(
              'inline-flex items-center gap-1 px-1.5 py-0.5 rounded-md text-[9px] font-medium ring-1',
              tone,
            )}
          >
            <Icon className="h-2.5 w-2.5" strokeWidth={2} />
            {f.kind.replace(/_/g, ' ')}
          </span>
        );
      })}
      {more > 0 && (
        <span className="text-[9px] text-gray-400 font-medium">+{more}</span>
      )}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Reusable cells
// -----------------------------------------------------------------------------

function CellEmpty({ w }: { w: number }) {
  return <div className="flex-shrink-0" style={{ width: `${w}px` }} />;
}

function CellMoney({
  w,
  value,
  tone,
  bold,
}: {
  w: number;
  value: number | null | undefined;
  tone: 'mono' | 'mono-light' | 'duty' | 'duty-light' | 'fees';
  bold?: boolean;
}) {
  const toneClass =
    tone === 'duty'
      ? 'text-red-600'
      : tone === 'duty-light'
      ? 'text-red-500'
      : tone === 'fees'
      ? 'text-amber-600'
      : tone === 'mono-light'
      ? 'text-gray-500'
      : 'text-gray-700';
  return (
    <div
      className={cn(
        'flex-shrink-0 px-3 text-right font-mono tabular-nums text-[11px] truncate flex items-center justify-end',
        toneClass,
        bold && 'font-semibold',
      )}
      style={{ width: `${w}px` }}
    >
      {value == null ? (
        <span className="text-gray-300">—</span>
      ) : (
        formatCurrency(value)
      )}
    </div>
  );
}

function CellRate({
  w,
  value,
  bold,
  small,
}: {
  w: number;
  value: number | null | undefined;
  bold?: boolean;
  small?: boolean;
}) {
  return (
    <div
      className={cn(
        'flex-shrink-0 px-3 text-right font-mono tabular-nums text-gray-500 truncate flex items-center justify-end',
        small ? 'text-[10px]' : 'text-[10px]',
        bold && 'text-gray-700 font-semibold',
      )}
      style={{ width: `${w}px` }}
    >
      {value == null ? (
        <span className="text-gray-300">—</span>
      ) : (
        formatRateShort(value)
      )}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Exported helpers used by the summary rail
// -----------------------------------------------------------------------------

export function summarizeGroupVariance(
  groups: (EntryGroup | ShipmentGroup)[],
): {
  total: number;
  match: number;
  minor: number;
  material: number;
  critical: number;
  noUpload: number;
} {
  const out = {
    total: groups.length,
    match: 0,
    minor: 0,
    material: 0,
    critical: 0,
    noUpload: 0,
  };
  for (const g of groups) {
    const s = groupVarianceSeverity(g);
    if (s === 'match') out.match++;
    else if (s === 'minor') out.minor++;
    else if (s === 'material') out.material++;
    else if (s === 'critical') out.critical++;
    else out.noUpload++;
  }
  return out;
}

export { formatCurrencyCompact };
