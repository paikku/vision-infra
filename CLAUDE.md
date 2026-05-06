# Project Instructions

`vision-infra` is the operator-owned orchestration layer for the
`vision` (Next.js frontend) + `videonizer` (FastAPI backend) stack.
**Do not put app code here.** This repo contains compose manifests,
nginx config, db init scripts, CI/CD reusable workflows, and operator
runbooks — nothing that ships in an app image.

Read `README.md` (operator-facing, Korean) and `docs/architecture.md`
(English) before changing service shape, volume layout, or routing.

## Most-violated rules

1. **Plan-first is the default.** Skip the plan only when *all four* hold:
   - WHAT is fixed by the user's words (literal value / exact rename
     target / named file location / explicit reference).
   - HOW is obvious, or the user enumerated the steps in this turn.
   - Blast radius stays local (no service shape change, no port
     change, no env contract change between this repo and an app repo).
   - A single `git revert` would unwind it cleanly.

   Otherwise: post a short plan and stop in that turn. No edits before
   an explicit go-ahead (`ok` / `ㄱㄱ` / `진행`). Silence is not consent.

2. **Cross-repo contracts are real.**
   - Service names (`postgres`, `minio`, `videonizer`, `vision`) are
     referenced by app env vars (`DATABASE_URL=...@postgres:5432`,
     `MINIO_ENDPOINT=minio:9000`). Renaming a service breaks the app.
   - The routing prefix in `nginx/conf.d/default.conf` (`/v1/*` →
     videonizer) is hardcoded to videonizer's current URL surface. If
     videonizer changes its URL prefix, this nginx config must change
     in lockstep. (Managing the API surface itself — request/response
     schemas, status codes — is **not** this repo's responsibility;
     that lives in the app repos.)
   - The reusable workflow input contract (`reusable-build-push.yml`)
     is consumed by `vision/.github/workflows/build.yml` and
     `videonizer/.github/workflows/build.yml`. Breaking changes need
     PRs in all three repos.
   - **DB schema lives in `videonizer`, not here.** Tables, columns,
     indexes go through `videonizer/alembic/`. The `db/init/*.sql`
     files in this repo are reserved for things that must exist
     *before* any migration runs — postgres extensions, role grants.
     If a PR adds a `CREATE TABLE` to `db/init/`, reject it and move
     the change into a videonizer alembic revision.

3. **Language scope.**
   - Docs (`docs/*.md`, `CLAUDE.md`, `AGENTS.md`, code comments) →
     **English**.
   - User-facing **`README.md` is Korean** — operators read it first.
   - Commit messages, PR/MR titles + bodies, merge commits, review
     replies → **Korean**. No conventional-commit prefixes
     (`feat:`, `fix:`, etc.).

4. **Commits authored as `paikku`.** The sandbox default is
   `Claude <noreply@anthropic.com>`, so set the four env vars inline
   on every commit:

   ```bash
   GIT_AUTHOR_NAME="paikku" GIT_AUTHOR_EMAIL="jungi_@naver.com" \
   GIT_COMMITTER_NAME="paikku" GIT_COMMITTER_EMAIL="jungi_@naver.com" \
   git commit -m "<제목>" -m "<본문>"
   ```

   Never touch `git config --global`.

5. **No abstraction beyond the request.** Don't templatize a value
   that has one caller, don't add a service for hypothetical future
   use, don't rename a working compose service for "consistency".
   Compose stays boring.

## Verification before commit

```bash
cd compose
# Validate base + dev override merges cleanly.
docker compose -f docker-compose.yml -f docker-compose.dev.yml config >/dev/null
# Validate base + prod override merges cleanly.
docker compose -f docker-compose.yml -f docker-compose.prod.yml config >/dev/null
```

For changes that touch routing or healthchecks, also bring the stack
up locally and verify `curl localhost/edge-healthz`,
`curl localhost/healthz`, `curl localhost/`.
