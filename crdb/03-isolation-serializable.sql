-- ============================================================================
-- Revert to SERIALIZABLE (CockroachDB default)
--
-- Apply before the SERIALIZABLE arm of each A/B test:
--   cockroach sql --insecure --host=localhost:26257 -f crdb/03-isolation-serializable.sql
-- ============================================================================

ALTER ROLE app_user     RESET default_transaction_isolation;
ALTER ROLE camunda_user RESET default_transaction_isolation;
ALTER ROLE camunda_user RESET autocommit_before_ddl;

-- Verify: rolconfig should no longer contain default_transaction_isolation
SELECT rolname, rolconfig FROM pg_roles
WHERE rolname IN ('app_user', 'camunda_user');
