import React, { useState } from 'react';
import * as PopoverPrimitive from '@radix-ui/react-popover';
import { Button } from '@/components/ui/button';
import { CalendarDays } from 'lucide-react';

const NEU_BG = '#FAFAF8';
const neuInset = `inset 2px 2px 5px rgba(0,0,0,0.08), inset -2px -2px 5px rgba(255,255,255,0.9)`;
const neuRaisedSm = `2px 2px 4px rgba(0,0,0,0.08), -2px -2px 4px rgba(255,255,255,0.9)`;

const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

interface DatePickerNeuProps {
  date: Date;
  onSelect: (d: Date) => void;
  minDate?: Date;
  maxDate?: Date;
}

export function DatePickerNeu({ date, onSelect, minDate, maxDate }: DatePickerNeuProps) {
  const [open, setOpen] = useState(false);
  const [viewMonth, setViewMonth] = useState<Date>(date);

  const formatted = date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });

  return (
    <PopoverPrimitive.Root open={open} onOpenChange={setOpen}>
      <PopoverPrimitive.Trigger asChild>
        <Button variant="outline" className="h-9 w-full justify-start text-left text-sm font-normal gap-2 px-3">
          <CalendarDays className="h-3.5 w-3.5 text-gray-400" />
          {formatted}
        </Button>
      </PopoverPrimitive.Trigger>
      <PopoverPrimitive.Portal>
        <PopoverPrimitive.Content
          className="z-[100] rounded-xl border border-gray-100 shadow-lg outline-none animate-fade-in"
          align="start"
          sideOffset={4}
        >
          <NeuCalendar
            selected={date}
            month={viewMonth}
            onMonthChange={setViewMonth}
            minDate={minDate}
            maxDate={maxDate}
            onDayClick={(d) => { onSelect(d); setOpen(false); }}
          />
        </PopoverPrimitive.Content>
      </PopoverPrimitive.Portal>
    </PopoverPrimitive.Root>
  );
}

function NeuCalendar({
  selected, month, onMonthChange, onDayClick, minDate, maxDate,
}: {
  selected: Date; month: Date; onMonthChange: (d: Date) => void;
  onDayClick: (d: Date) => void; minDate?: Date; maxDate?: Date;
}) {
  const year = month.getFullYear();
  const monthIdx = month.getMonth();
  const firstDay = new Date(year, monthIdx, 1);
  const startOffset = firstDay.getDay();
  const daysInMonth = new Date(year, monthIdx + 1, 0).getDate();
  const daysInPrevMonth = new Date(year, monthIdx, 0).getDate();

  const cells: Array<{ day: number; date: Date; outside: boolean }> = [];
  for (let i = startOffset - 1; i >= 0; i--)
    cells.push({ day: daysInPrevMonth - i, date: new Date(year, monthIdx - 1, daysInPrevMonth - i), outside: true });
  for (let d = 1; d <= daysInMonth; d++)
    cells.push({ day: d, date: new Date(year, monthIdx, d), outside: false });
  const remaining = 42 - cells.length;
  for (let d = 1; d <= remaining; d++)
    cells.push({ day: d, date: new Date(year, monthIdx + 1, d), outside: true });

  const today = new Date();
  const isSameDay = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

  const yearRange: number[] = [];
  for (let y = year - 5; y <= year + 5; y++) yearRange.push(y);

  return (
    <div className="p-4 rounded-xl select-none" style={{ background: NEU_BG }}>
      <div className="flex items-center justify-between mb-3">
        <button type="button" onClick={() => onMonthChange(new Date(year, monthIdx - 1, 1))}
          className="h-8 w-8 flex items-center justify-center rounded-full text-gray-500 hover:text-gray-900 transition-all cursor-pointer"
          style={{ boxShadow: neuRaisedSm, background: NEU_BG }}>
          <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round"><path d="M15 18l-6-6 6-6" /></svg>
        </button>
        <div className="flex items-center gap-1.5">
          <select value={monthIdx} onChange={(e) => onMonthChange(new Date(year, parseInt(e.target.value), 1))}
            className="text-sm font-semibold text-gray-800 appearance-none px-2.5 py-1 rounded-lg border-0 cursor-pointer focus:outline-none focus:ring-2 focus:ring-[#353CED]/20"
            style={{ boxShadow: neuInset, background: NEU_BG }}>
            {MONTHS.map((m, i) => <option key={i} value={i}>{m}</option>)}
          </select>
          <select value={year} onChange={(e) => onMonthChange(new Date(parseInt(e.target.value), monthIdx, 1))}
            className="text-sm font-semibold text-gray-800 appearance-none px-2.5 py-1 rounded-lg border-0 cursor-pointer focus:outline-none focus:ring-2 focus:ring-[#353CED]/20"
            style={{ boxShadow: neuInset, background: NEU_BG }}>
            {yearRange.map(y => <option key={y} value={y}>{y}</option>)}
          </select>
        </div>
        <button type="button" onClick={() => onMonthChange(new Date(year, monthIdx + 1, 1))}
          className="h-8 w-8 flex items-center justify-center rounded-full text-gray-500 hover:text-gray-900 transition-all cursor-pointer"
          style={{ boxShadow: neuRaisedSm, background: NEU_BG }}>
          <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round"><path d="M9 18l6-6-6-6" /></svg>
        </button>
      </div>
      <div className="grid grid-cols-7 mb-1">
        {['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'].map(d => (
          <div key={d} className="text-center text-[10px] font-medium text-gray-400 py-1">{d}</div>
        ))}
      </div>
      <div className="grid grid-cols-7 gap-1">
        {cells.map((cell, i) => {
          const isSelected = isSameDay(cell.date, selected);
          const isToday = isSameDay(cell.date, today) && !isSelected;
          const isDisabled =
            (minDate && cell.date < new Date(minDate.getFullYear(), minDate.getMonth(), minDate.getDate())) ||
            (maxDate && cell.date > new Date(maxDate.getFullYear(), maxDate.getMonth(), maxDate.getDate()));
          return (
            <button key={i} type="button" disabled={!!isDisabled}
              onClick={() => !isDisabled && onDayClick(cell.date)}
              className={`h-8 w-8 flex items-center justify-center rounded-full text-xs transition-all
                ${isDisabled ? 'text-gray-200 cursor-not-allowed' : 'cursor-pointer'}
                ${cell.outside && !isDisabled ? 'text-gray-300' : !isDisabled ? 'text-gray-700' : ''}
                ${isSelected ? 'text-white font-semibold' : ''}
                ${isToday && !isDisabled ? 'font-semibold' : ''}
                ${!isSelected && !cell.outside && !isDisabled ? 'hover:text-gray-900' : ''}`}
              style={{
                background: isSelected ? '#353CED' : isToday ? 'linear-gradient(145deg, #e8e8e6, #ffffff)' : 'transparent',
                boxShadow: isSelected ? 'inset 2px 2px 4px rgba(0,0,0,0.2), inset -1px -1px 3px rgba(255,255,255,0.1)' : isToday ? neuRaisedSm : 'none',
              }}>
              {cell.day}
            </button>
          );
        })}
      </div>
    </div>
  );
}
