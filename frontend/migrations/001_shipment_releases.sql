-- Additive release registry. Apply only with explicit deployment approval.
CREATE TABLE IF NOT EXISTS main.tariff_releases (
  release_id VARCHAR PRIMARY KEY, schema_name VARCHAR UNIQUE NOT NULL,
  contract_version VARCHAR NOT NULL, dataset_version VARCHAR UNIQUE NOT NULL,
  evidence_snapshot_id VARCHAR NOT NULL, manifest_sha256 VARCHAR NOT NULL,
  status VARCHAR NOT NULL, prepared_at TIMESTAMPTZ DEFAULT current_timestamp
);
CREATE TABLE IF NOT EXISTS main.tariff_active_release (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1), release_id VARCHAR NOT NULL,
  previous_release_id VARCHAR, activated_at TIMESTAMPTZ
);
