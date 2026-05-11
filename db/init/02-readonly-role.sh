#!/bin/bash
# Create the `videonizer_ro` LOGIN role for external read-only clients
# (analytics, ad-hoc inspection). The role gets SELECT on every current
# and future table in the public schema, but no DML / DDL.
#
# Runs only on first container boot (when pgdata is empty), per the
# upstream postgres image init convention. To rotate the password or
# enable the role after the fact, see docs/external-access.md.
#
# VIDEONIZER_RO_PASSWORD comes from the operator .env via docker-compose.yml.
# When unset (dev with empty .env), we skip silently — the dev stack
# does not need this role.
set -e

if [ -z "${VIDEONIZER_RO_PASSWORD:-}" ]; then
  echo "[init] VIDEONIZER_RO_PASSWORD empty — skipping videonizer_ro role." >&2
  echo "[init] Set it in .env and reinitialize pgdata to create the role." >&2
  exit 0
fi

psql -v ON_ERROR_STOP=1 \
     -v ro_pw="$VIDEONIZER_RO_PASSWORD" \
     -v dbname="$POSTGRES_DB" \
     --username "$POSTGRES_USER" \
     --dbname "$POSTGRES_DB" <<-'EOSQL'
CREATE ROLE videonizer_ro LOGIN PASSWORD :'ro_pw';
GRANT CONNECT ON DATABASE :"dbname" TO videonizer_ro;
GRANT USAGE ON SCHEMA public TO videonizer_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO videonizer_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO videonizer_ro;
EOSQL
