# camunda-crdb-testbed

Local test harness for validating **Camunda 8 against CockroachDB** on macOS.

Produces evidence for the Cockroach Labs ISV Technology Partner Program — specifically
a filled-in results register, a metrics comparison against a PostgreSQL control, and a
precise gap register that can be handed to Camunda's engineering org.

## Scope

| Layer | What it tests | Expected |
|---|---|---|
| **L1** | CockroachDB as the **business/application database** behind a BPMN workflow, via the out-of-the-box SQL Connector and a custom job worker | 🟢 Should work |
| **L2** | CockroachDB as **Camunda 8 secondary storage** (RDBMS exporter, PostgreSQL dialect) | 🔴 Unsupported by Camunda — expected to break |

**Out of scope:** Camunda 7 / core engine persistence. Do not test it.

## The question this answers

Camunda's process engine was written against PostgreSQL **READ COMMITTED** semantics.
CockroachDB defaults to **SERIALIZABLE**, which surfaces SQLSTATE 40001 retry errors.
That mismatch lost CRL the Fidelity POC in 2023.

CockroachDB has supported READ COMMITTED since v23.2 (Enterprise from v24.1), and
CRDB's RC is *stronger* than PostgreSQL's — it prevents anomalies within single
statements. The headline experiment here is the **SERIALIZABLE vs READ COMMITTED A/B
under deliberate contention** (test cases L1-04 vs L1-05).

## Quickstart

```bash
git clone https://github.com/DianaJen777/camunda-crdb-testbed.git ~/camunda-crdb
cd ~/camunda-crdb
chmod +x scripts/*.sh workers/*.sh
./scripts/preflight.sh      # aborts if Java/Docker/CRDB prerequisites are wrong
claude                       # Claude Code reads CLAUDE.md and runs the plan
```

## What's in the repo vs what gets generated

Already here:

- `CLAUDE.md` — the full execution plan and guardrails
- `crdb/` — 3-node CockroachDB compose file + bootstrap SQL + RC toggle
- `control/` — PostgreSQL 16 control instance (required for every L1 comparison)
- `scripts/` — preflight, evidence snapshot, inter-run reset
- `workers/contention_driver.sh` — concurrent load driver
- `results/*.csv` — headers only, to be filled in during execution

Authored by Claude Code during the run:

- `workers/kyc_worker.py` — job worker with SQLSTATE 40001 retry handling
- `bpmn/kyc-connector.bpmn` — L1 Variant A (SQL Connector)
- `bpmn/kyc-worker.bpmn` — L1 Variant B (job worker)
- `RUNLOG.md` — append-only audit trail
- `results/` — all populated rows and evidence artefacts

Downloaded during the run:

- `c8/` — Camunda 8.10 distribution from
  [camunda-distributions releases](https://github.com/camunda/camunda-distributions/releases)

## Ground rules

1. **Never fabricate a result.** `NOT RUN` is an allowed status; invented numbers are not.
2. **L2 is expected to fail.** A precisely documented failure is the deliverable, not a bug.
3. **Always 3 CRDB nodes.** Single-node hides the contention this test exists to measure.
4. **Always run the PostgreSQL control.** Numbers without a baseline argue against us.
5. **A/B every contention test** across SERIALIZABLE and READ COMMITTED.

Full detail in [CLAUDE.md](./CLAUDE.md).

## Reference

- [Camunda RDBMS support policy](https://docs.camunda.io/docs/self-managed/concepts/databases/relational-db/rdbms-support-policy/) — authoritative supported-database list (CRDB is absent)
- [Camunda SQL connector](https://docs.camunda.io/docs/components/connectors/out-of-the-box-connectors/sql/)
- [CockroachDB Read Committed](https://www.cockroachlabs.com/docs/stable/read-committed)
- [CockroachDB transactions & retries](https://www.cockroachlabs.com/docs/stable/transactions)
- [cockroachdb/cockroach#114778](https://github.com/cockroachdb/cockroach/issues/114778) — DDL in RC transactions
- [Camunda 7.14 release blog](https://camunda.com/blog/2020/10/camunda-bpm-runtime-7-14-0-released/) — the original READ COMMITTED statement
- CRL Jira: [CRDB-19005](https://cockroachlabs.atlassian.net/browse/CRDB-19005)

---

Maintainer: Diana Annie Jenosh (Partner Solutions Architecture) · Prepared with Mica
