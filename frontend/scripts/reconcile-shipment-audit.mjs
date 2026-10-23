// Offline reconciliation of an immutable, previously captured read-only audit.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {parseArgs} from 'node:util';
import {fileURLToPath} from 'node:url';
import {compareAuditCases, AUDIT_CONTRACT} from '../server/shipment-audit.js';
import {verifyAuditEvidence} from '../server/shipment-audit-evidence.js';
const {values:args}=parseArgs({options:{snapshot:{type:'string'},cases:{type:'string'},out:{type:'string'}}});
if (!args.snapshot || !args.out) throw new Error('Required: --snapshot DIRECTORY --out NEW_FILE [--cases FILE]');
const repository=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const root=await fs.realpath(args.snapshot);
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const manifestBytes=await fs.readFile(path.join(root,'manifest.json'));
const manifest=JSON.parse(manifestBytes);
if (manifest.contract_version!==AUDIT_CONTRACT || manifest.access_mode!=='READ_ONLY') throw new Error('Unsupported audit snapshot');
for (const artifact of manifest.artifacts) {
  const file=await fs.realpath(path.resolve(root,artifact.path));
  if (!file.startsWith(root+path.sep)) throw new Error('Snapshot artifact escapes directory');
  if (hash(await fs.readFile(file))!==artifact.sha256) throw new Error(`Snapshot hash mismatch: ${artifact.path}`);
}
const casesPath=args.cases ?? path.join(repository,'resources/shipment_audit/cases.json');
const casesBytes=await fs.readFile(casesPath);const specification=JSON.parse(casesBytes);
const sources=await verifyAuditEvidence(specification,repository);
const rows=JSON.parse(await fs.readFile(path.join(root,'cases.json'),'utf8')).rows;
const report={contract_version:'sail.shipment-audit-reconciliation/v1',
  source_manifest_sha256:hash(manifestBytes),source_case_sha256:hash(casesBytes),
  source_database:manifest.database,source_retrieved_at:manifest.finished_at,
  reconciled_at:new Date().toISOString(),findings:compareAuditCases(specification.cases,rows,sources)};
await fs.writeFile(args.out,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({cases:report.findings.length,legal_stack_status:'not_certified_by_component_checks'}));
