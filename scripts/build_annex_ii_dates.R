#!/usr/bin/env Rscript
# The former HTS8 expansion/first-appearance stamper broadened exemptions and
# assigned unlimited windows to untraceable rows. It is intentionally retired.
stop('Legacy reciprocal exemption regeneration retired. The normal build now extracts original-annex scopes and legal windows via src/ieepa_reciprocal_sources.py. For a source-only audit, run python3 scripts/audit_reciprocal_scope.py --out output/reciprocal-scope-audit. No timeseries rebuild is run by that command.',call.=FALSE)
