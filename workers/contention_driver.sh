#!/usr/bin/env bash
# =============================================================================
# Contention driver.
#
#   ./workers/contention_driver.sh <concurrency> <iterations> [run_id]
#
# Fires N concurrent process instances that ALL target the SAME account_limit
# row (PAN ABCDE1234F). This is deliberate: the read-modify-write in the
# crdb-reserve-limit job is the test case that provokes SQLSTATE 40001 under
# SERIALIZABLE isolation.
#
# If this produces zero retries under SERIALIZABLE at concurrency 20, the test
# is broken - not CockroachDB. Verify the worker is actually doing a
# multi-statement SELECT ... FOR UPDATE then UPDATE before recording a result.
#
# Example A/B:
#   cockroach sql --insecure -f crdb/03-isolation-serializable.sql
#   ./workers/contention_driver.sh 20 50 L1-04-ser
#   ./scripts/snapshot_crdb_stats.sh L1-04-ser
#   ./scripts/reset_between_runs.sh
#   cockroach sql --insecure -f crdb/02-isolation-rc.sql
#   ./workers/contention_driver.sh 20 50 L1-05-rc
#   ./scripts/snapshot_crdb_stats.sh L1-05-rc
# =============================================================================
set -uo pipefail

CONC=${1:-20}
ITER=${2:-50}
RUN_ID=${3:-$(date +%Y%m%d-%H%M%S)}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/results/evidence/${RUN_ID}"
mkdir -p "$OUT"
: > "${OUT}/http_codes.txt"

C8="${C8_URL:-http://localhost:8080}"
C8_AUTH="${C8_AUTH:-demo:demo}"
PROC_ID="${PROC_ID:-kyc-crdb}"
PAN="${PAN:-ABCDE1234F}"
AMOUNT="${AMOUNT:-100}"

{
  echo "run_id=${RUN_ID}"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "concurrency=${CONC}"
  echo "iterations=${ITER}"
  echo "process_definition_id=${PROC_ID}"
  echo "contended_pan=${PAN}"
} | tee "${OUT}/driver.log"

start=$(date +%s)

for i in $(seq 1 "$ITER"); do
  for c in $(seq 1 "$CONC"); do
    (
      code=$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST "${C8}/v2/process-instances" \
        -H 'Content-Type: application/json' \
        -u "$C8_AUTH" \
        -d "{\"processDefinitionId\":\"${PROC_ID}\",
             \"variables\":{\"pan\":\"${PAN}\",\"amount\":${AMOUNT}}}")
      echo "$code" >> "${OUT}/http_codes.txt"
    ) &
  done
  wait
done

elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -eq 0 ] && elapsed=1

total=$(( CONC * ITER ))
ok=$(grep -c '^2' "${OUT}/http_codes.txt" 2>/dev/null || echo 0)
bad=$(grep -vc '^2' "${OUT}/http_codes.txt" 2>/dev/null || echo 0)

{
  echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "elapsed_sec=${elapsed}"
  echo "instances_requested=${total}"
  echo "http_2xx=${ok}"
  echo "http_non2xx=${bad}"
  echo "request_throughput_per_sec=$(awk "BEGIN{printf \"%.2f\", ${ok}/${elapsed}}")"
} | tee -a "${OUT}/driver.log"

echo
echo "HTTP code distribution:"
sort "${OUT}/http_codes.txt" | uniq -c | sort -rn | tee -a "${OUT}/driver.log"

echo
echo "NOTE: request throughput != completion throughput. Wait for the engine to"
echo "      drain, then read completed-instance counts from the snapshot script."
echo "Next: ./scripts/snapshot_crdb_stats.sh ${RUN_ID}"
