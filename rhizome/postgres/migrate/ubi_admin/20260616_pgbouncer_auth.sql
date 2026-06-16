-- pgbouncer auth: a dedicated schema and the get_auth function used by pgbouncer's
-- auth_query (https://www.pgbouncer.org/config.html#auth_query). Runs in ubi_admin.
REVOKE ALL PRIVILEGES ON SCHEMA public FROM pgbouncer;

CREATE SCHEMA IF NOT EXISTS pgbouncer;
REVOKE ALL PRIVILEGES ON SCHEMA pgbouncer FROM pgbouncer;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer;

CREATE OR REPLACE FUNCTION pgbouncer.get_auth (
  INOUT p_user     name,
  OUT   p_password text
) RETURNS record
  LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS
$$SELECT usename, passwd FROM pg_shadow WHERE usename = p_user$$;

REVOKE ALL ON FUNCTION pgbouncer.get_auth(name) FROM PUBLIC, pgbouncer;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(name) TO pgbouncer;
