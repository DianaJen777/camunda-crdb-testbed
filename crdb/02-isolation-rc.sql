-- ============================================================================
-- READ COMMITTED toggle
--
-- Apply ONLY for the RC arm of each A/B test:
--   cockroach sql --insecure --host=localhost:26257 -f crdb/02-isolation-rc.sql
--
-- Revert to SERIALIZABLE with crdb/03-isolation-serializable.sql
--
-- WHY THIS MATTERS
-- Camunda's engine was written against PostgreSQL READ COMMITTED semantics.
-- Under CRDB's default SERIALIZABLE, contended read-modify-write patterns
-- surface SQLSTATE 40001 to the application. The delta between these two
-- arms (test L1-04 vs L1-05) is the headline finding of this project.
-- ============================================================================

ALTER ROLE app_user     SET default_transaction_isolation = 'read committed';
ALTER ROLE camunda_user SET default_transaction_isolation = 'read committed';

-- CockroachDB rejects DDL inside explicit READ COMMITTED transactions:
--   "explicit transaction involving a schema change needs to be SERIALIZABLE"
-- Liquibase/Flyway wrap DDL in transactions, so Camunda's L2 schema creation
-- will hit this. See https://github.com/cockroachdb/cockroach/issues/114778
ALTER ROLE camunda_user SET autocommit_before_ddl = on;

-- Stop a wedged exporter transaction from pinning ranges indefinitely.
ALTER ROLE camunda_user SET statement_timeout = '30s';

-- Verify
SELECT rolname, rolconfig FROM pg_roles
WHERE rolname IN ('app_user', 'camunda_user');
