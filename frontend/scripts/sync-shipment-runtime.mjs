// Generate the tracker runtime from SAIL's one shared TypeScript interpreter.
// Usage: node scripts/sync-shipment-runtime.mjs /path/to/SAIL/server/src/shared/duty/shipmentRules.ts
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';

const input = process.argv[2];
if (!input) throw new Error('Provide the SAIL shared shipmentRules.ts path');
const moduleName = path.basename(input, '.ts');
if (!['shipmentRules', 'shipmentWide'].includes(moduleName)) throw new Error('Unsupported shared shipment module');
const source = fs.readFileSync(input, 'utf8');
const hash = crypto.createHash('sha256').update(source).digest('hex');
const { outputText, diagnostics } = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022, strict: true },
  reportDiagnostics: true,
});
if (diagnostics?.length) throw new Error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
  getCurrentDirectory: () => process.cwd(), getCanonicalFileName: p => p, getNewLine: () => '\n',
}));
const output = path.resolve(path.dirname(fileURLToPath(import.meta.url)), `../server/generated/${moduleName}.js`);
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, `// Generated from SAIL server/src/shared/duty/${moduleName}.ts. Do not edit.\n// Source SHA256: ${hash}\n${outputText}`);
if (moduleName === 'shipmentWide') fs.writeFileSync(path.resolve(path.dirname(output), '../../src/types/shipment-wide.ts'),
  `// Generated from SAIL shared shipmentWide.ts. Do not edit.\n// Source SHA256: ${hash}\n${source}`);
console.log(`shipment runtime ${hash}`);
