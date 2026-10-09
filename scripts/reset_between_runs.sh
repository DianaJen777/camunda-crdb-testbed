#!/usr/bin/env bash
# =============================================================================
# Return the environment to a clean baseline between A/B runs.
#
#   ./scripts/reset_between_runs.sh [crdb|pg|both]
#
# Default: crdb
#
# Without this, the SERIALIZABLE and READ COMMITTED arms are not comparable -
# utilised_inr accumulates and kyc_audit grows, changing contention behaviour.
# =============================================================================
set -uo pipefail

TARGET=${1:-crdb}
C8="${C8_URL:-http://localhost:8080}"
C8_AUTH="${C8_AUTH:-demo:demo}"

reset_crdb() {
  echo "Resetting CockroachDB appdb..."
  cockroach sql --insecure --host=localhost:26257 -d appdb <<'SQL'
TRUNCATE kyc_audit;
UPDATE account_limit SET utilised_inr = 0, version = 1;
UPDATE customer SET kyc_status = 'PENDING', updated_at = now();
SQL
}

reset_pg() {
  echo "Resetting PostgreSQL control appdb..."
  PGPASSWORD=app_pass psql -h localhost -p 5432 -U app_user -d appdb <<'SQL'
TRUNCATE kyc_audit;
UPDATE account_limit SET utilised_inr = 0, version = 1;
UPDATE customer SET kyc_status = 'PENDING', updated_at = now();
SQL
}

case "$TARGET" in
  crdb) reset_crdb ;;
  pg)   reset_pg ;;
  both) reset_crdb; reset_pg ;;
  *)    echo "usage: reset_between_runs.sh [crdb|pg|both]"; exit 1 ;;
esac

# --- Cancel lingering ACTIVE process instances -------------------------------
echo "Cancelling active Camunda process instances..."
KEYS=$(curl -s -u "$C8_AUTH" -X POST "${C8}/v2/process-instances/search" \
  -H 'Content-Type: application/json' \
  -d '{"filter":{"state":"ACTIVE"},"page":{"limit":1000}}' \
  | jq -r '.items[]?.processInstanceKey // empty' 2>/dev/null)

n=0
for k in $KEYS; do
  curl -s -u "$C8_AUTH" -X POST \
    "${C8}/v2/process-instances/${k}/cancellation" \
    -H 'Content-Type: application/json' -d '{}' > /dev/null 2>&1
  n=$((n+1))
done

echo "Reset complete. Cancelled ${n} active instance(s)."
echo
echo "NOTE: CRDB statement statistics are NOT reset by this script."
echo "      To zero them between runs:  cockroach sql --insecure -e 'SELECT crdb_internal.reset_sql_stats();'"
echo "      Otherwise diff the snapshots instead of reading absolute counts."
