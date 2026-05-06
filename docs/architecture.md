# Architecture & K8s migration notes

This document captures the load-bearing decisions in the compose files and
calls out what changes when the stack is lifted onto Kubernetes. Read this
before changing service shape, volume layout, or network topology.

## Compose service map

| Service              | Image                      | Listens | Persistence                                | Notes                                                             |
| -------------------- | -------------------------- | ------- | ------------------------------------------ | ----------------------------------------------------------------- |
| `nginx` (edge)       | `nginx:1.27-alpine`        | 80, 443 | `nginx/certs/` (read-only mount)           | Only service binding host ports. Routes to `vision`, `videonizer`. |
| `vision`             | `vision:dev` (or registry) | 3000    | none                                       | Runs Next.js standalone (`node /app/server.js`); skips bundled supervisord+nginx. |
| `videonizer`         | `videonizer:dev`           | 8000    | `/srv/tmp` (job scratch, prod bind-mount)  | FastAPI app. Healthcheck on `/healthz`.                           |
| `videonizer-migrate` | `videonizer:dev`           | none    | none                                       | One-shot `alembic upgrade head` runs before `videonizer` starts. |
| `postgres`           | `postgres:16-alpine`       | 5432    | `pgdata` named volume (prod bind-mount)    | `db/init/*.sql` applied on first start (empty volume only).      |
| `minio`              | `minio/minio:latest`       | 9000, 9001 | `miniodata` named volume                | S3-compatible object store. Console on 9001.                     |

## Routing contract (edge nginx)

`vision` calls `videonizer` via relative paths when
`NEXT_PUBLIC_VIDEONIZER_URL` is empty (the same-origin reverse-proxy
pattern, documented in `vision/.env.example`). Edge nginx has to honor
that contract:

| Path           | Upstream                |
| -------------- | ----------------------- |
| `/v1/*`        | `videonizer:8000`       |
| `/healthz`     | `videonizer:8000`       |
| `/edge-healthz` | nginx itself (200)     |
| everything else | `vision:3000`          |

The `/edge-healthz` endpoint is intentionally local — Docker can probe
nginx without depending on upstream readiness, which avoids start-up
deadlocks.

## Why vision skips its own nginx in this stack

`vision/Dockerfile` ships a supervisord that runs both Next.js and a
local nginx. That image is self-contained for environments where vision
is deployed alone. In the `vision-infra` stack the edge nginx already
handles TLS, body limits, and routing, so the per-app nginx is dead
weight (and adds an extra hop). The compose override sets
`entrypoint: []` + `command: ["node", "/app/server.js"]` to bypass
supervisord — the rest of the image (`/app/.next/standalone`, public
assets, etc.) is reused as-is.

If you ever switch `vision` to run on its own without `vision-infra`
fronting it, the supervisord path still works; this override is only
active inside this compose stack.

## env var ownership

- **`vision-infra/.env`** — operator-owned. POSTGRES_*, MINIO_ROOT_*,
  image tags, edge port overrides. Source of truth for the stack.
- **`videonizer/.env`** — app-owned (DATABASE_URL, MINIO_*, app
  knobs). In the stack, the operator's `.env` mirrors these values so
  both `videonizer-migrate` and `videonizer` get a consistent
  configuration via `env_file: ../.env`.
- **`vision/.env`** — *build-time only* (`NEXT_PUBLIC_*` get inlined
  at `npm run build`). For the same-origin reverse-proxy deployment
  the build leaves `NEXT_PUBLIC_VIDEONIZER_URL` empty so the bundle
  emits relative `/v1/...` paths.

## K8s migration

The compose files are written so the move to K8s is mechanical. Each
service maps to a `Deployment` + `Service`, named volumes become PVCs,
edge nginx becomes an `Ingress`. Concrete mapping:

| Compose construct                                        | K8s equivalent                                  |
| -------------------------------------------------------- | ----------------------------------------------- |
| `services.<x>` + `image:`                                | `Deployment` (replicas: 1 to start)             |
| `services.<x>.networks: [vision_net]` (DNS by name)      | `Service` (ClusterIP) — DNS by service name     |
| `services.<x>.ports: ["80:80"]` (only on `nginx`)        | `Ingress` (or `Service` of type `LoadBalancer`) |
| `services.<x>.volumes: [pgdata:/var/lib/postgresql/data]` | `PersistentVolumeClaim` + `volumeMounts`        |
| `env_file: ../.env`                                      | `ConfigMap` (non-secrets) + `Secret` (secrets)  |
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
   `pathType: Prefix` rules.
3. Convert named volumes (`pgdata`, `miniodata`) to PVCs with the
   storage class your cluster uses. Bind-mount paths in the prod
   override go away — operator state lives in cluster storage.
4. Move `videonizer-migrate` into a `Job` and gate `videonizer`'s
   pod startup on it via an `initContainer` that polls migration
   completion.
5. Split `.env` into:
   - `ConfigMap/vision-infra-env` for non-secrets (image tags,
     bucket names, log levels, hostnames).
   - `Secret/vision-infra-secrets` for credentials (POSTGRES_PASSWORD,
     MINIO_ROOT_PASSWORD, MINIO_SECRET_KEY, DATABASE_URL).
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
