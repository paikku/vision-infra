# Architecture

This document captures the load-bearing decisions in the compose files —
the canonical operational form for this stack. K8s migration content
appears at the end as **future-reference material** (§5); it is not the
primary purpose of this repo. Read this doc before changing service
shape, volume layout, or network topology.

## Compose service map

| Service              | Image                      | Listens | Persistence                                | Notes                                                             |
| -------------------- | -------------------------- | ------- | ------------------------------------------ | ----------------------------------------------------------------- |
| `nginx` (edge)       | `nginx:1.27-alpine`        | 80, 443 | `nginx/certs/` (read-only mount)           | Only service binding host ports. Routes to `vision`, `videonizer`. Terminates TLS; :80 redirects to :443 except `/edge-healthz`. |
| `vision`             | `vision:dev` (or registry) | 3000    | none                                       | Single-process Next.js standalone (`node server.js`). No nginx in the image. |
| `videonizer`         | `videonizer:dev`           | 8000    | `/srv/tmp` (job scratch, prod bind-mount)  | FastAPI app. Healthcheck on `/healthz`.                           |
| `videonizer-migrate` | `videonizer:dev`           | none    | none                                       | One-shot `alembic upgrade head` runs before `videonizer` starts. |
| `videonizer-loadfiller` | `videonizer:dev`        | none    | none                                       | Idle load filler agent (`python -m app.loadfiller`). Minimum CPU weight, OOM-first. See "Idle load filler". |
| `postgres`           | `postgres:16-alpine`       | 5432    | `pgdata` named volume (prod bind-mount)    | `db/init/*.sql` applied on first start (empty volume only).      |
| `minio`              | `minio/minio:latest`       | 9000, 9001 | `miniodata` named volume                | S3-compatible object store. Console on 9001.                     |

## Routing contract (edge nginx)

Edge nginx terminates TLS and routes by path on a single shared origin
so the `access_token` cookie installed by `/v1/auth/callback` is
visible to every later request — vision's middleware, vision's
`AuthProvider`, and every videonizer endpoint all see the same cookie
on the same host.

| Listener  | Path             | Behavior                                            |
| --------- | ---------------- | --------------------------------------------------- |
| `:80`     | `/edge-healthz`  | 200 (Docker probe — independent of upstreams)       |
| `:80`     | everything else  | 301 → `https://$host$request_uri`                   |
| `:443`    | `/edge-healthz`  | 200 (HTTPS probe)                                   |
| `:443`    | `/v1/*`          | `videonizer:8000` (includes `/v1/auth/*`)           |
| `:443`    | `/healthz`       | `videonizer:8000`                                   |
| `:443`    | everything else  | `vision:3000`                                       |

The :443 server adds `Strict-Transport-Security: max-age=31536000;
includeSubDomains`. Browsers latch onto HTTPS for a year after a
single successful response — test ramp-downs need a fresh profile or
a different host.

Cookies and `Set-Cookie` are explicitly forwarded both ways so the
session cookie set by `/v1/auth/callback` reaches the browser and
every later request carries it back to videonizer.

For air-gapped or pre-TLS test deployments where real certs aren't
available, the `cert-init.sh` bootstrap generates a self-signed pair
on first start so the :443 listener still responds. Real certs
mounted at `nginx/certs/{fullchain,privkey}.pem` are detected by the
`[ -s "$CRT" ]` guard and the bootstrap becomes a no-op.

## Why there's only one nginx in the stack

`vision/Dockerfile` is intentionally a single-process Next.js
standalone runner — `node server.js` on port 3000, nothing else.
TLS, body limits, and HTTP-level routing are the edge nginx's job in
this stack (and would be a K8s Ingress's job in a cluster). The vision
image stays small and the data path is one hop instead of two.

For a standalone vision deployment without `vision-infra`, the same
applies — put a reverse proxy (nginx, Caddy, ALB) in front of port
3000. Don't add nginx back into the image.

## Auth & session boundary

Auth lives entirely in videonizer (`/v1/auth/*`); vision reads
session state via `GET /v1/auth/me` and renders accordingly. The
edge nginx is the seam that makes the boundary practical:

- vision and videonizer share one origin behind the edge → the
  `access_token` cookie set by `/v1/auth/callback` is sent on every
  later `/v1/*` request automatically (browser default).
- vision's `middleware.ts` (Edge runtime) checks for the cookie's
  *presence* before serving `/projects/*` when
  `VISION_REQUIRE_AUTH=true`. Cryptographic validation stays in
  videonizer — the edge runtime would otherwise need a JWT library
  and the signing key, doubling the secret-distribution surface.
- A forged cookie still passes the middleware presence check but
  every `/v1/*` call still validates the JWT, so the worst case is
  the SPA loading once and immediately seeing 401s.

The `AUTH_COOKIE_SECURE` flag must follow the listener: `true`
behind HTTPS (this stack's edge), `false` for plain-HTTP local dev
where each service is hit on its own port. Cookie domain stays
empty for same-origin deployments and switches to `.your-domain`
only when vision and videonizer are split across sub-domains.

## Machine callers (PHPI ingest)

Every route behind the edge authenticates with the session cookie except
one: `POST /v1/phpi/items`, called by an external model server that pushes
judged images. It rides the ordinary `/v1/*` location — no dedicated nginx
block — and authenticates in videonizer with a shared `X-API-Key` secret
(`PHPI_INGEST_API_KEY`; empty disables ingest). The edge does no IP
filtering or rate limiting for it; restrict the sender at the host firewall
if it is a known address. The PHPI pages (`/phpi/*`) are ordinary vision
routes and fall through to `location /`.

PHPI image blobs land in the same MinIO bucket under `phpi/items/` and are
deleted by videonizer after `PHPI_RETENTION_DAYS`. At the expected volume
(~18k images/day, ~100 KB each) a one-year window holds up to ~660 GB, so
the MinIO data mount must be sized for it.

## GPU worker (outside the stack)

Model training and inference do not run in any service of this compose
stack. They run on a separate GPU machine (Windows), in a worker process
that ships in the `videonizer` repo (`gpu_worker/`) and is installed there
as plain Python — it is not an image and has no service here.

- **The worker dials in; nothing dials out.** It polls
  `https://<host>/v1/gpu/worker/*` every few seconds. Like the PHPI ingest
  it rides the ordinary `/v1/*` location and authenticates in videonizer
  with a shared `X-API-Key` (`GPU_WORKER_API_KEY`; empty = no worker can
  attach). The GPU machine needs outbound 443 to the edge and nothing else:
  no inbound port, no route to postgres or minio, no credentials for either.
- **The edge's upload limits are load-bearing for it.** A worker uploads
  checkpoints and trained weights (hundreds of MB) and downloads datasets
  through the edge. `client_max_body_size 2g`, `proxy_request_buffering
  off` and the 3600 s proxy timeouts in `nginx/nginx.conf` are what let
  those through — lowering them breaks training, not just video upload.
- **The stack holds all state.** The job queue and model metadata are in
  postgres; model weights (`models/`), dataset snapshots and checkpoints
  (`projects/{id}/gpu-jobs/`) are in the MinIO bucket, so they are covered
  by the same backups. The GPU machine keeps only a cache; it can be
  rebuilt or replaced without losing a model.
- **The stack runs fine without it.** With no worker attached, training
  requests queue and everything else is unaffected.
- **Its idle filler is unrelated to `videonizer-loadfiller`.** That service
  tops up this host's CPU and memory; the GPU filler tops up the GPU on the
  worker's machine and is switched on separately (`/v1/gpu/filler`).

MinIO sizing: a trained model is ~6–120 MB depending on the architecture,
and each unfinished training job holds one checkpoint about three times its
model's size. Models are kept until someone deletes them.

## Idle load filler

`videonizer-loadfiller` raises host-wide CPU and memory utilization to an
admin-set target (50–80 %, default 75 %) while the host is otherwise idle,
and records host utilization once a minute (kept for 7 days). It is the
videonizer image run with a different command, so it needs no image of its
own. The agent's behavior, schema and API live in `videonizer`
(`app/loadfiller/`, `/v1/admin/load-filler`, `/v1/admin/utilization`); this
repo owns only how it is run.

- **Control plane is the database.** An admin toggles it on the `/admin`
  page; videonizer writes the desired state to postgres; the agent polls
  it every 5 s. No port, no nginx route, no service-to-service call. If
  the agent cannot confirm its settings for 20 s it turns itself off.
- **`cpu_shares: 2` is what keeps it out of the way.** The agent's workers
  run as `SCHED_IDLE`, but that policy only ranks tasks inside one cgroup.
  Between containers the kernel compares cgroup CPU weights, so the
  minimum weight is the setting that makes the filler yield to every
  other service. Without it a saturating job measurably slows for the
  few seconds the agent needs to back off; the agent logs
  `loadfiller.cpu_weight_not_minimal` at startup if it is missing.
- **`oom_score_adj: 1000`** makes the ballast the first thing the kernel
  kills if the host runs out of memory. The agent also keeps
  `LOADFILLER_MEM_FLOOR_MB` (default 4096) of `MemAvailable` free.
- **Prod limits are backstops, not the control.** `cpus: "13"` /
  `memory: 24G` cap a misbehaving agent at roughly the highest allowed
  target on the 16 vCPU / 31Gi host. Resize them with the host.
- **It measures the host, not the container.** `/proc/stat` and
  `/proc/meminfo` are not namespaced by Docker. Memory usage is
  `1 − MemAvailable / MemTotal`, so the ballast displaces page cache;
  the 80 % target ceiling is what leaves room for it.
- **Stopping the container is a full off-switch**: `docker compose stop
  videonizer-loadfiller` releases everything immediately. Utilization
  recording stops with it.

## env var ownership

- **`vision-infra/.env`** — operator-owned. POSTGRES_*, MINIO_ROOT_*,
  AUTH_* (SSO + cookie attributes), PHPI_* (ingest key + retention),
  GPU_WORKER_API_KEY (the GPU worker's shared key — the same value is
  set on the GPU machine, outside this repo),
  image tags, edge port overrides. Source of truth for the stack.
- **`videonizer/.env`** — app-owned (DATABASE_URL, MINIO_*, app
  knobs). In the stack, the operator's `.env` mirrors these values so
  both `videonizer-migrate` and `videonizer` get a consistent
  configuration via `env_file: ./.env`.
- **`vision/.env`** — *runtime* env. Backend URLs
  (`VIDEONIZER_URL`, etc.) and the optional `VISION_REQUIRE_AUTH`
  middleware flag are read on container start and re-emitted as
  `window.__ENV` by the Next.js root layout, so a config change
  applies on restart without a rebuild.

## Future expansion: K8s migration

> Compose is the canonical operational form. The notes below describe a
> potential future K8s migration — they exist so the compose files stay
> K8s-friendly today (named volumes, env-driven config, service-name
> DNS, healthchecks), but actually moving to K8s is **not a goal of
> this repo right now**. Skip this section unless you're scoping that
> migration.

The compose files are written so the move to K8s is mechanical. Each
service maps to a `Deployment` + `Service`, named volumes become PVCs,
edge nginx becomes an `Ingress`. Concrete mapping:

| Compose construct                                        | K8s equivalent                                  |
| -------------------------------------------------------- | ----------------------------------------------- |
| `services.<x>` + `image:`                                | `Deployment` (replicas: 1 to start)             |
| `services.<x>.networks: [vision_net]` (DNS by name)      | `Service` (ClusterIP) — DNS by service name     |
| `services.<x>.ports: ["80:80"]` (only on `nginx`)        | `Ingress` (or `Service` of type `LoadBalancer`) |
| `services.<x>.volumes: [pgdata:/var/lib/postgresql/data]` | `PersistentVolumeClaim` + `volumeMounts`        |
| `env_file: ./.env`                                       | `ConfigMap` (non-secrets) + `Secret` (secrets)  |
| `healthcheck:`                                           | `readinessProbe` + `livenessProbe`              |
| `depends_on: { condition: service_healthy }`             | initContainer or app-level retry                |
| `depends_on: { condition: service_completed_successfully }` (migrate) | `Job` + `initContainer` waiting for it          |
| `restart: unless-stopped`                                | `Deployment.spec.template.spec.restartPolicy: Always` |
| `deploy.resources.limits/reservations` (prod override)   | `resources.limits` + `resources.requests`       |

### Migration checklist

1. Generate base manifests with `kompose convert -f docker-compose.yml`
   as a starting point — expect to rewrite, not reuse verbatim.
2. Replace `nginx` service with an `Ingress` resource. The routing
   table in `nginx/conf.d/default.conf` translates 1:1 into Ingress
   `pathType: Prefix` rules; HSTS and HTTPS redirect become Ingress
   annotations (`nginx.ingress.kubernetes.io/force-ssl-redirect`,
   `nginx.ingress.kubernetes.io/hsts`).
3. Convert named volumes (`pgdata`, `miniodata`) to PVCs with the
   storage class your cluster uses. Bind-mount paths in the prod
   override go away — operator state lives in cluster storage.
4. Move `videonizer-migrate` into a `Job` and gate `videonizer`'s
   pod startup on it via an `initContainer` that polls migration
   completion.
5. Split `.env` into:
   - `ConfigMap/vision-infra-env` for non-secrets (image tags,
     bucket names, log levels, hostnames, `AUTH_DEV_MODE`,
     `AUTH_COOKIE_*`).
   - `Secret/vision-infra-secrets` for credentials
     (POSTGRES_PASSWORD, MINIO_ROOT_PASSWORD, MINIO_SECRET_KEY,
     DATABASE_URL, **`AUTH_JWT_SECRET`**).
6. Drop `restart: unless-stopped` (Deployments handle this) and
   `depends_on` (use probes + initContainers).
7. Test the routing rules with a synthetic upstream pair before
   moving the real apps over — `nginxdemos/hello` works as a stub
   for both `vision` and `videonizer`.

### What stays the same

- Service names (`postgres`, `minio`, `videonizer`, `vision`) — apps
  reference these in env vars; keep them stable across compose and K8s.
- Healthcheck commands (Docker → probes is a syntax change, not a
  semantic change).
- `db/init/*.sql` — works as-is via a postgres init Job or sidecar.

### What does NOT translate

- `entrypoint: []` + `command: [...]` overrides — K8s pods specify
  `command` and `args` separately. The vision override needs to be
  re-stated in the `Deployment.spec.template.spec.containers[].command`.
- `env_file:` — K8s has no direct equivalent; emit ConfigMap/Secret
  with `envFrom:`.
- `depends_on` semantics around `service_healthy` — the migration
  pattern is initContainer + readinessProbe, not a declarative dep.
