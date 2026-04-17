// =============================================================================
// BulkDutyWorkflow — shipment-centric bulk duty analysis
// =============================================================================
// Five-stage pipeline matching the visual language of DutyCalculatorPanel:
// Card + CardContent(p-5), neu inset toggles, icon badges, uppercase
// tracking-wider column headers, monospace numbers, red/amber/blue duty
// color key.
//
// Stages:
//   1. Upload      — drag/drop CSV or XLSX, sheet picker, worker-free parse
//   2. Map Columns — auto-detected canonical mappings with sample values,
//                    "recommended for grouping" chip on entry / shipment id
//   3. Validate    — tier-1 validation counts + sample issues, no layout shift
//   4. Process     — dual progress (rates, calculation)
//   5. Review      — hierarchical reconciliation grid grouped by entry or
//                    shipment, summary rail with Line Item Totals and
//                    Recomputed Entry Totals side-by-side

import React, { useCallback, useMemo, useState } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import {
  Upload,
  FileSpreadsheet,
  ArrowRight,
  ArrowLeft,
  Check,
  AlertTriangle,
  AlertCircle,
  X,
  Download,
  Loader2,
  Table,
  ClipboardList,
  Calculator,
  LayoutGrid,
  Info,
  Package,
  ListChecks,
  TrendingUp,
  TrendingDown,
  Minus,
  GitCompareArrows,
  Layers,
  RefreshCw,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import type { Country } from '@/types/tariff';
import type {
  ImportJob,
  JobStage,
  ColumnMapping,
  CanonicalFieldKey,
  DutyResultRow,
  EntryGroup,
  ShipmentGroup,
  JobSummary,
  CanonicalFieldDef,
  MergedLineItem,
} from '@/types/bulk';
import { emptyJobSummary } from '@/types/bulk';
import { parseBulkFile } from '@/utils/bulkParser';
import {
  CANONICAL_FIELDS,
  FIELD_GROUP_LABELS,
  autoDetectMapping,
  validateMapping,
  setMapping as setMappingHelper,
} from '@/utils/columnMapping';
import { buildCountryResolver, buildRows } from '@/utils/bulkValidator';
import { calculateBulk, collectRateKeys } from '@/utils/bulkCalculator';
import { exportBulkJob } from '@/utils/bulkExport';
import { useBulkRateLookup } from '@/hooks/useBulkRateLookup';
import { formatCurrency, formatCurrencyCompact } from '@/utils/formatters';
import {
  BulkResultsGrid,
  type ReviewView,
  type GroupBy,
  summarizeGroupVariance,
} from './BulkResultsGrid';
import { LineDetailDrawer } from './LineDetailDrawer';

// -----------------------------------------------------------------------------
// Neu inset shadow — matches DutyCalculatorPanel toggle bar
// -----------------------------------------------------------------------------

const NEU_INSET =
  'inset 1px 1px 4px rgba(0,0,0,0.05), inset -1px -1px 4px rgba(255,255,255,0.85)';

// -----------------------------------------------------------------------------
// Stages
// -----------------------------------------------------------------------------

interface StageDef {
  key: JobStage;
  label: string;
  icon: React.ElementType;
}

const STAGES: StageDef[] = [
  { key: 'upload', label: 'Upload', icon: Upload },
  { key: 'mapping', label: 'Map Columns', icon: Table },
  { key: 'validation', label: 'Validate', icon: ListChecks },
  { key: 'processing', label: 'Calculate', icon: Calculator },
  { key: 'review', label: 'Review', icon: LayoutGrid },
];

// -----------------------------------------------------------------------------
// Initial state
// -----------------------------------------------------------------------------

function emptyJob(): ImportJob {
  return {
    id: `job_${Date.now()}`,
    createdAt: new Date().toISOString(),
    fileName: '',
    fileType: 'csv',
    parseResult: null,
    sourceColumns: [],
    mapping: {},
    rows: [],
    lineItems: [],
    shipments: [],
    entries: [],
    jobSummary: emptyJobSummary(),
    stage: 'upload',
    status: 'idle',
  };
}

// =============================================================================
// Root
// =============================================================================

interface Props {
  countries: Country[];
}

export function BulkDutyWorkflow({ countries }: Props) {
  const [job, setJob] = useState<ImportJob>(emptyJob);
  const resolver = useMemo(() => buildCountryResolver(countries), [countries]);
  const rateLookup = useBulkRateLookup();

  const [uploadError, setUploadError] = useState<string | null>(null);
  const [processError, setProcessError] = useState<string | null>(null);
  const [calcProgress, setCalcProgress] = useState({ processed: 0, total: 0 });

  const setStage = useCallback((stage: JobStage) => {
    setJob((j) => ({ ...j, stage }));
  }, []);

  // ---------------------------------------------------------------------------
  // Stage 1 — upload
  // ---------------------------------------------------------------------------
  const handleFile = useCallback(async (file: File) => {
    setUploadError(null);
    setJob((j) => ({ ...j, status: 'parsing' }));
    try {
      const parsed = await parseBulkFile(file);
      const activeSheet = parsed.sheets[parsed.activeSheetIndex];
      const mapping = autoDetectMapping(activeSheet.headers);
      setJob({
        ...emptyJob(),
        id: `job_${Date.now()}`,
        createdAt: new Date().toISOString(),
        fileName: parsed.fileName,
        fileType: parsed.fileType,
        parseResult: parsed,
        sourceColumns: activeSheet.headers,
        mapping,
        stage: 'mapping',
        status: 'ready_to_map',
      });
    } catch (err) {
      setUploadError(err instanceof Error ? err.message : String(err));
      setJob((j) => ({ ...j, status: 'error' }));
    }
  }, []);

  const handleSheetChange = useCallback((sheetIndex: number) => {
    setJob((j) => {
      if (!j.parseResult) return j;
      const sheet = j.parseResult.sheets[sheetIndex];
      if (!sheet) return j;
      const mapping = autoDetectMapping(sheet.headers);
      return {
        ...j,
        parseResult: { ...j.parseResult, activeSheetIndex: sheetIndex },
        sourceColumns: sheet.headers,
        mapping,
      };
    });
  }, []);

  // ---------------------------------------------------------------------------
  // Stage 2 — mapping
  // ---------------------------------------------------------------------------
  const handleMappingChange = useCallback(
    (key: CanonicalFieldKey, sourceColumn: string | null) => {
      setJob((j) => ({
        ...j,
        mapping: setMappingHelper(j.mapping, key, sourceColumn),
      }));
    },
    [],
  );

  const mappingValidation = useMemo(
    () => validateMapping(job.mapping),
    [job.mapping],
  );

  const hasGroupingKey = useMemo(
    () =>
      !!(
        job.mapping.entryNumber?.sourceColumn ||
        job.mapping.shipmentId?.sourceColumn ||
        job.mapping.masterBill?.sourceColumn ||
        job.mapping.houseBill?.sourceColumn
      ),
    [job.mapping],
  );

  const goToValidate = useCallback(() => {
    if (!job.parseResult) return;
    const sheet = job.parseResult.sheets[job.parseResult.activeSheetIndex];
    const rows = buildRows(sheet.rows, job.mapping, {
      resolver,
      defaultImportCountry: null,
    });
    setJob((j) => ({
      ...j,
      rows,
      stage: 'validation',
      status: 'ready_to_validate',
    }));
  }, [job.parseResult, job.mapping, resolver]);

  // ---------------------------------------------------------------------------
  // Stage 3 — validation counts
  // ---------------------------------------------------------------------------
  const validationCounts = useMemo(() => {
    let valid = 0;
    let warnings = 0;
    let blocked = 0;
    for (const r of job.rows) {
      if (r.validation.some((v) => v.severity === 'blocking')) blocked++;
      else if (r.validation.length > 0 || r.flags.length > 0) warnings++;
      else valid++;
    }
    return { valid, warnings, blocked };
  }, [job.rows]);

  // ---------------------------------------------------------------------------
  // Stage 4 — calculate
  // ---------------------------------------------------------------------------
  const handleCalculate = useCallback(async () => {
    setProcessError(null);
    setJob((j) => ({ ...j, stage: 'processing', status: 'calculating' }));
    try {
      const { keys } = collectRateKeys(job.rows);
      const { rateMap } = await rateLookup.lookup(keys);
      setCalcProgress({ processed: 0, total: job.rows.length });
      const result = calculateBulk(job.rows, {
        rateMap,
        defaultMOT: 'ocean',
        onProgress: (p, t) => setCalcProgress({ processed: p, total: t }),
      });
      setJob((j) => ({
        ...j,
        rows: result.rows,
        lineItems: result.lineItems,
        entries: result.entries,
        shipments: result.shipments,
        jobSummary: result.jobSummary,
        stage: 'review',
        status: 'complete',
      }));
    } catch (err) {
      setProcessError(err instanceof Error ? err.message : String(err));
      setJob((j) => ({ ...j, status: 'error' }));
    }
  }, [job.rows, rateLookup]);

  // ---------------------------------------------------------------------------
  // Stage 5 — export / reset
  // ---------------------------------------------------------------------------
  const handleExport = useCallback(() => {
    exportBulkJob(job);
  }, [job]);

  const reset = useCallback(() => {
    setJob(emptyJob());
    setUploadError(null);
    setProcessError(null);
    setCalcProgress({ processed: 0, total: 0 });
  }, []);

  return (
    <div className="space-y-5">
      <StageNav stage={job.stage} />

      {job.stage === 'upload' && (
        <UploadStage
          onFile={handleFile}
          status={job.status}
          error={uploadError}
        />
      )}

      {job.stage === 'mapping' && job.parseResult && (
        <MappingStage
          job={job}
          onMappingChange={handleMappingChange}
          onSheetChange={handleSheetChange}
          onBack={() => setStage('upload')}
          onNext={goToValidate}
          validation={mappingValidation}
          hasGroupingKey={hasGroupingKey}
        />
      )}

      {job.stage === 'validation' && (
        <ValidationStage
          rows={job.rows}
          counts={validationCounts}
          onBack={() => setStage('mapping')}
          onNext={handleCalculate}
        />
      )}

      {job.stage === 'processing' && (
        <ProcessingStage
          rateProgress={rateLookup.progress}
          calcProgress={calcProgress}
          error={processError}
          onBack={() => setStage('validation')}
        />
      )}

      {job.stage === 'review' && (
        <ReviewStage
          job={job}
          onBack={() => setStage('validation')}
          onExport={handleExport}
          onReset={reset}
        />
      )}
    </div>
  );
}

// =============================================================================
// Stage navigation — dot-connected stepper with icon nodes and labels below.
// Visual language: neu inset track beneath, white glass-shadowed active node.
// =============================================================================

function StageNav({ stage }: { stage: JobStage }) {
  const currentIdx = STAGES.findIndex((s) => s.key === stage);
  return (
    <Card>
      <CardContent className="p-5">
        <div className="flex items-center gap-3 mb-5">
          <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
            <ClipboardList className="h-3.5 w-3.5 text-[#353CED]" />
          </div>
          <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">
            Bulk Duty Analysis
          </h3>
          <span className="text-[10px] font-medium text-gray-400 uppercase tracking-wider ml-2">
            Stage {currentIdx + 1} of {STAGES.length}
          </span>
        </div>
        <div className="relative px-2">
          {/* Dotted track behind the nodes */}
          <div className="absolute left-5 right-5 top-4 h-px bg-gray-200/80" />
          <div
            className="absolute left-5 top-4 h-px bg-[#353CED]/40 transition-all duration-500 ease-out"
            style={{
              width: `calc(${(currentIdx / Math.max(STAGES.length - 1, 1)) * 100}% - ${(currentIdx / Math.max(STAGES.length - 1, 1)) * 40}px)`,
            }}
          />
          <div className="relative flex items-start justify-between">
            {STAGES.map((s, idx) => {
              const done = idx < currentIdx;
              const active = idx === currentIdx;
              const Icon = s.icon;
              return (
                <div
                  key={s.key}
                  className="flex flex-col items-center gap-1.5 min-w-0"
                >
                  <div
                    className={cn(
                      'w-8 h-8 rounded-full flex items-center justify-center transition-all duration-300 ease-out',
                      active &&
                        'bg-white text-[#353CED] shadow-[0_2px_8px_-2px_rgba(53,60,237,0.35),0_0_0_3px_rgba(53,60,237,0.12)] ring-1 ring-[#353CED]/20',
                      done && 'bg-emerald-50 text-emerald-600 ring-1 ring-emerald-200/60',
                      !active &&
                        !done &&
                        'bg-gray-50 text-gray-300 ring-1 ring-gray-200/60',
                    )}
                  >
                    {done ? (
                      <Check className="h-3.5 w-3.5" strokeWidth={2.5} />
                    ) : (
                      <Icon className="h-3.5 w-3.5" strokeWidth={2} />
                    )}
                  </div>
                  <span
                    className={cn(
                      'text-[10px] font-medium uppercase tracking-wider whitespace-nowrap',
                      active && 'text-gray-800',
                      done && 'text-emerald-600',
                      !active && !done && 'text-gray-300',
                    )}
                  >
                    {s.label}
                  </span>
                </div>
              );
            })}
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

// =============================================================================
// Stage 1 — Upload
// =============================================================================

function UploadStage({
  onFile,
  status,
  error,
}: {
  onFile: (file: File) => void;
  status: string;
  error: string | null;
}) {
  const [dragging, setDragging] = useState(false);
  const inputRef = React.useRef<HTMLInputElement>(null);

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragging(false);
    const file = e.dataTransfer.files[0];
    if (file) onFile(file);
  };

  return (
    <Card>
      <CardContent className="p-5">
        <div className="flex items-center gap-2 mb-5">
          <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
            <Upload className="h-3.5 w-3.5 text-[#353CED]" />
          </div>
          <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">
            Upload Shipment File
          </h3>
        </div>

        <div
          onDragEnter={(e) => {
            e.preventDefault();
            setDragging(true);
          }}
          onDragOver={(e) => e.preventDefault()}
          onDragLeave={() => setDragging(false)}
          onDrop={handleDrop}
          onClick={() => inputRef.current?.click()}
          className={cn(
            'rounded-2xl border-2 border-dashed p-12 text-center cursor-pointer transition-all duration-300 ease-out',
            dragging
              ? 'border-[#353CED] bg-[#353CED]/5 scale-[1.01]'
              : 'border-gray-200 bg-gradient-to-b from-gray-50/40 to-white hover:border-gray-300 hover:bg-gray-50/60',
          )}
        >
          <div className="w-14 h-14 rounded-2xl bg-white shadow-[0_1px_0_rgba(255,255,255,0.8)_inset,0_1px_3px_rgba(15,23,42,0.06),0_8px_20px_-8px_rgba(53,60,237,0.18)] flex items-center justify-center mx-auto mb-4 ring-1 ring-gray-100/80">
            {status === 'parsing' ? (
              <Loader2 className="h-5 w-5 animate-spin text-[#353CED]" />
            ) : (
              <FileSpreadsheet className="h-5 w-5 text-[#353CED]" strokeWidth={1.75} />
            )}
          </div>
          <p className="text-[13px] text-gray-800 font-medium tracking-[-0.01em]">
            {status === 'parsing' ? 'Parsing file…' : 'Drop a CSV or XLSX file here'}
          </p>
          <p className="text-[11px] text-gray-400 mt-1.5">
            Broker exports, ACE return files, and SAIL templates are supported.
          </p>
          <input
            ref={inputRef}
            type="file"
            aria-label="Upload CSV or XLSX file"
            title="Upload CSV or XLSX file"
            accept=".csv,.xlsx,.xls,.xlsm"
            className="hidden"
            onChange={(e) => {
              const file = e.target.files?.[0];
              if (file) onFile(file);
            }}
          />
        </div>

        {error && (
          <div className="mt-4 flex items-start gap-2.5 px-4 py-3 rounded-xl bg-red-50/80 border border-red-200/60 text-xs text-red-800">
            <AlertCircle className="h-4 w-4 flex-shrink-0 mt-0.5 text-red-500" />
            <span>{error}</span>
          </div>
        )}

        <div className="mt-4 rounded-lg bg-gray-50 px-3.5 py-2.5 text-[10px] text-gray-400 leading-relaxed">
          <span className="font-medium text-gray-500">Source fields are sacred.</span>{' '}
          Original columns flow through to the export verbatim. SAIL appends
          calculation, reconciliation, and flag columns alongside them.
        </div>
      </CardContent>
    </Card>
  );
}

// =============================================================================
// Stage 2 — Mapping
// =============================================================================

function MappingStage({
  job,
  onMappingChange,
  onSheetChange,
  onBack,
  onNext,
  validation,
  hasGroupingKey,
}: {
  job: ImportJob;
  onMappingChange: (key: CanonicalFieldKey, sourceColumn: string | null) => void;
  onSheetChange: (idx: number) => void;
  onBack: () => void;
  onNext: () => void;
  validation: { ok: boolean; missingRequired: CanonicalFieldKey[]; mappedCount: number };
  hasGroupingKey: boolean;
}) {
  const parseResult = job.parseResult!;
  const activeSheet = parseResult.sheets[parseResult.activeSheetIndex];

  // Sample values for each header — first non-empty value across the first
  // 5 rows. Surfaces enough context for the user to verify a mapping.
  const sampleValues = useMemo(() => {
    const map = new Map<string, string>();
    for (const h of activeSheet.headers) {
      for (let i = 0; i < Math.min(5, activeSheet.rows.length); i++) {
        const v = activeSheet.rows[i]?.[h];
        if (v && v.trim().length > 0) {
          map.set(h, v);
          break;
        }
      }
    }
    return map;
  }, [activeSheet]);

  const groupedFields = useMemo(() => {
    const groups: Record<string, CanonicalFieldDef[]> = {};
    for (const f of CANONICAL_FIELDS) (groups[f.group] ??= []).push(f);
    return groups;
  }, []);

  return (
    <Card>
      <CardContent className="p-5">
        {/* Header */}
        <div className="flex items-center justify-between mb-5">
          <div className="flex items-center gap-2">
            <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
              <Table className="h-3.5 w-3.5 text-[#353CED]" />
            </div>
            <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">
              Map Columns
            </h3>
          </div>
          <div className="flex items-center gap-3 text-[11px] text-gray-400">
            <span className="inline-flex items-center gap-1.5">
              <FileSpreadsheet className="h-3 w-3" />
              <span className="text-gray-700 font-medium">{job.fileName}</span>
            </span>
            <span>·</span>
            <span>{activeSheet.rowCount.toLocaleString()} rows</span>
            <span>·</span>
            <span>{activeSheet.headers.length} columns</span>
            {parseResult.sheets.length > 1 && (
              <select
                value={parseResult.activeSheetIndex}
                onChange={(e) => onSheetChange(Number(e.target.value))}
                aria-label="Select sheet"
                title="Select sheet"
                className="ml-2 px-2 py-1 text-xs rounded-md border border-gray-200 bg-white"
              >
                {parseResult.sheets.map((s, i) => (
                  <option key={s.sheetName} value={i}>
                    {s.sheetName} ({s.rowCount.toLocaleString()})
                  </option>
                ))}
              </select>
            )}
          </div>
        </div>

        {/* Priority notice */}
        {!hasGroupingKey && (
          <div className="mb-4 flex items-start gap-2.5 px-4 py-3 rounded-xl bg-amber-50/80 border border-amber-200/60 text-xs text-amber-800">
            <AlertTriangle className="h-4 w-4 flex-shrink-0 mt-0.5 text-amber-500" />
            <div>
              <span className="font-medium">No grouping key mapped.</span> To get
              entry-level reconciliation and correct per-entry MPF / HMF, map
              either <span className="font-semibold">Entry Number</span> or{' '}
              <span className="font-semibold">Shipment ID</span> (master bill /
              house bill also work). Without one, every line rolls into a
              single synthetic batch.
            </div>
          </div>
        )}

        {/* Mapping table */}
        <div className="rounded-xl border border-gray-200/80 overflow-hidden shadow-[0_1px_2px_rgba(15,23,42,0.04)]">
          {/* Column header */}
          <div className="grid grid-cols-[280px_1fr_220px_80px] gap-3 bg-gradient-to-b from-gray-50 to-gray-50/60 px-4 py-2.5 text-[10px] font-semibold text-gray-500 uppercase tracking-wider border-b border-gray-100">
            <span>Canonical Field</span>
            <span>Source Column</span>
            <span>Sample Value</span>
            <span className="text-right">Match</span>
          </div>

          <div className="max-h-[560px] overflow-auto">
            {Object.entries(groupedFields).map(([groupKey, fields]) => (
              <div key={groupKey}>
                <div className="sticky top-0 z-10 px-4 py-1.5 bg-gray-50/95 backdrop-blur-sm border-b border-gray-100 text-[10px] font-semibold text-gray-500 uppercase tracking-wider">
                  {FIELD_GROUP_LABELS[groupKey] ?? groupKey}
                </div>
                {fields.map((field) => {
                  const m = job.mapping[field.key];
                  const sample = m?.sourceColumn
                    ? sampleValues.get(m.sourceColumn) ?? ''
                    : '';
                  const isPriority = field.priority === 'grouping';
                  return (
                    <div
                      key={field.key}
                      className={cn(
                        'grid grid-cols-[280px_1fr_220px_80px] gap-3 px-4 py-2 border-b border-gray-50 items-center',
                        isPriority && !m?.sourceColumn && 'bg-amber-50/20',
                      )}
                    >
                      {/* Canonical field label + description */}
                      <div className="min-w-0">
                        <div className="flex items-center gap-1.5 min-w-0">
                          <span className="text-[12px] font-medium text-gray-700 truncate">
                            {field.label}
                          </span>
                          {field.required && (
                            <span className="text-[9px] text-red-500 font-semibold uppercase">
                              Required
                            </span>
                          )}
                          {isPriority && (
                            <span className="text-[9px] text-[#353CED] font-semibold uppercase flex items-center gap-0.5">
                              <Layers className="h-2.5 w-2.5" />
                              Grouping
                            </span>
                          )}
                        </div>
                        <div className="text-[10px] text-gray-400 leading-tight truncate">
                          {field.description}
                        </div>
                      </div>

                      {/* Source column select */}
                      <select
                        value={m?.sourceColumn ?? ''}
                        onChange={(e) =>
                          onMappingChange(field.key, e.target.value || null)
                        }
                        aria-label={`Source column for ${field.label}`}
                        title={`Source column for ${field.label}`}
                        className={cn(
                          'h-8 px-2.5 text-xs rounded-md border bg-white transition-colors',
                          m?.sourceColumn
                            ? 'border-gray-200 text-gray-700'
                            : field.required
                            ? 'border-red-200 bg-red-50/30 text-gray-400'
                            : 'border-gray-100 text-gray-400',
                        )}
                      >
                        <option value="">— unmapped —</option>
                        {activeSheet.headers.map((h) => (
                          <option key={h} value={h}>
                            {h}
                          </option>
                        ))}
                      </select>

                      {/* Sample value preview */}
                      <div
                        className="text-[11px] text-gray-400 truncate font-mono"
                        title={sample}
                      >
                        {sample || <span className="text-gray-200">—</span>}
                      </div>

                      {/* Confidence / manual chip */}
                      <div className="text-[10px] text-right">
                        {m?.sourceColumn && !m.manualOverride ? (
                          <span className="inline-flex items-center px-1.5 py-0.5 rounded bg-emerald-50 text-emerald-700">
                            {Math.round((m.confidence ?? 0) * 100)}%
                          </span>
                        ) : m?.manualOverride ? (
                          <span className="inline-flex items-center px-1.5 py-0.5 rounded bg-[#353CED]/10 text-[#353CED]">
                            manual
                          </span>
                        ) : (
                          <span className="text-gray-300">—</span>
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>
            ))}
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center gap-3 mt-5">
          <Button variant="outline" size="sm" onClick={onBack} className="h-8 text-xs gap-1.5">
            <ArrowLeft className="h-3 w-3" /> Back
          </Button>
          <div className="ml-2 text-[11px] text-gray-400">
            {validation.mappedCount} of {CANONICAL_FIELDS.length} fields mapped
          </div>
          {!validation.ok && (
            <div className="flex items-center gap-1.5 text-[11px] text-red-600">
              <AlertTriangle className="h-3 w-3" />
              Missing required: {validation.missingRequired.join(', ')}
            </div>
          )}
          <Button
            size="sm"
            onClick={onNext}
            disabled={!validation.ok}
            className="ml-auto h-8 text-xs gap-1.5"
          >
            Validate Rows <ArrowRight className="h-3 w-3" />
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}

// =============================================================================
// Stage 3 — Validation
// =============================================================================

function ValidationStage({
  rows,
  counts,
  onBack,
  onNext,
}: {
  rows: DutyResultRow[];
  counts: { valid: number; warnings: number; blocked: number };
  onBack: () => void;
  onNext: () => void;
}) {
  return (
    <Card>
      <CardContent className="p-5">
        <div className="flex items-center gap-2 mb-5">
          <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
            <ListChecks className="h-3.5 w-3.5 text-[#353CED]" />
          </div>
          <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">
            Validate Rows
          </h3>
        </div>

        {/* Summary tiles */}
        <div className="grid grid-cols-3 gap-3 mb-5">
          <ValidationTile
            label="Ready"
            value={counts.valid}
            icon={<Check className="h-3.5 w-3.5" />}
            tone="emerald"
          />
          <ValidationTile
            label="Warnings"
            value={counts.warnings}
            icon={<AlertTriangle className="h-3.5 w-3.5" />}
            tone="amber"
          />
          <ValidationTile
            label="Blocked"
            value={counts.blocked}
            icon={<X className="h-3.5 w-3.5" />}
            tone="red"
          />
        </div>

        <div className="rounded-lg bg-gray-50 px-3.5 py-2.5 text-[10px] text-gray-400 leading-relaxed mb-5">
          Blocked rows are quarantined (no calculation). Warnings do not block
          processing. Every row — blocked, warning, or clean — is preserved in
          the export so you can repair upstream and re-run.
        </div>

        {/* Sample issues — fixed height to prevent layout shift */}
        <div className="h-60 rounded-xl border border-gray-200/80 overflow-hidden mb-5">
          <div className="bg-gray-50/80 px-3 py-2 text-[11px] font-medium text-gray-500 uppercase tracking-wider border-b border-gray-100">
            {counts.blocked > 0
              ? 'Sample Blocked Rows'
              : counts.warnings > 0
              ? 'Sample Warning Rows'
              : 'No Issues'}
          </div>
          <div className="h-[calc(100%-32px)] overflow-auto">
            <IssueList
              rows={rows}
              kind={counts.blocked > 0 ? 'blocking' : 'warning'}
              limit={30}
            />
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center gap-3">
          <Button variant="outline" size="sm" onClick={onBack} className="h-8 text-xs gap-1.5">
            <ArrowLeft className="h-3 w-3" /> Back
          </Button>
          <span className="text-[11px] text-gray-400 ml-2">
            {counts.valid + counts.warnings} rows will be calculated
          </span>
          <Button
            size="sm"
            onClick={onNext}
            disabled={counts.valid + counts.warnings === 0}
            className="ml-auto h-8 text-xs gap-1.5"
          >
            Calculate Duty <ArrowRight className="h-3 w-3" />
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}

function ValidationTile({
  label,
  value,
  icon,
  tone,
}: {
  label: string;
  value: number;
  icon: React.ReactNode;
  tone: 'emerald' | 'amber' | 'red';
}) {
  const border =
    tone === 'emerald'
      ? 'border-emerald-100/80'
      : tone === 'amber'
      ? 'border-amber-100/80'
      : 'border-red-100/80';
  const bg =
    tone === 'emerald'
      ? 'bg-gradient-to-br from-emerald-50/50 to-white'
      : tone === 'amber'
      ? 'bg-gradient-to-br from-amber-50/50 to-white'
      : 'bg-gradient-to-br from-red-50/50 to-white';
  const iconBg =
    tone === 'emerald'
      ? 'bg-emerald-100/70 text-emerald-700'
      : tone === 'amber'
      ? 'bg-amber-100/70 text-amber-700'
      : 'bg-red-100/70 text-red-700';
  const numberTone =
    tone === 'emerald'
      ? 'text-emerald-700'
      : tone === 'amber'
      ? 'text-amber-700'
      : 'text-red-700';
  return (
    <div
      className={cn(
        'rounded-xl border px-4 py-4 shadow-[0_1px_2px_rgba(15,23,42,0.03)]',
        border,
        bg,
      )}
    >
      <div className="flex items-center gap-2 mb-2">
        <div className={cn('w-5 h-5 rounded-md flex items-center justify-center', iconBg)}>
          {icon}
        </div>
        <span className="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">
          {label}
        </span>
      </div>
      <div
        className={cn(
          'text-[28px] font-semibold tracking-tight font-mono leading-none',
          numberTone,
        )}
      >
        {value.toLocaleString()}
      </div>
    </div>
  );
}

function IssueList({
  rows,
  kind,
  limit,
}: {
  rows: DutyResultRow[];
  kind: 'blocking' | 'warning';
  limit: number;
}) {
  const items: Array<{ row: DutyResultRow; message: string; field: string }> = [];
  for (const row of rows) {
    for (const v of row.validation) {
      if (v.severity === kind) {
        items.push({ row, message: v.message, field: String(v.field) });
      }
    }
    if (items.length >= limit) break;
  }
  if (items.length === 0) {
    return (
      <div className="flex items-center justify-center h-full text-[11px] text-gray-300">
        Nothing to show.
      </div>
    );
  }
  return (
    <div className="divide-y divide-gray-50">
      {items.map((it, i) => (
        <div key={i} className="grid grid-cols-[60px_140px_1fr] gap-3 px-3 py-1.5 text-xs items-center">
          <span className="font-mono text-gray-400">#{it.row.sourceRowIndex}</span>
          <span className="text-gray-500 uppercase text-[10px] tracking-wider">
            {it.field}
          </span>
          <span className="text-gray-700 truncate" title={it.message}>
            {it.message}
          </span>
        </div>
      ))}
    </div>
  );
}

// =============================================================================
// Stage 4 — Processing
// =============================================================================

function ProcessingStage({
  rateProgress,
  calcProgress,
  error,
  onBack,
}: {
  rateProgress: { fetched: number; total: number; found: number; missing: number };
  calcProgress: { processed: number; total: number };
  error: string | null;
  onBack: () => void;
}) {
  const ratePct =
    rateProgress.total > 0
      ? Math.round((rateProgress.fetched / rateProgress.total) * 100)
      : 0;
  const calcPct =
    calcProgress.total > 0
      ? Math.round((calcProgress.processed / calcProgress.total) * 100)
      : 0;
  const isRateDone = rateProgress.total > 0 && rateProgress.fetched >= rateProgress.total;
  const isCalcDone = calcProgress.total > 0 && calcProgress.processed >= calcProgress.total;

  return (
    <Card>
      <CardContent className="p-5">
        <div className="flex items-center gap-2 mb-6">
          <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
            <Calculator className="h-3.5 w-3.5 text-[#353CED]" strokeWidth={2} />
          </div>
          <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">
            Calculating
          </h3>
          <span className="text-[10px] font-medium text-gray-400 uppercase tracking-wider ml-2">
            Deduping keys → fetching rates → applying duty stack
          </span>
        </div>

        <div className="space-y-6">
          <ProgressRow
            label="Fetching rates"
            current={rateProgress.fetched}
            total={rateProgress.total}
            pct={ratePct}
            note={`${rateProgress.found} found · ${rateProgress.missing} missing`}
            done={isRateDone}
          />
          <ProgressRow
            label="Calculating duty"
            current={calcProgress.processed}
            total={calcProgress.total}
            pct={calcPct}
            done={isCalcDone}
          />
        </div>

        {error && (
          <div className="mt-6 flex items-start gap-2.5 px-4 py-3 rounded-xl bg-red-50/80 border border-red-200/60 text-xs text-red-800">
            <AlertCircle className="h-4 w-4 flex-shrink-0 mt-0.5 text-red-500" />
            <span>{error}</span>
          </div>
        )}
        {error && (
          <Button
            variant="outline"
            size="sm"
            onClick={onBack}
            className="mt-4 h-8 text-xs gap-1.5"
          >
            <ArrowLeft className="h-3 w-3" /> Back
          </Button>
        )}
      </CardContent>
    </Card>
  );
}

function ProgressRow({
  label,
  current,
  total,
  pct,
  note,
  done,
}: {
  label: string;
  current: number;
  total: number;
  pct: number;
  note?: string;
  done?: boolean;
}) {
  return (
    <div>
      <div className="flex items-center justify-between mb-2">
        <div className="flex items-center gap-2">
          <div
            className={cn(
              'w-4 h-4 rounded-full flex items-center justify-center transition-colors',
              done
                ? 'bg-emerald-100 text-emerald-600'
                : 'bg-[#353CED]/8 text-[#353CED]',
            )}
          >
            {done ? (
              <Check className="h-2.5 w-2.5" strokeWidth={3} />
            ) : (
              <Loader2 className="h-2.5 w-2.5 animate-spin" strokeWidth={3} />
            )}
          </div>
          <span className="text-[11px] font-semibold text-gray-700 uppercase tracking-[0.08em]">
            {label}
          </span>
        </div>
        <span className="text-[11px] text-gray-500 font-mono tabular-nums">
          {current.toLocaleString()}
          <span className="text-gray-300 mx-1">/</span>
          {total.toLocaleString()}
          {note && (
            <span className="text-gray-300 ml-2 text-[10px]">· {note}</span>
          )}
        </span>
      </div>
      <div className="h-1.5 bg-gray-100 rounded-full overflow-hidden shadow-[inset_0_1px_2px_rgba(15,23,42,0.04)]">
        <div
          className={cn(
            'h-full rounded-full transition-all duration-500 ease-out',
            done
              ? 'bg-emerald-500'
              : 'bg-gradient-to-r from-[#353CED] to-[#4E54F2]',
          )}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}

// =============================================================================
// Stage 5 — Review (reconciliation dashboard)
// =============================================================================

function ReviewStage({
  job,
  onBack,
  onExport,
  onReset,
}: {
  job: ImportJob;
  onBack: () => void;
  onExport: () => void;
  onReset: () => void;
}) {
  const [view, setView] = useState<ReviewView>('results');
  const [groupBy, setGroupBy] = useState<GroupBy>('entry');
  const [selectedLine, setSelectedLine] = useState<MergedLineItem | null>(null);

  const activeGroups = groupBy === 'entry' ? job.entries : job.shipments;
  const groupVarianceBreakdown = useMemo(
    () => summarizeGroupVariance(activeGroups),
    [activeGroups],
  );

  // Line item totals (summed as-provided, including naive per-line MPF/HMF)
  const lineItemTotals = useMemo(() => {
    let cv = 0;
    let duty = 0;
    let mpfSum = 0;
    let hmfSum = 0;
    let brokerDuty = 0;
    let hasBroker = false;
    for (const r of job.rows) {
      if (r.normalized.customsValue != null) cv += r.normalized.customsValue;
      if (r.calculated) {
        duty += r.calculated.totalDuty;
        mpfSum += r.calculated.mpf;
        hmfSum += r.calculated.hmf;
      }
      if (r.normalized.uploadedDuty != null) {
        brokerDuty += r.normalized.uploadedDuty;
        hasBroker = true;
      }
    }
    return {
      customsValue: cv,
      duty,
      mpfSum,
      hmfSum,
      brokerDuty: hasBroker ? brokerDuty : null,
    };
  }, [job.rows]);

  // Recomputed entry-level totals (from group aggregates — canonical)
  const entryTotals = useMemo(() => {
    let cv = 0;
    let duty = 0;
    let mpf = 0;
    let hmf = 0;
    let brokerDuty = 0;
    let hasBroker = false;
    for (const g of job.entries) {
      cv += g.totalCustomsValue;
      duty += g.totalCalculatedDuty;
      mpf += g.recomputedMPF;
      hmf += g.recomputedHMF;
      if (g.totalUploadedDuty != null) {
        brokerDuty += g.totalUploadedDuty;
        hasBroker = true;
      }
    }
    return {
      customsValue: cv,
      duty,
      mpf,
      hmf,
      brokerDuty: hasBroker ? brokerDuty : null,
    };
  }, [job.entries]);

  return (
    <div className="grid grid-cols-[1fr_316px] gap-5 h-[calc(100vh-260px)] min-h-[560px]">
      {/* Left: grid card — flex column fills the full grid-row height */}
      <Card className="flex flex-col min-h-0 overflow-hidden">
        <CardContent className="p-0 flex flex-col flex-1 min-h-0">
          {/* Toolbar */}
          <div className="flex items-center gap-3 px-5 py-4 border-b border-gray-100 bg-gradient-to-b from-white to-gray-50/30">
            <div className="flex items-center gap-2">
              <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
                <LayoutGrid className="h-3.5 w-3.5 text-[#353CED]" strokeWidth={2} />
              </div>
              <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">
                Review
              </h3>
            </div>

            {/* View segmented */}
            <div
              className="flex items-center gap-0.5 h-8 rounded-xl p-1 bg-white ml-3"
              style={{ boxShadow: NEU_INSET }}
            >
              {(
                [
                  ['results', 'Results', LayoutGrid],
                  ['reconciliation', 'Reconciliation', GitCompareArrows],
                  ['exceptions', 'Exceptions', AlertTriangle],
                ] as [ReviewView, string, React.ElementType][]
              ).map(([key, label, Icon]) => (
                <button
                  key={key}
                  type="button"
                  onClick={() => setView(key)}
                  className={cn(
                    'inline-flex items-center h-6 gap-1.5 rounded-lg px-2.5 text-[11px] font-medium transition-all duration-200 ease-out',
                    'text-gray-400 hover:text-gray-600',
                    view === key && 'shadow-glass text-[#353CED] bg-white',
                  )}
                >
                  <Icon className="h-3 w-3" strokeWidth={2} />
                  {label}
                </button>
              ))}
            </div>

            {/* Group by */}
            <div
              className="flex items-center gap-0.5 h-8 rounded-xl p-1 bg-white"
              style={{ boxShadow: NEU_INSET }}
            >
              {(
                [
                  ['entry', 'Entry', Package],
                  ['shipment', 'Shipment', Layers],
                ] as [GroupBy, string, React.ElementType][]
              ).map(([key, label, Icon]) => (
                <button
                  key={key}
                  type="button"
                  onClick={() => setGroupBy(key)}
                  className={cn(
                    'inline-flex items-center h-6 gap-1.5 rounded-lg px-2.5 text-[11px] font-medium transition-all duration-200 ease-out',
                    'text-gray-400 hover:text-gray-600',
                    groupBy === key && 'shadow-glass text-[#353CED] bg-white',
                  )}
                >
                  <Icon className="h-3 w-3" strokeWidth={2} />
                  {label}
                </button>
              ))}
            </div>

            <div className="ml-auto flex items-center gap-2">
              <Button
                size="sm"
                onClick={onExport}
                className="h-8 text-xs gap-1.5"
              >
                <Download className="h-3 w-3" strokeWidth={2} /> Export XLSX
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={onReset}
                className="h-8 text-xs gap-1.5 text-gray-400 hover:text-gray-700"
              >
                <RefreshCw className="h-3 w-3" strokeWidth={2} /> Start Over
              </Button>
            </div>
          </div>

          {/* Reconciliation dashboard strip */}
          {view === 'reconciliation' && (
            <ReconciliationDashboard
              breakdown={groupVarianceBreakdown}
              groupBy={groupBy}
            />
          )}

          {/* Grid — fills remaining card height and handles its own internal scroll */}
          <div className="flex-1 min-h-0 flex flex-col">
            <BulkResultsGrid
              rows={job.rows}
              lineItems={job.lineItems}
              entries={job.entries}
              shipments={job.shipments}
              view={view}
              groupBy={groupBy}
              onLineClick={setSelectedLine}
            />
          </div>
        </CardContent>
      </Card>

      {/* Line detail drawer — rate history + duty stack for the clicked HTS */}
      <LineDetailDrawer
        lineItem={selectedLine}
        rows={job.rows}
        onClose={() => setSelectedLine(null)}
      />

      {/* Right: summary rail — scrolls independently when content overflows */}
      <div className="space-y-4 overflow-y-auto min-h-0 pr-1 -mr-1">
        <JobSummaryCard summary={job.jobSummary} />
        <TotalsCard
          title="Line Item Totals"
          subtitle="Per-line sums · MPF/HMF naive"
          icon={<ListChecks className="h-3 w-3 text-gray-500" strokeWidth={2} />}
          totals={{
            customsValue: lineItemTotals.customsValue,
            duty: lineItemTotals.duty,
            mpf: lineItemTotals.mpfSum,
            hmf: lineItemTotals.hmfSum,
            broker: lineItemTotals.brokerDuty,
          }}
          informational
        />
        <TotalsCard
          title="Entry Totals"
          subtitle="Per-entry MPF cap applied"
          icon={<Package className="h-3 w-3 text-[#353CED]" strokeWidth={2} />}
          totals={{
            customsValue: entryTotals.customsValue,
            duty: entryTotals.duty,
            mpf: entryTotals.mpf,
            hmf: entryTotals.hmf,
            broker: entryTotals.brokerDuty,
          }}
        />
        <FlagCountsCard summary={job.jobSummary} />
        <Button
          variant="outline"
          size="sm"
          onClick={onBack}
          className="w-full h-8 text-xs gap-1.5"
        >
          <ArrowLeft className="h-3 w-3" strokeWidth={2} /> Back to Validation
        </Button>
      </div>
    </div>
  );
}

function ReconciliationDashboard({
  breakdown,
  groupBy,
}: {
  breakdown: ReturnType<typeof summarizeGroupVariance>;
  groupBy: GroupBy;
}) {
  const tiles: {
    label: string;
    value: number;
    color: string;
    bg: string;
    border: string;
    text: string;
  }[] = [
    {
      label: 'Match',
      value: breakdown.match,
      color: '#059669',
      bg: 'from-emerald-50/80 to-white',
      border: 'border-emerald-100/60',
      text: 'text-emerald-700',
    },
    {
      label: 'Minor',
      value: breakdown.minor,
      color: '#ca8a04',
      bg: 'from-yellow-50/80 to-white',
      border: 'border-yellow-100/60',
      text: 'text-yellow-700',
    },
    {
      label: 'Material',
      value: breakdown.material,
      color: '#d97706',
      bg: 'from-amber-50/80 to-white',
      border: 'border-amber-100/60',
      text: 'text-amber-700',
    },
    {
      label: 'Critical',
      value: breakdown.critical,
      color: '#dc2626',
      bg: 'from-red-50/80 to-white',
      border: 'border-red-100/60',
      text: 'text-red-700',
    },
    {
      label: 'No Broker Data',
      value: breakdown.noUpload,
      color: '#94a3b8',
      bg: 'from-slate-50/80 to-white',
      border: 'border-slate-100/60',
      text: 'text-slate-600',
    },
  ];
  return (
    <div className="grid grid-cols-5 gap-3 px-5 py-4 bg-gradient-to-b from-gray-50/60 to-white border-b border-gray-100">
      {tiles.map((t) => (
        <div
          key={t.label}
          className={cn(
            'rounded-xl bg-gradient-to-br px-3.5 py-3 border shadow-[0_1px_2px_rgba(15,23,42,0.03)]',
            t.bg,
            t.border,
          )}
        >
          <div className="flex items-center gap-1.5 mb-1">
            <span
              className="w-1.5 h-1.5 rounded-full"
              style={{ backgroundColor: t.color }}
            />
            <span className="text-[9px] font-semibold uppercase tracking-[0.08em] text-gray-500">
              {t.label}
            </span>
          </div>
          <div
            className={cn(
              'font-mono tabular-nums text-[22px] font-semibold leading-none mt-1.5',
              t.text,
            )}
          >
            {t.value.toLocaleString()}
          </div>
          <div className="text-[9px] text-gray-300 mt-0.5 uppercase tracking-wider">
            {groupBy === 'entry' ? 'entries' : 'shipments'}
          </div>
        </div>
      ))}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Summary rail cards
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Reusable card header
// -----------------------------------------------------------------------------

function RailCardHeader({
  title,
  subtitle,
  icon,
  accent,
}: {
  title: string;
  subtitle?: string;
  icon: React.ReactNode;
  accent?: 'primary' | 'muted';
}) {
  const iconBg =
    accent === 'muted'
      ? 'bg-gray-100 text-gray-500'
      : 'bg-[#353CED]/8 text-[#353CED]';
  return (
    <div className="mb-3">
      <div className="flex items-center gap-2">
        <div
          className={cn(
            'w-5 h-5 rounded-md flex items-center justify-center',
            iconBg,
          )}
        >
          {icon}
        </div>
        <h4 className="text-[10px] font-semibold text-gray-900 uppercase tracking-[0.08em]">
          {title}
        </h4>
      </div>
      {subtitle && (
        <div className="text-[10px] text-gray-400 leading-tight ml-7 mt-0.5">
          {subtitle}
        </div>
      )}
    </div>
  );
}

function JobSummaryCard({ summary }: { summary: JobSummary }) {
  return (
    <Card>
      <CardContent className="p-4">
        <RailCardHeader
          title="Job Summary"
          icon={<Info className="h-3 w-3" strokeWidth={2} />}
        />
        <div className="space-y-0.5">
          <StatRow label="Total rows" value={summary.totalRows.toLocaleString()} mono />
          <StatRow
            label="Ready"
            value={summary.validRows.toLocaleString()}
            mono
            tone="emerald"
          />
          <StatRow
            label="Warnings"
            value={summary.warningRows.toLocaleString()}
            mono
            tone="amber"
          />
          <StatRow
            label="Blocked"
            value={summary.blockedRows.toLocaleString()}
            mono
            tone="red"
          />
          <div className="h-px bg-gray-100 my-2" />
          <StatRow label="Entries" value={summary.entryCount.toLocaleString()} mono />
          <StatRow label="Shipments" value={summary.shipmentCount.toLocaleString()} mono />
          <StatRow
            label="Unique rate keys"
            value={summary.uniqueRateKeys.toLocaleString()}
            mono
          />
        </div>
      </CardContent>
    </Card>
  );
}

function TotalsCard({
  title,
  subtitle,
  icon,
  totals,
  informational,
}: {
  title: string;
  subtitle: string;
  icon: React.ReactNode;
  totals: {
    customsValue: number;
    duty: number;
    mpf: number;
    hmf: number;
    broker: number | null;
  };
  informational?: boolean;
}) {
  const variance = totals.broker != null ? totals.duty - totals.broker : null;
  const varianceTone =
    variance == null
      ? 'text-gray-400'
      : Math.abs(variance) < 1
      ? 'text-emerald-600'
      : Math.abs(variance) < 50
      ? 'text-yellow-700'
      : Math.abs(variance) < 500
      ? 'text-amber-600'
      : 'text-red-600';
  return (
    <Card className={cn(informational && 'bg-gray-50/40')}>
      <CardContent className="p-4">
        <RailCardHeader
          title={title}
          subtitle={subtitle}
          icon={icon}
          accent={informational ? 'muted' : 'primary'}
        />

        {/* Hero number — SAIL duty */}
        <div className="mb-3">
          <div className="text-[9px] font-semibold uppercase tracking-[0.08em] text-gray-400 mb-0.5">
            SAIL Duty
          </div>
          <div className="font-mono tabular-nums text-[20px] font-semibold text-red-600 leading-none">
            {formatCurrencyCompact(totals.duty)}
          </div>
        </div>

        <div className="space-y-0.5">
          <StatRow
            label="Customs value"
            value={formatCurrencyCompact(totals.customsValue)}
            mono
          />
          <StatRow label="MPF" value={formatCurrencyCompact(totals.mpf)} mono tone="fees" />
          <StatRow label="HMF" value={formatCurrencyCompact(totals.hmf)} mono tone="fees" />

          {totals.broker != null && (
            <>
              <div className="h-px bg-gray-100 my-2" />
              <StatRow
                label="Broker duty"
                value={formatCurrencyCompact(totals.broker)}
                mono
              />
              <div className="flex items-center justify-between py-1 text-[11px]">
                <span className="text-gray-500">Variance</span>
                <div className="flex items-center gap-1">
                  {variance != null &&
                    (Math.abs(variance) < 0.01 ? (
                      <Minus className="h-3 w-3 text-gray-400" strokeWidth={2} />
                    ) : variance > 0 ? (
                      <TrendingUp className="h-3 w-3 text-red-500" strokeWidth={2} />
                    ) : (
                      <TrendingDown className="h-3 w-3 text-emerald-500" strokeWidth={2} />
                    ))}
                  <span className={cn('font-mono font-semibold tabular-nums', varianceTone)}>
                    {variance != null ? formatCurrency(variance) : '—'}
                  </span>
                </div>
              </div>
            </>
          )}
        </div>
      </CardContent>
    </Card>
  );
}

function FlagCountsCard({ summary }: { summary: JobSummary }) {
  const entries = Object.entries(summary.flagCounts);
  if (entries.length === 0) return null;
  return (
    <Card>
      <CardContent className="p-4">
        <RailCardHeader
          title="Flag Counts"
          icon={<AlertTriangle className="h-3 w-3" strokeWidth={2} />}
        />
        <div className="space-y-0.5">
          {entries.map(([kind, count]) => (
            <StatRow
              key={kind}
              label={kind.replace(/_/g, ' ')}
              value={String(count)}
              mono
            />
          ))}
        </div>
      </CardContent>
    </Card>
  );
}

function StatRow({
  label,
  value,
  mono,
  tone,
}: {
  label: string;
  value: string;
  mono?: boolean;
  tone?: 'emerald' | 'amber' | 'red' | 'duty' | 'fees';
}) {
  const toneClass =
    tone === 'emerald'
      ? 'text-emerald-600'
      : tone === 'amber'
      ? 'text-amber-600'
      : tone === 'red'
      ? 'text-red-600'
      : tone === 'duty'
      ? 'text-red-600'
      : tone === 'fees'
      ? 'text-amber-600'
      : 'text-gray-800';
  return (
    <div className="flex items-center justify-between py-1 text-[11px] leading-none">
      <span className="text-gray-500 truncate">{label}</span>
      <span className={cn('font-semibold tabular-nums', mono && 'font-mono', toneClass)}>
        {value}
      </span>
    </div>
  );
}
