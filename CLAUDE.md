# CLAUDE.md — Camunda × CockroachDB Integration Test Harness

## Mission

Execute a local test harness on macOS that produces **evidence** for two integration
layers between Camunda 8 and CockroachDB:

- **L1 — CockroachDB as the business/application database.** A BPMN workflow reads and
  writes CRDB tables via (a) the out-of-the-box SQL Connector and (b) a custom job
  worker. Expected to work.
- **L2 — CockroachDB as Camunda 8 secondary storage.** The Orchestration Cluster's
  RDBMS exporter pointed at CRDB using the PostgreSQL dialect. **Unsupported by
  Camunda. Expected to break.**

Camunda 7 / core engine persistence is **out of scope**. Do not test it.

The deliverable is not "a working system". It is a filled-in results register, a
metrics comparison against a PostgreSQL control, and a precise gap register that
Cockroach Labs' partner team can hand to Camunda's engineering org.

---

## CRITICAL RULES — read before doing anything

1. **Never fabricate a result.** Every cell in every results table must come from a
   command you actually ran. If you did not run it, leave `NOT RUN`. If it errored,
   record the verbatim error. Inventing plausible numbers destroys the entire purpose
   of this exercise.

2. **L2 is EXPECTED to fail. Failure is a valid, valuable result.** Do not thrash
   trying to force it to work. When L2 breaks:
   - Capture the **exact** error text, SQLSTATE, stack trace and failing SQL statement
   - Add a row to `results/gaps.csv`
   - Try **at most two** documented workarounds from the gotchas table
   - Then move on and record the outcome

   A precisely documented failure beats a hacked-together success.

3. **Always 3 CRDB nodes. Never single-node.** Single-node hides the contention and
   retry behaviour that is the entire point of this test.

4. **Always run the PostgreSQL control.** Numbers without a control argue against us.
   Every L1 test case has a control counterpart.

5. **A/B the isolation level.** Every contention test runs twice: SERIALIZABLE (CRDB
   default) and READ COMMITTED. The delta is the headline finding of this project.

6. **No GUI steps.** Camunda Desktop Modeler is not available to you. Hand-write BPMN
   XML and deploy via the REST API.

7. **Stop and ask Diana** when you hit anything in the Escalate section.

8. **Commit after every phase** so progress is recoverable.

---

## What exists vs what you author

**Provided in this repo — use as-is, do not rewrite:**

```
CLAUDE.md                            this file
README.md
.gitignore
RUNLOG.md                            scaffold; you append to it
crdb/docker-compose.yml              3-node cluster
crdb/01-bootstrap.sql                schema + seed
crdb/02-isolation-rc.sql             RC toggle
crdb/03-isolation-serializable.sql   SER revert
control/docker-compose.yml           Postgres 16 control
control/01-bootstrap-pg.sql          control schema
scripts/preflight.sh                 environment checks
scripts/snapshot_crdb_stats.sh       evidence capture
scripts/reset_between_runs.sh        inter-run reset
workers/contention_driver.sh         concurrent load driver
workers/requirements.txt
results/test-register.csv            pre-seeded, all NOT RUN
results/metrics.csv                  headers only
results/gaps.csv                     headers + one example row to delete
```

**You author these during the run:**

```
workers/kyc_worker.py       Phase 4b — spec below
bpmn/kyc-connector.bpmn     Phase 4a — spec below
bpmn/kyc-worker.bpmn        Phase 4b — spec below
c8/configuration/application-crdb.yaml   Phase 5 — content below
results/SUMMARY.md          final deliverable
```

**Downloaded during the run:** `c8/` — Camunda 8.10 distribution.

If a script you need does not exist, it is listed above as provided — check the path
before writing your own. Do not duplicate.

---

## Environment

- macOS, Docker Desktop (**8 CPU / 10 GB RAM** — `preflight.sh` verifies)
- **Java 21–23 ONLY.** Camunda 8 does not support JDK 24+.
- Python 3.10+, CockroachDB CLI, jq, curl
- Target Camunda version: **8.10**. If you find 8.9 behaves materially differently for
  RDBMS secondary storage, flag it — 8.9 was the first GA release of that feature.

---

## Phase 0 — Scaffold and verify

```bash
cd ~/camunda-crdb
chmod +x scripts/*.sh workers/*.sh
mkdir -p bpmn results/evidence
./scripts/preflight.sh
```

**Gate — do not proceed unless preflight exits 0.** If Java is outside 21–23 or Docker
has insufficient resources, stop and escalate.

```bash
git add -A && git commit -m "Phase 0: scaffold verified"
```

---

## Phase 1 — CockroachDB cluster

```bash
cd crdb && docker compose up -d && cd ..
sleep 20
cockroach sql --insecure --host=localhost:26257 \
  -e "SELECT node_id, address, is_live FROM crdb_internal.gossip_nodes;"
```

**Gate: three nodes, all `is_live = true`.** If `crdb-init` exited non-zero, check its
logs — the cluster is not initialised until it succeeds.

```bash
cockroach sql --insecure --host=localhost:26257 -f crdb/01-bootstrap.sql
```

**Gate:** `SHOW CLUSTER SETTING sql.txn.read_committed_isolation.enabled` returns
`true`. If false, or if applying `02-isolation-rc.sql` fails on licensing, **STOP and
escalate** — READ COMMITTED is an Enterprise feature from v24.1 and it blocks the core
thesis of this project.

DB Console: http://localhost:8081 — keep Transaction Retries and SQL Activity open.

---

## Phase 2 — PostgreSQL control

```bash
cd control && docker compose up -d && cd ..
sleep 10
PGPASSWORD=app_pass psql -h localhost -p 5432 -U app_user -d appdb \
  -c "SELECT pan, risk_band FROM customer ORDER BY pan;"
```

Schema is applied automatically on first start. If the volume already exists from a
prior run, the init script is skipped — `docker compose down -v` to force a reset.

---

## Phase 3 — Camunda 8 for L1

Download the 8.10 Docker Compose bundle from
https://github.com/camunda/camunda-distributions/releases into `c8/`, then:

```bash
cd c8/docker-compose/versions/camunda-8.10
docker compose up -d     # lightweight profile — H2 secondary storage
```

**For L1, Camunda's internals stay on H2 deliberately.** Only business data lives in
CRDB, which keeps the variables clean.

```bash
docker network connect camunda-crdb $(docker ps -qf name=connectors)
docker network connect camunda-crdb $(docker ps -qf name=orchestration)
```

**Gate:** `curl -u demo:demo http://localhost:8080/v2/topology` returns a healthy
cluster.

---

## Phase 4 — L1 tests

### 4a. Variant A — SQL Connector (`bpmn/kyc-connector.bpmn`)

Hand-write the BPMN. The SQL Connector is applied via `zeebe:modelerTemplate` plus
`zeebe:taskDefinition` and `zeebe:ioMapping`.

**Do not guess the element template property names.** Inspect the actual template
shipped in the connectors runtime first:

```bash
docker exec $(docker ps -qf name=connectors) sh -c 'ls /opt/custom 2>/dev/null; ls /opt/connectors 2>/dev/null'
```

Or fetch from the connectors bundle repo. Record in RUNLOG which source you used.

- JDBC URL: `jdbc:postgresql://crdb-0:26257/appdb?user=app_user&sslmode=disable&ApplicationName=camunda-l1-connector`
- Database type: **PostgreSQL** (CRDB speaks pgwire)
- Process ID: `kyc-connector`

Three service tasks: SELECT customer by PAN → UPDATE `kyc_status` → INSERT into
`kyc_audit` (JSONB).

Deploy:
```bash
curl -u demo:demo -X POST http://localhost:8080/v2/deployments \
  -F "resources=@bpmn/kyc-connector.bpmn"
```

Covers **L1-01, L1-02, L1-03**.

### 4b. Variant B — custom job worker

**`workers/kyc_worker.py`** — uses `pyzeebe` + `psycopg[binary]`.

Required behaviour:

- Env vars: `CRDB_DSN` (default points at CRDB), `CRDB_ISOLATION`
  (`serializable` | `read committed`), `ZEEBE_ADDRESS` (default `localhost:26500`)
- A `run_txn()` helper wrapping every DB call in an explicit transaction with
  **SQLSTATE 40001 retry: max 5 attempts, exponential backoff with jitter**
- Set isolation per transaction: `SET TRANSACTION_ISOLATION = '<CRDB_ISOLATION>'`
- Three job handlers:
  - `crdb-fetch-customer` — SELECT by PAN, raise if not found
  - `crdb-reserve-limit` — **`SELECT ... FOR UPDATE` then `UPDATE` with an optimistic
    version check.** This is the contention test case. It MUST be a genuine
    multi-statement read-then-write or the whole A/B is meaningless.
  - `crdb-audit` — INSERT with JSONB, `RETURNING audit_id`
- Metrics: `attempts`, `retries_40001`, `failures`, latency list
- Background task writing `results/l1_metrics_<isolation>.json` every 15s with
  attempts / retries_40001 / failures / p50 / p95 / p99

The same worker must run against the Postgres control by overriding `CRDB_DSN` —
keep the SQL vendor-neutral.

**`bpmn/kyc-worker.bpmn`** — process ID **`kyc-crdb`** (the contention driver expects
this exact ID). Plain service tasks with `zeebe:taskDefinition` matching the three job
types, chained start → fetch → reserve → audit → end.

```bash
pip install -r workers/requirements.txt
```

### 4c. Test matrix

| ID | Variant | Target | Isolation | Conc. |
|---|---|---|---|---|
| L1-01/02/03 | Connector | CRDB | SER | 1 |
| **L1-04** | Worker | CRDB | **SER** | **20** |
| **L1-05** | Worker | CRDB | **RC** | **20** |
| L1-06 | Worker, retry loop on | CRDB | SER | 20 |
| L1-07 | Worker, large result | CRDB | RC | 1 |
| L1-08 | Worker + node kill | CRDB | RC | 20 |
| L1-C1 | Worker | Postgres control | RC | 20 |

**L1-04 vs L1-05 is the headline comparison.**

### 4d. A/B procedure — follow exactly

```bash
# --- SERIALIZABLE arm ---
cockroach sql --insecure -f crdb/03-isolation-serializable.sql
./scripts/reset_between_runs.sh crdb
cockroach sql --insecure -e "SELECT crdb_internal.reset_sql_stats();"
CRDB_ISOLATION=serializable python3 workers/kyc_worker.py &   # note the PID
./workers/contention_driver.sh 20 50 L1-04-ser
sleep 30                                    # let the engine drain
./scripts/snapshot_crdb_stats.sh L1-04-ser
kill %1

# --- READ COMMITTED arm ---
cockroach sql --insecure -f crdb/02-isolation-rc.sql
./scripts/reset_between_runs.sh crdb
cockroach sql --insecure -e "SELECT crdb_internal.reset_sql_stats();"
CRDB_ISOLATION="read committed" python3 workers/kyc_worker.py &
./workers/contention_driver.sh 20 50 L1-05-rc
sleep 30
./scripts/snapshot_crdb_stats.sh L1-05-rc
kill %1
```

Record both rows in `results/metrics.csv` and update `results/test-register.csv`.

### 4e. Sanity check before recording

**If L1-04 (SERIALIZABLE, concurrency 20) shows zero 40001 retries and zero
isolation-related incidents, the test is broken — not CockroachDB.** Verify:

- Is the worker actually running and picking up jobs? Check its log.
- Is `crdb-reserve-limit` doing a real multi-statement read-then-write?
- Are all instances hitting the *same* `account_limit` row?
- Did `http_codes.txt` show 2xx for the instance creations?

Fix the harness and re-run before recording anything. Then escalate the observation.

---

## Phase 5 — L2 attempt (expected to break)

Tear down the L1 stack. Create `c8/docker-compose/versions/camunda-8.10/configuration/application-crdb.yaml`
by copying `application-postgresql.yaml` and changing only the datasource:

```yaml
camunda:
  database:
    type: rdbms
  data:
    secondary-storage:
      type: rdbms

spring:
  datasource:
    url: jdbc:postgresql://crdb-0:26257/camunda8?sslmode=disable&ApplicationName=camunda-l2&reWriteBatchedInserts=true
    username: camunda_user
    password: ""
    driver-class-name: org.postgresql.Driver
    hikari:
      maximum-pool-size: 20
      connection-init-sql: "SET default_transaction_isolation = 'read committed'"
```

The pgjdbc driver is **already bundled** in the Camunda image — no driver work needed.

```bash
cd c8/docker-compose/versions/camunda-8.10
echo "ORCHESTRATION_CONFIG_FILE=application-crdb.yaml" >> .env
docker compose down -v && docker compose up -d
docker compose logs -f orchestration | tee ~/camunda-crdb/results/l2_startup.log
```

### Capture in this order

1. **Dialect detection** — grep the log for the resolved vendor/dialect. If it did not
   resolve PostgreSQL, record it and stop; everything downstream is invalid.
2. **Schema migration** — the most likely failure point. If you see
   `explicit transaction involving a schema change needs to be SERIALIZABLE`, that is
   the known DDL-under-RC issue. Workarounds: `autocommit_before_ddl = on` (in
   `02-isolation-rc.sql`), or create schema under SERIALIZABLE then switch to RC.
   Try both, record which works.
3. **Every rejected SQL statement, verbatim** — this is the core of the gap register.
4. **If it boots:** deploy `kyc-worker.bpmn`, run 50 instances, verify instances,
   variables and incidents render in Operate. Exercise search, sort and pagination —
   the exporter's weakest surfaces.
5. **Exporter throughput and backlog** under sustained load. Watch disk IO and CPU;
   the 2018 community report on CRDB described extremely heavy IO from constant
   upserts and deletes.

### Record as gaps even if L2 works

- 256-character cap on user-defined strings in RDBMS secondary storage
- Optimize still requires Elasticsearch/OpenSearch — cannot go all-RDBMS
- RDBMS not supported for dual-region (the one that matters most to CRDB's value prop)

---

## Phase 6 — Resilience demo

Under L1 with RC and sustained load running:

```bash
./workers/contention_driver.sh 20 100 L1-08-nodekill &
sleep 15
docker stop crdb-1          # kill a node mid-run
sleep 30
docker start crdb-1
wait
./scripts/snapshot_crdb_stats.sh L1-08-nodekill
```

Capture instances completed before / during / after, error count in the kill window,
and a DB Console screenshot. **This is the strongest single piece of evidence in the
project** — Camunda's supported RDBMS backends on single-node Postgres cannot do this.

Run the control equivalent (L1-C2: `docker stop pg-control`) to show the contrast.

---

## Known gotchas

| Symptom | Cause | Action |
|---|---|---|
| `explicit transaction involving a schema change needs to be SERIALIZABLE` | CRDB rejects DDL in explicit RC txns | `autocommit_before_ddl = on` — see cockroachdb/cockroach#114778 |
| SQLSTATE 40001 / `restart transaction` | SERIALIZABLE contention | Expected under SER. Count it. RC arm should eliminate it |
| RC silently behaving as SERIALIZABLE | Cluster setting false or licence missing | `SHOW CLUSTER SETTING sql.txn.read_committed_isolation.enabled` |
| Connector cannot reach `crdb-0` | Container not on `camunda-crdb` network | `docker network connect camunda-crdb <container>` |
| Anything needing `LISTEN/NOTIFY` | **CRDB does not support it** | Out of scope. Record as a hard gap; do not attempt |
| Results >16KiB stop auto-retrying | CRDB streams past the buffer | Expected. This is L1-07 |
| Slow `SELECT FOR UPDATE` under RC | Extra lookup join per locked table vs SER | Expected. Record the latency delta |
| Operate sort order differs from control | Vendor collation differences | Record as Minor gap |
| `crdb-init` keeps restarting | Nodes not reachable yet | Normal for ~10s; persistent means a network issue |

---

## Escalate to Diana — stop and ask

- **READ COMMITTED unavailable** (licence or cluster setting) — blocks the core thesis
- Camunda 8.9 vs 8.10 behaving materially differently for RDBMS secondary storage
- L2 failing where the only workaround requires patching Camunda source
- **Any result that looks too good** — e.g. zero 40001s under SERIALIZABLE at
  concurrency 20. Almost certainly a broken test. Verify per 4e before recording
- Hardware limits (OOM, thrashing) preventing the L2 stack from running

**Do not silently reduce scope to make something pass.** Record the constraint instead.

---

## Final deliverable — `results/SUMMARY.md`

1. One-paragraph verdict per layer with RAG status
2. **The L1-04 vs L1-05 headline number** — incidents and 40001s, SER vs RC
3. CRDB vs PostgreSQL control comparison
4. Gap register summary — count by severity, blockers listed explicitly
5. Resilience demo outcome
6. Everything NOT RUN, and why

Keep it factual. No recommendations, no spin — Diana writes the commercial framing.

---

## Reference

- Camunda RDBMS support policy: https://docs.camunda.io/docs/self-managed/concepts/databases/relational-db/rdbms-support-policy/
- Camunda SQL connector: https://docs.camunda.io/docs/components/connectors/out-of-the-box-connectors/sql/
- Camunda distributions: https://github.com/camunda/camunda-distributions/releases
- Orchestration Cluster REST API: https://docs.camunda.io/docs/apis-tools/orchestration-cluster-api-rest/orchestration-cluster-api-rest-overview/
- CRDB Read Committed: https://www.cockroachlabs.com/docs/stable/read-committed
- CRDB transactions and retries: https://www.cockroachlabs.com/docs/stable/transactions
- DDL in RC transactions: https://github.com/cockroachdb/cockroach/issues/114778
- Camunda 7.14 release blog (the original READ COMMITTED statement): https://camunda.com/blog/2020/10/camunda-bpm-runtime-7-14-0-released/
