-- ============================================================================
-- Camunda x CockroachDB testbed - bootstrap
--
-- Run once after the cluster is up and initialised:
--   cockroach sql --insecure --host=localhost:26257 -f crdb/01-bootstrap.sql
--
-- Creates:
--   appdb     - L1 business/application data (the workflow reads/writes this)
--   camunda8  - L2 Camunda 8 secondary storage target
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Licence. READ COMMITTED is an Enterprise feature from v24.1.
-- Uncomment and fill in before running any RC test case.
-- If RC is unavailable, STOP and escalate - it blocks the core thesis.
-- ---------------------------------------------------------------------------
-- SET CLUSTER SETTING enterprise.license = '<dev-license-key>';
-- SET CLUSTER SETTING cluster.organization = 'Cockroach Labs - Camunda POC';

-- Verify RC is available. Expect: true
SHOW CLUSTER SETTING sql.txn.read_committed_isolation.enabled;

-- ---------------------------------------------------------------------------
-- Databases and users
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS appdb;
CREATE DATABASE IF NOT EXISTS camunda8;

CREATE USER IF NOT EXISTS app_user;
CREATE USER IF NOT EXISTS camunda_user;

GRANT ALL ON DATABASE appdb    TO app_user;
GRANT ALL ON DATABASE camunda8 TO camunda_user;

-- ---------------------------------------------------------------------------
-- L1 business schema.
-- A KYC-style approval flow, deliberately shaped like the Angel One workload:
-- a read, a contended read-modify-write, and an append-only audit insert.
-- ---------------------------------------------------------------------------
USE appdb;

CREATE TABLE IF NOT EXISTS customer (
  customer_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pan           STRING(10)  NOT NULL UNIQUE,
  full_name     STRING(200) NOT NULL,
  risk_band     STRING(10)  NOT NULL DEFAULT 'UNKNOWN',
  kyc_status    STRING(20)  NOT NULL DEFAULT 'PENDING',
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The contention target. Every concurrent workflow instance in the load test
-- hits ONE row of this table on purpose.
CREATE TABLE IF NOT EXISTS account_limit (
  customer_id       UUID PRIMARY KEY REFERENCES customer(customer_id),
  daily_limit_inr   DECIMAL(15,2) NOT NULL DEFAULT 0,
  utilised_inr      DECIMAL(15,2) NOT NULL DEFAULT 0,
  version           INT NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS kyc_audit (
  audit_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id   UUID NOT NULL,
  process_id    STRING(64),
  step          STRING(64) NOT NULL,
  detail        JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  INDEX (customer_id, created_at DESC)
);

-- ---------------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------------
INSERT INTO customer (pan, full_name, risk_band) VALUES
  ('ABCDE1234F', 'Asha Rao',    'LOW'),
  ('BCDEF2345G', 'Vikram Nair', 'MEDIUM'),
  ('CDEFG3456H', 'Priya Menon', 'HIGH')
ON CONFLICT (pan) DO NOTHING;

INSERT INTO account_limit (customer_id, daily_limit_inr)
SELECT customer_id, 500000 FROM customer
ON CONFLICT (customer_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Sanity check
-- ---------------------------------------------------------------------------
SELECT c.pan, c.risk_band, c.kyc_status, a.daily_limit_inr, a.utilised_inr
FROM customer c JOIN account_limit a USING (customer_id)
ORDER BY c.pan;
