#!/usr/bin/env bash
# =============================================================================
# Snapshot evidence after a test run.
#
#   ./scripts/snapshot_crdb_stats.sh <run_id>
#
# Writes to results/evidence/<run_id>/:
#   stmt_stats.csv        - per-statement counts and retry metrics
#   contention.csv        - contended indexes
#   node_health.csv       - which nodes were live
#   txn_stats.csv         - transaction-level retry counts
#   incidents.json        - raw Camunda incident list
#   incident_summary.txt  - total vs isolation-related incident counts
#
# The isolation-related incident count is the headline number for the
# SERIALIZABLE vs READ COMMITTED comparison (test L1-04 vs L1-05).
# =============================================================================
set -uo pipefail

RUN_ID=${1:?usage: snapshot_crdb_stats.sh <run_id>}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/results/evidence/${RUN_ID}"
mkdir -p "$OUT"

CSQL="cockroach sql --insecure --host=localhost:26257 --format=csv"
C8="${C8_URL:-http://localhost:8080}"
C8_AUTH="${C8_AUTH:-demo:demo}"

echo "Snapshotting evidence for run_id=${RUN_ID} -> ${OUT}"

# --- Statement-level stats, scoped to our ApplicationName tags --------------
$CSQL -e "
SELECT application_name,
       substring(key, 1, 120) AS stmt,
       count,
       (statistics->'statistics'->'maxRetries')::STRING  AS max_retries,
       (statistics->'statistics'->'numRows'->>'mean')     AS mean_rows,
       (statistics->'statistics'->'runLat'->>'mean')      AS mean_run_lat_s
FROM crdb_internal.node_statement_statistics
WHERE application_name LIKE 'camunda%'
ORDER BY count DESC
LIMIT 50;
" > "${OUT}/stmt_stats.csv" 2>&1

# --- Transaction-level retry counts -----------------------------------------
$CSQL -e "
SELECT application_name,
       (statistics->'statistics'->>'maxRetries') AS max_retries,
       (statistics->'statistics'->>'cnt')        AS txn_count
FROM crdb_internal.node_transaction_statistics
WHERE application_name LIKE 'camunda%'
ORDER BY txn_count DESC
LIMIT 50;
" > "${OUT}/txn_stats.csv" 2>&1

# --- Contention --------------------------------------------------------------
$CSQL -e "
SELECT table_name, index_name, num_contention_events, cumulative_contention_time
FROM crdb_internal.cluster_contended_indexes;
" > "${OUT}/contention.csv" 2>&1

# --- Cluster health at snapshot time ----------------------------------------
$CSQL -e "
SELECT node_id, address, is_live FROM crdb_internal.gossip_nodes ORDER BY node_id;
" > "${OUT}/node_health.csv" 2>&1

# --- Business-data end state -------------------------------------------------
$CSQL -d appdb -e "
SELECT c.pan, c.kyc_status, a.utilised_inr, a.version,
       (SELECT count(*) FROM kyc_audit k WHERE k.customer_id = c.customer_id) AS audit_rows
FROM customer c JOIN account_limit a USING (customer_id)
ORDER BY c.pan;
" > "${OUT}/business_state.csv" 2>&1

# --- Camunda incidents -------------------------------------------------------
curl -s -u "$C8_AUTH" -X POST "${C8}/v2/incidents/search" \
  -H 'Content-Type: application/json' \
  -d '{"page":{"limit":1000}}' > "${OUT}/incidents.json" 2>&1

if jq -e '.items' "${OUT}/incidents.json" >/dev/null 2>&1; then
  TOTAL=$(jq '.items | length' "${OUT}/incidents.json")
  RETRY=$(jq '[.items[]
            | select((.errorMessage // "")
            | test("40001|RETRY_SERIALIZABLE|restart transaction|SerializationFailure"; "i"))]
            | length' "${OUT}/incidents.json")
  jq -r '[.items[] | select((.errorMessage // "")
        | test("40001|RETRY_SERIALIZABLE|restart transaction|SerializationFailure"; "i"))
        | .errorMessage] | unique | .[]' \
        "${OUT}/incidents.json" > "${OUT}/incident_messages.txt" 2>/dev/null
else
  TOTAL="QUERY_FAILED"
  RETRY="QUERY_FAILED"
  echo "WARN: could not parse incidents.json - check Camunda is reachable at ${C8}"
fi

cat > "${OUT}/incident_summary.txt" <<EOF
run_id=${RUN_ID}
snapshot_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
incidents_total=${TOTAL}
incidents_isolation_related=${RETRY}
EOF

echo "---"
cat "${OUT}/incident_summary.txt"
echo "---"
echo "Artefacts written to ${OUT}"
ls -1 "${OUT}"
