# External access to Postgres and MinIO (prod)

Operator runbook for letting external clients (psql / DBeaver / pgAdmin
/ `mc` / boto3 / aws-cli) talk directly to the prod Postgres and MinIO
instances managed by this repo. Dev access (the standalone backend
stack inside `videonizer/`) is documented in
`videonizer/docs/external-access.md`; this doc is the prod counterpart
and is the **single source of truth for the prod topology**, per
`CLAUDE.md` §2.

## What this repo currently exposes

`docker-compose.prod.yml` binds three host ports on the operator host
(khavipw01):

| Service  | Host port | Purpose                          |
|----------|-----------|----------------------------------|
| postgres | 5432      | psql / DBeaver / pgAdmin         |
| minio    | 9000      | S3 API (`mc`, `aws s3`, boto3)   |
| minio    | 9001      | MinIO web console                |

All three bind to `0.0.0.0` — Docker's `ports:` directive has no
IP-level allowlist of its own. **The host firewall is the only thing
standing between these ports and the network.** Edge nginx is not in
front of them; the only edge-routed path stays `/v1/*` → videonizer
and `/` → vision (see `nginx/conf.d/default.conf`).

Edge nginx does **not** proxy MinIO. If you want a clean
`https://s3.<domain>/` or `https://<domain>/minio/` URL instead of
hitting `:9000` / `:9001` directly, that requires adding an
`nginx/conf.d/*.conf` `server` (or `location`) block in this repo — it
is intentionally not done today because the headers / multipart limits
/ presigned-URL host rewriting need explicit thought per deployment.

## Pre-flight (do this before exposing the ports)

1. **Firewall allowlist.** Lock 5432 / 9000 / 9001 down to a specific
   source-IP allowlist at the host firewall (iptables / nftables /
   cloud security group). Leaving the ports world-reachable is rarely
   worth the risk.

2. **Strong credentials.** Replace every starter value in
   `/appdata/app/vision-infra/.env`:
   - `POSTGRES_PASSWORD` (do NOT keep `videonizer`)
   - `MINIO_ROOT_PASSWORD` (do NOT keep `minioadmin`)
   - `MINIO_SECRET_KEY` (if you split it from root)
   - `VIDEONIZER_RO_PASSWORD` (see "Read-only role" below)
   - `AUTH_JWT_SECRET` (unrelated to this doc but same hygiene)

   `chmod 600 /appdata/app/vision-infra/.env`.

3. **TLS for direct connections.** Direct external access without TLS
   leaks credentials on the wire. Two practical options:
   - Tunnel everything (VPN or `ssh -L 5432:postgres:5432 …`). This is
     the cheapest and what the current setup assumes.
   - Terminate TLS in front of each backend: stunnel / pgbouncer for
     Postgres; an HTTPS reverse proxy in front of MinIO with
     `MINIO_SECURE=true`. Neither is configured by this repo today.

4. **Backups still apply.** Direct external write access dramatically
   raises the importance of a recent backup. Run `pg_dump` +
   `mc mirror` *before* handing a write-capable role to anyone:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.prod.yml exec postgres \
     pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" \
     > /appdata/backup/vision/pg_$(date +%F).sql

   mc mirror --overwrite --remove \
     /appdata/storage/vision/minio \
     /appdata/backup/vision/minio_$(date +%F)/
   ```

## Read-only role (`videonizer_ro`)

For analysts and inspection clients, hand out `videonizer_ro` rather
than the `POSTGRES_USER` superuser. The role gets `SELECT` on every
current and future table in `public`; nothing else.

The role is materialized by `db/init/02-readonly-role.sh` on **first
container boot only** (the upstream postgres image only runs
`docker-entrypoint-initdb.d` against an empty data directory).

**Fresh prod install** (pgdata empty):

```bash
# 1. Put VIDEONIZER_RO_PASSWORD=<strong> in /appdata/app/vision-infra/.env
# 2. Bring up the stack — init runs automatically.
docker compose --env-file /appdata/app/vision-infra/.env \
  -f docker-compose.yml -f docker-compose.prod.yml up -d
```

**Existing prod install** (pgdata already populated, role missing):
the init script will not run again. You have two choices.

*Option A — wipe-and-reinit (clean, requires downtime + backup):*

```bash
# 1. Drain + back up.
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec postgres \
  pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" \
  > /appdata/backup/vision/pg_before_ro_init.sql

# 2. Stop and remove the postgres container + its bind-mounted data.
docker compose -f docker-compose.yml -f docker-compose.prod.yml stop postgres
sudo rm -rf /appdata/storage/vision/postgres/*

# 3. Add VIDEONIZER_RO_PASSWORD to .env, bring postgres back up. Init runs.
docker compose --env-file /appdata/app/vision-infra/.env \
  -f docker-compose.yml -f docker-compose.prod.yml up -d postgres

# 4. Restore data on top of the now-initialized cluster.
cat /appdata/backup/vision/pg_before_ro_init.sql | \
  docker compose -f docker-compose.yml -f docker-compose.prod.yml exec -T postgres \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

*Option B — apply the SQL manually (no downtime):*

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec -T postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
CREATE ROLE videonizer_ro LOGIN PASSWORD '<strong>';
GRANT CONNECT ON DATABASE videonizer TO videonizer_ro;
GRANT USAGE ON SCHEMA public TO videonizer_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO videonizer_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO videonizer_ro;
SQL
```

Option B is faster but leaves `.env` and the cluster out of sync —
record that the role exists out-of-band in your ops notes.

**Rotating the password later:**

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec -T postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "ALTER ROLE videonizer_ro PASSWORD '<new>';"
```

(Update `.env` too so any future reinit matches.)

## Connecting

```
# Postgres (read-only)
psql "postgresql://videonizer_ro:<password>@khavipw01:5432/videonizer"

# Postgres (superuser — for repair work only)
psql "postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@khavipw01:5432/$POSTGRES_DB"

# MinIO (S3 API)
mc alias set vid http://khavipw01:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
mc ls vid/$MINIO_BUCKET

# MinIO console (browser)
http://khavipw01:9001
```

Substitute a tunnel endpoint (`localhost:5432` after `ssh -L …`) if
you went the SSH-tunnel route in step 3 above.

## What NOT to do

- Do not add `CREATE TABLE` / `ALTER TABLE` to `db/init/`. Schema
  belongs in `videonizer/alembic/versions/`. The `db/init/` tree is
  reserved for postgres extensions and role grants only
  (`CLAUDE.md` §2).
- Do not move this prod topology into `videonizer/docker-compose.yml`
  to "make dev look like prod". That file is dev-only by contract
  (`videonizer/CLAUDE.md` §6).
- Do not skip the firewall step. The `ports:` block in
  `docker-compose.prod.yml` binds to `0.0.0.0` and trusts the host
  network layer to do the allowlisting.
- Do not hand out `POSTGRES_USER` (`videonizer`) credentials for
  inspection work. Use `videonizer_ro`.
