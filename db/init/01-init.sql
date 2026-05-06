-- Postgres init script — runs once on first container start (when the data
-- volume is empty). The default postgres image already creates the role and
-- database from POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB env vars; this
-- file is reserved for extensions and project-wide grants that should exist
-- before any app's schema migration runs.

-- pgcrypto: random UUIDs without an extra Python dependency.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
