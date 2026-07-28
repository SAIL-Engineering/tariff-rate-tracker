#!/usr/bin/env bash
# =============================================================================
# refresh_ca.sh — rebuild and publish the Canadian retrieval corpus.
#
# Drop the new CBSA export into data/ca_tariff_source/ and run this. Everything
# else — build, upload, verify, point Supabase — happens here.
#
#   scripts/hts_automation/refresh_ca.sh --effective-date 2026-08-01
#
# There is no cron equivalent for Canada. hts-revision-update.yml detects new US
# revisions by scraping USITC; CBSA publishes the tariff as PDF/HTML only, with
# no feed and no machine-readable endpoint, so a human has to notice a new
# edition and drop the file. That is the ONLY manual part — this script does the
# rest and refuses to publish anything it has not verified.
#
# Usage:
#   refresh_ca.sh                                  # newest CSV, revision from filename
#   refresh_ca.sh --csv path/to/file.csv
#   refresh_ca.sh --revision 2026_rev_2 --effective-date 2026-08-01
#   refresh_ca.sh --dry-run                        # build + report, no writes
#
# Exit codes: 0 ok · 1 config/args · 2 build · 3 upload/verify · 4 Supabase
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
cd "$REPO_ROOT"

SOURCE_DIR="data/ca_tariff_source"
ENV_FILE="$HERE/.env.hts_automation"

CSV_PATH=""
REVISION=""
EFFECTIVE_DATE=""
EFFECTIVE_LABEL=""
DRY_RUN="false"
KEEP=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)             CSV_PATH="$2"; shift 2 ;;
    --revision)        REVISION="$2"; shift 2 ;;
    --effective-date)  EFFECTIVE_DATE="$2"; shift 2 ;;
    --effective-label) EFFECTIVE_LABEL="$2"; shift 2 ;;
    --keep)            KEEP="$2"; shift 2 ;;
    --dry-run)         DRY_RUN="true"; shift ;;
    -h|--help)         sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

# ─── Config ──────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found (copy .env.hts_automation.example)" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
for v in PINECONE_API_KEY SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY; do
  [[ -n "${!v-}" ]] || { echo "ERROR: $v is not set in $ENV_FILE" >&2; exit 1; }
done

# ─── Locate the source ───────────────────────────────────────────────
if [[ -z "$CSV_PATH" ]]; then
  # Newest by mtime, so dropping a file in is all that is required.
  CSV_PATH="$(ls -t "$SOURCE_DIR"/ca_tariff_*.csv 2>/dev/null | head -1 || true)"
fi
[[ -n "$CSV_PATH" && -f "$CSV_PATH" ]] || {
  echo "ERROR: no CBSA export found." >&2
  echo "       Drop it in $SOURCE_DIR/ named ca_tariff_<year>_rev_<n>.csv" >&2
  echo "       (or pass --csv). See $SOURCE_DIR/README.md." >&2
  exit 1
}

# Revision from the filename unless overridden: ca_tariff_2026_rev_2.csv -> 2026_rev_2
if [[ -z "$REVISION" ]]; then
  REVISION="$(basename "$CSV_PATH" .csv | sed -E 's/^ca_tariff_//')"
fi
[[ "$REVISION" =~ ^([0-9]{4})_rev_([0-9]+)$ ]] || {
  echo "ERROR: could not derive a revision from '$CSV_PATH'." >&2
  echo "       Expected ca_tariff_<year>_rev_<n>.csv, or pass --revision 2026_rev_2." >&2
  exit 1
}
YEAR="${BASH_REMATCH[1]}"; REV_NUM="${BASH_REMATCH[2]}"
NAMESPACE="ca__${REVISION}"

log "source     $CSV_PATH"
log "revision   $REVISION  (year $YEAR, rev $REV_NUM)"
log "namespace  $NAMESPACE"

# ─── Build ───────────────────────────────────────────────────────────
log "1/4 build corpus"
OUT_STEM="$(mktemp -d)/ca_${REVISION}"
python3 "$HERE/build_hts_corpus.py" \
  "$CSV_PATH" "$HERE/chapters_ca.json" "$OUT_STEM" \
  --jurisdiction CA --revision "$REVISION" --max-depth 10 --source-format cbsa \
  || { echo "ERROR: corpus build failed" >&2; exit 2; }

RECORDS="$(python3 -c "import json;print(json.load(open('${OUT_STEM}.manifest.json'))['record_count'])")"

if [[ "$DRY_RUN" == "true" ]]; then
  log "dry-run — built $RECORDS records, stopping before any write"
  python3 -c "import json;print(json.dumps(json.load(open('${OUT_STEM}.manifest.json')), indent=2))"
  exit 0
fi

# ─── Upload + verify ─────────────────────────────────────────────────
# swap = upsert, poll until the count matches, run the golden queries, and only
# then prune older CA namespaces. It exits non-zero if the corpus does not
# answer correctly, so nothing below runs against a bad upload.
log "2/4 upload to Pinecone + verify"
python3 "$HERE/pinecone_sync.py" swap \
  --jsonl "${OUT_STEM}.jsonl" --namespace "$NAMESPACE" --keep "$KEEP" \
  || { echo "ERROR: Pinecone upload/verify failed — Supabase NOT touched" >&2; exit 3; }

# ─── Point Supabase at it ────────────────────────────────────────────
# Only reached once the namespace verified. --promote-country-pointer also
# advances the last-known-good fallback, which is what a rollback drops to if
# the revision row is later NULLed.
log "3/4 point Supabase at $NAMESPACE"
EFFECTIVE_DATE="${EFFECTIVE_DATE:-$(date +%Y-01-01)}"
EFFECTIVE_LABEL="${EFFECTIVE_LABEL:-$(date -d "$EFFECTIVE_DATE" '+%B %-d, %Y' 2>/dev/null || echo "$EFFECTIVE_DATE")}"
python3 "$HERE/supabase_insert_revision.py" \
  --country CA \
  --year "$YEAR" \
  --rev-num "$REV_NUM" \
  --effective-date "$EFFECTIVE_DATE" \
  --effective-date-label "$EFFECTIVE_LABEL" \
  --tariff-schedule-name "Canadian Customs Tariff" \
  --ragie-partition-id "canada_tariff_${YEAR}" \
  --pinecone-namespace "$NAMESPACE" \
  --promote-country-pointer \
  || { echo "ERROR: Supabase write failed. The namespace is live but unpointed;" >&2
       echo "       re-run this script, or set hts_revisions.pinecone_namespace by hand." >&2
       exit 4; }

# ─── Confirm what the server will now resolve ────────────────────────
log "4/4 confirm"
python3 - "$NAMESPACE" <<'PY'
import json, os, sys, urllib.request
ns = sys.argv[1]
base = os.environ["SUPABASE_URL"].rstrip("/")
key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
h = {"apikey": key, "authorization": f"Bearer {key}"}
def get(path):
    return json.load(urllib.request.urlopen(
        urllib.request.Request(f"{base}/rest/v1/{path}", headers=h), timeout=30))
today = __import__("datetime").date.today().isoformat()
# Mirrors services/countryConfig.ts: greatest effective_date <= today, then
# revision-first namespace with the country row as fallback.
revs = get(f"hts_revisions?select=revision_year,revision_number,effective_date,pinecone_namespace"
           f"&country_code=eq.CA&effective_date=lte.{today}"
           f"&order=effective_date.desc&limit=1")
ctry = get("supported_countries?select=pinecone_namespace&country_code=eq.CA")
active = (revs[0].get("pinecone_namespace") if revs else None) or (ctry[0].get("pinecone_namespace") if ctry else None)
print(f"  active CA revision : {revs[0]['revision_year']}_rev_{revs[0]['revision_number']} "
      f"(effective {revs[0]['effective_date']})" if revs else "  no active revision!")
print(f"  resolves to        : {active}")
if active != ns:
    print(f"  NOTE: the server will use {active}, not {ns}. That is correct if {ns} is "
          f"future-dated — it takes effect on its effective_date with no deploy.")
PY

log "DONE — CA corpus $REVISION published ($RECORDS records)"
