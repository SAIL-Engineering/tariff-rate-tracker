/** Evidence integrity check, not an automated legal-verification decision. */
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
export async function verifyAuditEvidence(specification, repositoryRoot) {
  const root = await fs.realpath(repositoryRoot);
  const verified = new Set();
  const ids = new Set();
  for (const source of specification.sources ?? []) {
    if (typeof source.id !== 'string' || ids.has(source.id)) throw new Error('Missing or duplicate audit source ID');
    ids.add(source.id);
    if (source.verification !== 'primary_source_verified') continue;
    if (typeof source.path !== 'string' || !/^[a-f0-9]{64}$/.test(source.sha256 ?? '')
      || !/^https:\/\//.test(source.url ?? '') || !source.locator)
      throw new Error(`Audit source lacks reproducible evidence: ${source.id}`);
    const file = await fs.realpath(path.resolve(root, source.path));
    if (!file.startsWith(root + path.sep)) throw new Error('Audit evidence escapes repository');
    const hash = crypto.createHash('sha256').update(await fs.readFile(file)).digest('hex');
    if (hash !== source.sha256) throw new Error(`Audit evidence hash mismatch: ${source.id}`);
    verified.add(source.id);
  }
  for (const item of specification.cases ?? []) for (const check of item.expectations ?? []) {
    if (check.verification === 'primary_source_verified' && (!check.source_ids?.length
      || check.source_ids.some(id => !verified.has(id))))
      throw new Error(`Verified expectation has no verified evidence: ${item.id}`);
  }
  return verified;
}
