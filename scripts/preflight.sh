#!/usr/bin/env bash
# =============================================================================
# Preflight checks. Run BEFORE anything else; abort the run if this fails.
#
#   ./scripts/preflight.sh
#
# Exit 0 = good to go. Exit 1 = fix the environment first.
# =============================================================================
set -uo pipefail

fail=0
warn=0

say()  { printf '%-34s %s\n' "$1" "$2"; }
check() {
  printf '%-34s' "$1"
  if eval "$2" >/dev/null 2>&1; then echo "OK"; else echo "FAIL"; fail=1; fi
}

echo "=============================================="
echo " Camunda x CockroachDB testbed - preflight"
echo "=============================================="
echo

# --- Java: Camunda 8 requires 21-23. JDK 24+ is NOT supported. --------------
if command -v java >/dev/null 2>&1; then
  JAVA_LINE=$(java -version 2>&1 | head -1)
  JV=$(echo "$JAVA_LINE" | sed -E 's/.*"([0-9]+).*/\1/')
  if [ "$JV" -ge 21 ] && [ "$JV" -le 23 ]; then
    say "java (21-23 required)" "OK  [$JAVA_LINE]"
  else
    say "java (21-23 required)" "FAIL [$JAVA_LINE]"
    echo "    Camunda 8 supports JDK 21-23 only. JDK 24+ will not work."
    fail=1
  fi
else
  say "java (21-23 required)" "FAIL [not installed]"
  fail=1
fi

# --- Core tooling -----------------------------------------------------------
check "docker daemon reachable"   "docker info"
check "cockroach cli"             "cockroach version"
check "python3"                   "python3 --version"
check "jq"                        "jq --version"
check "curl"                      "curl --version"
check "git"                       "git --version"

# --- Python version ---------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  PYV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  PYMINOR=$(echo "$PYV" | cut -d. -f2)
  if [ "$PYMINOR" -ge 10 ]; then
    say "python >= 3.10" "OK  [$PYV]"
  else
    say "python >= 3.10" "FAIL [$PYV]"
    fail=1
  fi
fi

# --- Docker resources: L2 needs headroom ------------------------------------
if docker info >/dev/null 2>&1; then
  CPUS=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  MEMB=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  MEMG=$(( MEMB / 1073741824 ))
  say "docker CPUs (>=8)"   "$CPUS"
  say "docker memory (>=10GiB)" "${MEMG}GiB"
  if [ "$CPUS" -lt 8 ]; then
    echo "    WARN: <8 CPU. L2 full stack may thrash. Raise in Docker Desktop > Resources."
    warn=1
  fi
  if [ "$MEMG" -lt 10 ]; then
    echo "    WARN: <10GiB. L2 full stack may OOM. Raise in Docker Desktop > Resources."
    warn=1
  fi
fi

# --- Port availability ------------------------------------------------------
for p in 26257 8081 8080 5432 26500; do
  printf '%-34s' "port $p free"
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "IN USE"
    echo "    WARN: something is already listening on $p"
    warn=1
  else
    echo "OK"
  fi
done

# --- Disk -------------------------------------------------------------------
AVAIL=$(df -g ~ | awk 'NR==2 {print $4}')
say "free disk in \$HOME (>=30GB)" "${AVAIL}GB"
[ "$AVAIL" -lt 30 ] && { echo "    WARN: low disk"; warn=1; }

echo
echo "=============================================="
if [ "$fail" -ne 0 ]; then
  echo " PREFLIGHT FAILED - fix the above before proceeding"
  exit 1
elif [ "$warn" -ne 0 ]; then
  echo " PREFLIGHT PASSED WITH WARNINGS"
  echo " Safe to start L1. Re-check resources before attempting L2."
  exit 0
else
  echo " PREFLIGHT PASSED"
  exit 0
fi
