-- Additive v8 release-schema template. Substitute only the quoted, validated
-- immutable schema identifier. No active pointer or existing release is changed.
CREATE TABLE __RELEASE_SCHEMA__.release_metadata (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), preparation_mode VARCHAR NOT NULL,
 manifest_sha256 VARCHAR NOT NULL, dataset_version VARCHAR NOT NULL,
 evidence_snapshot_id VARCHAR NOT NULL, verification_json VARCHAR NOT NULL
);
CREATE TABLE __RELEASE_SCHEMA__.rule_bundle_indexes (
 revision VARCHAR PRIMARY KEY, index_sha256 VARCHAR NOT NULL, index_json VARCHAR NOT NULL
);
CREATE TABLE __RELEASE_SCHEMA__.rule_bundles (
 bundle_id VARCHAR PRIMARY KEY,revision VARCHAR NOT NULL,valid_from TIMESTAMPTZ NOT NULL,
 valid_until TIMESTAMPTZ NOT NULL,bundle_sha256 VARCHAR NOT NULL,bundle_json VARCHAR NOT NULL,
 CHECK(valid_from<valid_until)
);
CREATE TABLE __RELEASE_SCHEMA__.rule_sources (
 bundle_id VARCHAR,source_id VARCHAR,source_json VARCHAR NOT NULL,PRIMARY KEY(bundle_id,source_id)
);
CREATE TABLE __RELEASE_SCHEMA__.executable_rules (
 bundle_id VARCHAR,rule_id VARCHAR,action_id VARCHAR NOT NULL,authority VARCHAR NOT NULL,
 rule_json VARCHAR NOT NULL,PRIMARY KEY(bundle_id,rule_id)
);
CREATE TABLE __RELEASE_SCHEMA__.rule_coverage (
 bundle_id VARCHAR,position INTEGER,authority VARCHAR NOT NULL,coverage_json VARCHAR NOT NULL,
 PRIMARY KEY(bundle_id,position)
);
CREATE TABLE __RELEASE_SCHEMA__.executable_claims (
 bundle_id VARCHAR,claim_id VARCHAR,claim_json VARCHAR NOT NULL,PRIMARY KEY(bundle_id,claim_id)
);
