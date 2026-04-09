import React from 'react';
import { Badge } from '@/components/ui/badge';
import { cn } from '@/lib/utils';

interface TariffProgramBadgeProps {
  label: string;
  rate?: number;
  className?: string;
}

const PROGRAM_COLORS: Record<string, string> = {
  'SECTION 301': 'bg-red-100 text-red-800 border-red-200',
  'SECTION 232': 'bg-orange-100 text-orange-800 border-orange-200',
  'SECTION 122': 'bg-amber-100 text-amber-800 border-amber-200',
  'IEEPA RECIPROCAL': 'bg-purple-100 text-purple-800 border-purple-200',
  'IEEPA FENTANYL': 'bg-pink-100 text-pink-800 border-pink-200',
  'FENTANYL': 'bg-pink-100 text-pink-800 border-pink-200',
  'SECTION 201': 'bg-indigo-100 text-indigo-800 border-indigo-200',
  'MFN': 'bg-blue-100 text-blue-800 border-blue-200',
  'OTHER': 'bg-gray-100 text-gray-800 border-gray-200',
  'USMCA': 'bg-emerald-100 text-emerald-800 border-emerald-200',
};

function getColorForProgram(label: string): string {
  const upper = label.toUpperCase();
  for (const [key, color] of Object.entries(PROGRAM_COLORS)) {
    if (upper.includes(key)) return color;
  }
  return 'bg-gray-100 text-gray-800 border-gray-200';
}

export const TariffProgramBadge: React.FC<TariffProgramBadgeProps> = ({ label, rate, className }) => {
  return (
    <Badge
      variant="outline"
      className={cn('text-xs font-medium border whitespace-nowrap', getColorForProgram(label), className)}
    >
      {label}
      {rate != null && ` (${(rate * 100).toFixed(1)}%)`}
    </Badge>
  );
};
