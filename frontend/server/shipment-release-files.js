import {createReadStream} from 'node:fs';
import crypto from 'node:crypto';

// Wide production partitions can exceed V8's buffer budget. Never materialize a
// Parquet solely to compute its content pin; JSON bundles are read separately.
export async function shipmentFileHash(filename) {
 const digest=crypto.createHash('sha256');
 for await(const chunk of createReadStream(filename))digest.update(chunk);
 return digest.digest('hex');
}
