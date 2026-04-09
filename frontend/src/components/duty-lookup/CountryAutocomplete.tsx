import React, { useState, useRef, useEffect, useMemo, useId } from 'react';
import { Input } from '@/components/ui/input';
import { cn } from '@/lib/utils';
import type { Country } from '@/types/tariff';
import { Search } from 'lucide-react';

interface CountryAutocompleteProps {
  countries: Country[];
  value: Country | null;
  onChange: (country: Country | null) => void;
  placeholder?: string;
  className?: string;
  /** Auto-add the selected country (skip the separate Add button) */
  onAutoAdd?: (country: Country) => void;
}

export function CountryAutocomplete({
  countries, value, onChange, placeholder = 'Search country...', className, onAutoAdd,
}: CountryAutocompleteProps) {
  const [query, setQuery] = useState('');
  const [open, setOpen] = useState(false);
  const [highlightedIndex, setHighlightedIndex] = useState(-1);
  const ref = useRef<HTMLDivElement>(null);
  const optionRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const listboxId = useId();

  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
        setHighlightedIndex(-1);
      }
    }
    document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, []);

  // Pre-sort countries alphabetically by name (stable across renders)
  const sorted = useMemo(
    () => [...countries].sort((a, b) => a.name.localeCompare(b.name)),
    [countries]
  );

  const filtered = useMemo(() => {
    if (!query) return sorted;
    const q = query.toLowerCase();
    return sorted.filter(c => (
      c.name.toLowerCase().includes(q) ||
      c.code.includes(query) ||
      (c.alpha2 && c.alpha2.toLowerCase() === q) ||
      (c.alpha3 && c.alpha3.toLowerCase() === q)
    ));
  }, [query, sorted]);

  useEffect(() => {
    if (!open) {
      setHighlightedIndex(-1);
      return;
    }
    if (filtered.length === 0) {
      setHighlightedIndex(-1);
      return;
    }
    setHighlightedIndex(prev => {
      if (prev >= 0 && prev < filtered.length) return prev;
      const selectedIndex = value ? filtered.findIndex(c => c.code === value.code) : -1;
      return selectedIndex >= 0 ? selectedIndex : 0;
    });
  }, [filtered, open, value]);

  useEffect(() => {
    if (!open || highlightedIndex < 0) return;
    optionRefs.current[highlightedIndex]?.scrollIntoView({ block: 'nearest' });
  }, [highlightedIndex, open]);

  const handleSelect = (c: Country) => {
    onChange(c);
    setOpen(false);
    setQuery('');
    setHighlightedIndex(-1);
    if (onAutoAdd) onAutoAdd(c);
  };

  const moveHighlight = (direction: 1 | -1) => {
    if (filtered.length === 0) return;
    setOpen(true);
    setHighlightedIndex(prev => {
      if (prev < 0) return direction === 1 ? 0 : filtered.length - 1;
      return (prev + direction + filtered.length) % filtered.length;
    });
  };

  return (
    <div ref={ref} className={cn('relative', className)}>
      <div className="relative cursor-pointer" onClick={() => { if (!open) { setOpen(true); setQuery(''); } }}>
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-gray-400 pointer-events-none" />
        <Input
          value={open ? query : (value ? `${value.name}${value.alpha2 ? ` (${value.alpha2})` : ` (${value.code})`}` : '')}
          onChange={(e) => { setQuery(e.target.value); setOpen(true); }}
          onFocus={() => { setOpen(true); setQuery(''); }}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') {
              e.preventDefault();
              moveHighlight(1);
              return;
            }
            if (e.key === 'ArrowUp') {
              e.preventDefault();
              moveHighlight(-1);
              return;
            }
            if (e.key === 'Enter') {
              if (!open || highlightedIndex < 0 || !filtered[highlightedIndex]) return;
              e.preventDefault();
              handleSelect(filtered[highlightedIndex]);
              return;
            }
            if (e.key === 'Escape') {
              setOpen(false);
              setHighlightedIndex(-1);
            }
          }}
          placeholder={placeholder}
          className="pl-9 h-9 text-sm cursor-pointer"
          role="combobox"
          aria-expanded={open}
          aria-controls={open ? listboxId : undefined}
          aria-activedescendant={
            open && highlightedIndex >= 0 && filtered[highlightedIndex]
              ? `${listboxId}-${filtered[highlightedIndex].code}`
              : undefined
          }
          aria-autocomplete="list"
        />
      </div>
      {open && (
        <div
          id={listboxId}
          role="listbox"
          className="absolute top-full left-0 right-0 mt-1 z-[200] bg-white border border-gray-200 rounded-lg shadow-lg max-h-64 overflow-auto min-w-[280px]"
        >
          {filtered.length === 0 ? (
            <div className="px-3 py-2 text-sm text-gray-400">No countries found</div>
          ) : (
            filtered.map((c, index) => (
              <button
                key={c.code}
                id={`${listboxId}-${c.code}`}
                ref={(node) => { optionRefs.current[index] = node; }}
                type="button"
                role="option"
                aria-selected={highlightedIndex === index}
                className={cn(
                  'w-full text-left px-3 py-2 text-sm transition-colors flex items-center justify-between gap-3',
                  highlightedIndex === index
                    ? 'bg-[#353CED]/10 text-gray-900'
                    : 'hover:bg-[#353CED]/10 hover:text-gray-900',
                  value?.code === c.code && 'font-medium text-[#353CED]'
                )}
                onMouseEnter={() => setHighlightedIndex(index)}
                onClick={() => handleSelect(c)}>
                <span className="truncate">{c.name}</span>
                <span className="text-xs text-gray-400 font-mono flex-shrink-0 whitespace-nowrap">
                  {c.alpha2 || '—'} · {c.code}
                </span>
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
}
