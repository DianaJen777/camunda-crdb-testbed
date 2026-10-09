-- ============================================================================
-- PostgreSQL 16 control schema.
--
-- Auto-applied by the postgres image on first start via
-- /docker-entrypoint-initdb.d. Mirrors crdb/01-bootstrap.sql exactly, with
-- CockroachDB-specific syntax translated:
--
--   STRING(n)           -> VARCHAR(n)
--   gen_random_uuid()   -> native in PG13+, no extension needed
--   INDEX (...) inline  -> separate CREATE INDEX statement
--
-- Keep this file in lockstep with crdb/01-bootstrap.sql. If the schemas drift,
-- the control comparison is invalid.
-- ============================================================================

CREATE TABLE IF NOT EXISTS customer (
  customer_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pan           VARCHAR(10)  NOT NULL UNIQUE,
  full_name     VARCHAR(200) NOT NULL,
  risk_band     VARCHAR(10)  NOT NULL DEFAULT 'UNKNOWN',
  kyc_status    VARCHAR(20)  NOT NULL DEFAULT 'PENDING',
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- The contention target. Same role as in CRDB: every concurrent workflow
-- instance in the load test hits ONE row of this table on purpose.
CREATE TABLE IF NOT EXISTS account_limit (
  customer_id       UUID PRIMARY KEY REFERENCES customer(customer_id),
  daily_limit_inr   DECIMAL(15,2) NOT NULL DEFAULT 0,
  utilised_inr      DECIMAL(15,2) NOT NULL DEFAULT 0,
  version           INT NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS kyc_audit (
  audit_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id   UUID NOT NULL,
  process_id    VARCHAR(64),
  step          VARCHAR(64) NOT NULL,
  detail        JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS kyc_audit_customer_created_idx
  ON kyc_audit (customer_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Seed data - identical to the CRDB side
-- ---------------------------------------------------------------------------
INSERT INTO customer (pan, full_name, risk_band) VALUES
  ('ABCDE1234F', 'Asha Rao',    'LOW'),
  ('BCDEF2345G', 'Vikram Nair', 'MEDIUM'),
  ('CDEFG3456H', 'Priya Menon', 'HIGH')
ON CONFLICT (pan) DO NOTHING;

INSERT INTO account_limit (customer_id, daily_limit_inr)
SELECT customer_id, 500000 FROM customer
ON CONFLICT (customer_id) DO NOTHING;
