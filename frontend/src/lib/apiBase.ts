// API base URL for the backend. Parameterized via VITE_TARIFF_API_BASE so
// this frontend can be pointed at either the local dev server (default) or
// the Railway deployment when embedded as a module in sail-gtx-prerelease.
//
// When unset (no env var), falls back to empty string = same-origin, which
// is what the prototype uses today with vite's dev-proxy setup.
export const API_BASE: string = import.meta.env.VITE_TARIFF_API_BASE ?? '';

export function apiUrl(pathname: string): string {
  if (!pathname.startsWith('/')) pathname = '/' + pathname;
  return `${API_BASE}${pathname}`;
}
