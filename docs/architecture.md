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

## env var ownership

- **`vision-infra/.env`** — operator-owned. POSTGRES_*, MINIO_ROOT_*,
  AUTH_* (SSO + cookie attributes), image tags, edge port overrides.
  Source of truth for the stack.
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
