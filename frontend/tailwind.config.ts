import type { Config } from 'tailwindcss';
import tailwindcssAnimate from 'tailwindcss-animate';
import typography from '@tailwindcss/typography';

export default {
  darkMode: ['class'],
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  prefix: '',
  theme: {
    container: {
      center: true,
      padding: '2rem',
      screens: { '2xl': '1400px' },
    },
    extend: {
      fontFamily: {
        sans: ['Geist', 'Inter', 'system-ui', 'sans-serif'],
        display: ['Geist', 'SF Pro Display', 'system-ui', 'sans-serif'],
        geist: ['Geist', 'system-ui', 'sans-serif'],
      },
      colors: {
        border: 'hsl(var(--border))',
        input: 'hsl(var(--input))',
        ring: 'hsl(var(--ring))',
        background: 'hsl(var(--background))',
        foreground: 'hsl(var(--foreground))',
        primary: { DEFAULT: '#353CED', foreground: '#FFFFFF' },
        accent: { DEFAULT: '#D7FD48', foreground: '#353CED' },
        beige: {
          DEFAULT: '#FAFAF8',
          50: '#FAFAF8',
          100: '#F9F8F6',
          200: '#F8F6F3',
          300: '#F7F3EA',
        },
        success: '#22C55E',
        warning: '#F59E0B',
        error: '#EF4444',
        info: '#3B82F6',
        secondary: {
          DEFAULT: 'hsl(var(--secondary))',
          foreground: 'hsl(var(--secondary-foreground))',
        },
        destructive: {
          DEFAULT: 'hsl(var(--destructive))',
          foreground: 'hsl(var(--destructive-foreground))',
        },
        muted: {
          DEFAULT: 'hsl(var(--muted))',
          foreground: 'hsl(var(--muted-foreground))',
        },
        popover: {
          DEFAULT: 'hsl(var(--popover))',
          foreground: 'hsl(var(--popover-foreground))',
        },
        card: {
          DEFAULT: 'hsl(var(--card))',
          foreground: 'hsl(var(--card-foreground))',
        },
      },
      borderRadius: {
        lg: 'var(--radius)',
        md: 'calc(var(--radius) - 2px)',
        sm: 'calc(var(--radius) - 4px)',
      },
      boxShadow: {
        'neu': '2px 2px 4px rgba(0,0,0,0.06), -2px -2px 4px rgba(255,255,255,0.8)',
        'neu-sm': '1px 1px 2px rgba(0,0,0,0.05), -1px -1px 2px rgba(255,255,255,0.8)',
        'neu-md': '4px 4px 8px rgba(0,0,0,0.07), -4px -4px 8px rgba(255,255,255,0.9)',
        'neu-inset': 'inset 2px 2px 5px rgba(0,0,0,0.06), inset -2px -2px 5px rgba(255,255,255,0.85)',
        'neu-hover': '6px 6px 12px rgba(0,0,0,0.08), -6px -6px 12px rgba(255,255,255,0.95)',
        'glass': '0 1px 2px rgba(0,0,0,0.04), 0 4px 16px rgba(0,0,0,0.04)',
        'glass-lg': '0 2px 4px rgba(0,0,0,0.03), 0 8px 32px rgba(0,0,0,0.06)',
        'elevated': '0 1px 3px rgba(0,0,0,0.04), 0 6px 24px rgba(0,0,0,0.06)',
        'pop': '0 4px 6px -1px rgba(53,60,237,0.08), 0 2px 4px -2px rgba(53,60,237,0.04)',
      },
      keyframes: {
        'accordion-down': { from: { height: '0' }, to: { height: 'var(--radix-accordion-content-height)' } },
        'accordion-up': { from: { height: 'var(--radix-accordion-content-height)' }, to: { height: '0' } },
        'fade-in': {
          '0%': { opacity: '0', transform: 'translateY(8px) scale(0.98)' },
          '100%': { opacity: '1', transform: 'translateY(0) scale(1)' },
        },
        'fade-in-down': {
          '0%': { opacity: '0', transform: 'translateY(-4px) scale(0.99)' },
          '100%': { opacity: '1', transform: 'translateY(0) scale(1)' },
        },
        'scale-in': {
          '0%': { opacity: '0', transform: 'scale(0.96)' },
          '100%': { opacity: '1', transform: 'scale(1)' },
        },
        'slide-up': {
          '0%': { opacity: '0', transform: 'translateY(12px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        },
        'shimmer': {
          '0%': { backgroundPosition: '-200% 0' },
          '100%': { backgroundPosition: '200% 0' },
        },
      },
      animation: {
        'accordion-down': 'accordion-down 0.2s cubic-bezier(0.32,0.72,0,1)',
        'accordion-up': 'accordion-up 0.2s cubic-bezier(0.32,0.72,0,1)',
        'fade-in': 'fade-in 0.35s cubic-bezier(0.32,0.72,0,1) forwards',
        'fade-in-down': 'fade-in-down 0.2s cubic-bezier(0.32,0.72,0,1) forwards',
        'scale-in': 'scale-in 0.2s cubic-bezier(0.32,0.72,0,1) forwards',
        'slide-up': 'slide-up 0.4s cubic-bezier(0.32,0.72,0,1) forwards',
        'shimmer': 'shimmer 2s ease-in-out infinite',
      },
      transitionTimingFunction: {
        'spring': 'cubic-bezier(0.32,0.72,0,1)',
        'smooth': 'cubic-bezier(0.4,0,0.2,1)',
        'bounce': 'cubic-bezier(0.34,1.56,0.64,1)',
      },
    },
  },
  plugins: [tailwindcssAnimate, typography],
} satisfies Config;
