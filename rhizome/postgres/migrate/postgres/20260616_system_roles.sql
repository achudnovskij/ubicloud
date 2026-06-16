-- System roles used across the cluster: replication (standbys), monitoring
-- (postgres_exporter), and pgbouncer (auth). Runs in the postgres database, which is
-- always migrated before ubi_admin, so these roles exist before the ubi_admin
-- pgbouncer migration grants to them. Idempotent (DO / IF NOT EXISTS) so it is safe on
-- a server that predates migration tracking and already has the roles.
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ubi_replication') THEN CREATE ROLE ubi_replication WITH REPLICATION LOGIN; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ubi_monitoring') THEN CREATE ROLE ubi_monitoring WITH LOGIN IN ROLE pg_monitor; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer') THEN CREATE ROLE pgbouncer LOGIN; END IF; END $$;
