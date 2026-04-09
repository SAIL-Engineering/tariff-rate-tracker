import React, { useState, useCallback, useRef } from 'react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Upload, FileSpreadsheet, Check, AlertCircle, X } from 'lucide-react';
import type { ShipmentRow } from '@/types/tariff';

interface ShipmentImportDialogProps {
  open: boolean;
  onClose: () => void;
  onImport: (rows: ShipmentRow[]) => void;
  minDate?: Date;
  maxDate?: Date;
}

interface ParsedRow {
  date: string;
  value: number;
  valid: boolean;
  error?: string;
}

function StepIndicator({ step, total }: { step: number; total: number }) {
  return (
    <div className="flex items-center gap-2 mb-4">
      {Array.from({ length: total }).map((_, i) => (
        <React.Fragment key={i}>
          <div className={`w-7 h-7 rounded-full flex items-center justify-center text-xs font-semibold transition-all duration-300 ease-spring ${
            i < step ? 'bg-[#353CED] text-white' : i === step ? 'bg-[#353CED] text-white ring-4 ring-[#353CED]/15' : 'bg-gray-100 text-gray-400'
          }`}>
            {i < step ? <Check className="h-3.5 w-3.5" /> : i + 1}
          </div>
          {i < total - 1 && <div className={`flex-1 h-0.5 ${i < step ? 'bg-[#353CED]' : 'bg-gray-200'}`} />}
        </React.Fragment>
      ))}
    </div>
  );
}

export function ShipmentImportDialog({ open, onClose, onImport, minDate, maxDate }: ShipmentImportDialogProps) {
  const [step, setStep] = useState(0);
  const [rawText, setRawText] = useState('');
  const [columns, setColumns] = useState<string[]>([]);
  const [rawRows, setRawRows] = useState<string[][]>([]);
  const [dateCol, setDateCol] = useState(0);
  const [valueCol, setValueCol] = useState(1);
  const [parsedRows, setParsedRows] = useState<ParsedRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const reset = () => { setStep(0); setRawText(''); setColumns([]); setRawRows([]); setParsedRows([]); setError(null); };

  const handleFile = useCallback((file: File) => {
    setError(null);
    const reader = new FileReader();
    reader.onload = (e) => {
      const text = e.target?.result as string;
      const lines = text.split('\n').map(l => l.trim()).filter(Boolean);
      if (lines.length < 2) { setError('File must have at least a header and one data row.'); return; }
      const header = lines[0].split(',').map(s => s.trim().replace(/^"|"$/g, ''));
      const data = lines.slice(1).map(l => l.split(',').map(s => s.trim().replace(/^"|"$/g, '')));
      setColumns(header);
      setRawRows(data);

      // Auto-detect columns
      const dateCandidates = header.map((h, i) => ({ h: h.toLowerCase(), i }));
      const dateIdx = dateCandidates.find(c => c.h.includes('date'))?.i ?? 0;
      const valueIdx = dateCandidates.find(c => c.h.includes('value') || c.h.includes('amount'))?.i ?? (dateIdx === 0 ? 1 : 0);
      setDateCol(dateIdx);
      setValueCol(valueIdx);
      setStep(1);
    };
    reader.readAsText(file);
  }, []);

  const handleParse = useCallback(() => {
    const parsed: ParsedRow[] = rawRows.map(row => {
      const dateStr = row[dateCol]?.trim();
      const valueStr = row[valueCol]?.trim();
      const value = parseFloat(valueStr?.replace(/[$,]/g, '') ?? '');
      if (!dateStr || isNaN(value)) {
        return { date: dateStr ?? '', value: 0, valid: false, error: 'Invalid date or value' };
      }
      const date = new Date(dateStr);
      if (isNaN(date.getTime())) {
        return { date: dateStr, value, valid: false, error: `Cannot parse date: ${dateStr}` };
      }
      if (minDate && date < minDate) return { date: dateStr, value, valid: false, error: 'Date before range' };
      if (maxDate && date > maxDate) return { date: dateStr, value, valid: false, error: 'Date after range' };
      return { date: date.toISOString().slice(0, 10), value, valid: true };
    });
    setParsedRows(parsed);
    setStep(2);
  }, [rawRows, dateCol, valueCol, minDate, maxDate]);

  const handleImport = useCallback(() => {
    const valid = parsedRows.filter(r => r.valid);
    const rows: ShipmentRow[] = valid.map((r, i) => ({
      id: `import-${Date.now()}-${i}`,
      customsValue: r.value,
      date: new Date(r.date + 'T00:00:00'),
    }));
    onImport(rows);
    reset();
    onClose();
  }, [parsedRows, onImport, onClose]);

  if (!open) return null;

  const validCount = parsedRows.filter(r => r.valid).length;
  const invalidCount = parsedRows.filter(r => !r.valid).length;

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center">
      <div className="fixed inset-0 bg-black/40 backdrop-blur-[2px]" onClick={() => { reset(); onClose(); }} />
      <div className="relative bg-white rounded-2xl shadow-glass-lg w-full max-w-[680px] max-h-[90vh] overflow-hidden flex flex-col z-[61] animate-scale-in">
        {/* Header */}
        <div className="px-6 py-4 border-b border-gray-100/80 flex items-center justify-between">
          <div>
            <h2 className="text-sm font-semibold text-gray-900">Import Shipments</h2>
            <p className="text-xs text-gray-400 mt-0.5">Upload a CSV file with date and value columns</p>
          </div>
          <button onClick={() => { reset(); onClose(); }} className="text-gray-400 hover:text-gray-600">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="px-6 py-4 flex-1 overflow-y-auto">
          <StepIndicator step={step} total={3} />

          {error && (
            <div className="flex items-start gap-2 px-3 py-2 rounded-lg bg-red-50 border border-red-200 text-xs text-red-700 mb-4">
              <AlertCircle className="h-4 w-4 flex-shrink-0 mt-0.5" /> {error}
            </div>
          )}

          {/* Step 0: Upload */}
          {step === 0 && (
            <div className="space-y-4">
              <div className="border-2 border-dashed border-gray-200 rounded-xl p-8 text-center hover:border-[#353CED]/30 hover:bg-[#353CED]/[0.02] transition-all duration-200 ease-spring cursor-pointer"
                onClick={() => fileRef.current?.click()}
                onDragOver={(e) => { e.preventDefault(); e.stopPropagation(); }}
                onDrop={(e) => { e.preventDefault(); const f = e.dataTransfer.files[0]; if (f) handleFile(f); }}>
                <input ref={fileRef} type="file" accept=".csv,.xlsx,.xls" className="hidden"
                  onChange={(e) => { const f = e.target.files?.[0]; if (f) handleFile(f); }} />
                <Upload className="h-8 w-8 text-gray-300 mx-auto mb-3" />
                <p className="text-sm text-gray-600 font-medium">Drop a file here or click to browse</p>
                <p className="text-xs text-gray-400 mt-1">Supports CSV, XLSX, XLS</p>
              </div>
              <div className="text-xs text-gray-400">
                <strong>Expected format:</strong> CSV with header row. Columns should include a date and a customs value.
              </div>
            </div>
          )}

          {/* Step 1: Map columns */}
          {step === 1 && (
            <div className="space-y-4">
              <div className="text-xs font-medium text-gray-700 mb-2">Map your columns:</div>
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-1.5">
                  <label className="text-[10px] font-medium text-gray-500 uppercase tracking-wider">Date Column</label>
                  <select value={dateCol} onChange={(e) => setDateCol(Number(e.target.value))}
                    className="w-full h-9 rounded-md border border-gray-200 px-3 text-sm">
                    {columns.map((c, i) => <option key={i} value={i}>{c}</option>)}
                  </select>
                </div>
                <div className="space-y-1.5">
                  <label className="text-[10px] font-medium text-gray-500 uppercase tracking-wider">Value Column</label>
                  <select value={valueCol} onChange={(e) => setValueCol(Number(e.target.value))}
                    className="w-full h-9 rounded-md border border-gray-200 px-3 text-sm">
                    {columns.map((c, i) => <option key={i} value={i}>{c}</option>)}
                  </select>
                </div>
              </div>
              <div className="text-xs text-gray-400">
                Preview: {rawRows.length} rows detected. First row: {rawRows[0]?.[dateCol]} / {rawRows[0]?.[valueCol]}
              </div>
              <Button onClick={handleParse} size="sm" className="w-full">Preview Import</Button>
            </div>
          )}

          {/* Step 2: Preview */}
          {step === 2 && (
            <div className="space-y-4">
              <div className="flex items-center gap-3">
                {validCount > 0 && (
                  <Badge className="bg-emerald-100 text-emerald-800 border-emerald-200">{validCount} valid</Badge>
                )}
                {invalidCount > 0 && (
                  <Badge className="bg-red-100 text-red-800 border-red-200">{invalidCount} invalid</Badge>
                )}
              </div>
              <div className="rounded-lg border border-gray-200 overflow-hidden max-h-[240px] overflow-y-auto">
                <table className="w-full text-xs">
                  <thead className="bg-gray-50 sticky top-0">
                    <tr>
                      <th className="px-3 py-2 text-left text-[10px] font-medium text-gray-500">Status</th>
                      <th className="px-3 py-2 text-left text-[10px] font-medium text-gray-500">Date</th>
                      <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500">Value (USD)</th>
                      <th className="px-3 py-2 text-left text-[10px] font-medium text-gray-500">Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    {parsedRows.slice(0, 50).map((r, i) => (
                      <tr key={i} className={`border-t border-gray-50 ${!r.valid ? 'bg-red-50/50' : ''}`}>
                        <td className="px-3 py-1.5">
                          {r.valid ? <Check className="h-3.5 w-3.5 text-emerald-500" /> : <AlertCircle className="h-3.5 w-3.5 text-red-500" />}
                        </td>
                        <td className="px-3 py-1.5 font-mono">{r.date}</td>
                        <td className="px-3 py-1.5 text-right font-mono">${r.value.toLocaleString()}</td>
                        <td className="px-3 py-1.5 text-red-500">{r.error ?? ''}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {parsedRows.length > 50 && (
                <div className="text-xs text-gray-400 text-center">Showing first 50 of {parsedRows.length} rows</div>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        {step === 2 && (
          <div className="px-6 py-4 border-t border-gray-100 flex items-center justify-end gap-3">
            <Button variant="outline" size="sm" onClick={() => setStep(1)}>Back</Button>
            <Button size="sm" onClick={handleImport} disabled={validCount === 0}>
              <FileSpreadsheet className="h-3.5 w-3.5 mr-1.5" />
              Import {validCount} Shipments
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}
