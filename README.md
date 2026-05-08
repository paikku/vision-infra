# vision-infra

`vision` 프론트엔드와 `videonizer` 백엔드를 한 번에 띄우는 운영용 인프라
저장소입니다. **앱 코드는 들어 있지 않습니다** — 배포 토폴로지(엣지
nginx, postgres, minio, 리버스 프록시 라우팅)와 환경별 override만 관리합니다.

```
┌──────── nginx (edge, 80/443) ────────┐
│                                      │
│   /v1/*, /healthz   → videonizer:8000 │
│   그 외             → vision:3000     │
│                                      │
└──────────────────────────────────────┘
        │                    │
        ▼                    ▼
   videonizer            vision (Next.js
   (FastAPI)             standalone, Node only)
        │
        ├─→ postgres:5432 (메타데이터)
        └─→ minio:9000 (오브젝트 스토리지)
```

## 운영 모드

세 가지 모드 중 하나를 골라서 띄우면 됩니다. 각 모드는 자기 레포의 `.env`
하나만 보고 동작합니다.

| 모드 | 시작 위치 / 명령 | 필요한 .env |
|---|---|---|
| A. vision 단독 | `cd vision && npm run dev` 또는 `docker run --env-file .env vision` | `vision/.env` (전부 비워도 부팅, UI 만 동작) |
| B. videonizer 단독 | `cd videonizer && docker compose up -d --build` | `videonizer/.env` (REGISTRY_URL/IMAGE_PREFIX 외 비워도 부팅) |
| C. 통합 스택 (이 레포) | `cd vision-infra/compose && docker compose --env-file ../.env -f docker-compose.yml -f docker-compose.{dev,prod}.yml up -d` | `vision-infra/.env` (단일 소스) |

통합 모드(C)에서는 sub-repo 의 `.env` 가 사용되지 않습니다 — 이 레포의 `.env`
가 모든 서비스 환경변수를 책임집니다. `.env` 가 비어 있어도 `REGISTRY_URL` /
`IMAGE_PREFIX` 만 채우면 합리적 기본값으로 부팅하며, `ALLOWED_ORIGINS` 미설정
시 videonizer 코드 기본값 `*` 가 적용되어 외부망에서도 동작합니다.

## 어디서 뭘 바꾸나 (cheat sheet)

`vision-infra` 는 **배포 토폴로지** 만 책임집니다. 코드와 스키마는 앱 레포 소유.

| 바꾸고 싶은 것 | 어느 레포 | 어느 파일 |
|---|---|---|
| 프론트엔드 페이지 / 컴포넌트 | `vision` | `src/`, `app/` |
| FastAPI 라우트 / 비즈니스 로직 | `videonizer` | `app/routers/`, `app/main.py` |
| **DB 스키마 / 마이그레이션** | `videonizer` | `app/models.py` + `alembic/versions/` |
| 모델 가중치, ffmpeg 옵션 | `videonizer` | `weights/`, `app/normalize.py` |
| nginx 라우팅 (`/v1` 등) | **`vision-infra`** | `nginx/conf.d/default.conf` |
| postgres 익스텐션 (스키마 *전*) | **`vision-infra`** | `db/init/*.sql` |
| postgres / minio 리소스 한도 | **`vision-infra`** | `compose/docker-compose.prod.yml` |
| 서비스 의존성 / healthcheck | **`vision-infra`** | `compose/docker-compose.yml` |
| 운영자 env (레지스트리, 자격증명, 태그) | **`vision-infra`** | `.env` |
| CI 빌드 로직 (재사용) | **`vision-infra`** | `.github/workflows/reusable-build-push.yml` |
| CI 빌드 호출 (얇은 caller) | `vision`, `videonizer` | 각자 `.github/workflows/build.yml` |

### 자주 헷갈리는 경계

- **DB 스키마는 `videonizer/alembic/`**, `vision-infra/db/init/` 이 아닙니다.
  `db/init/` 는 마이그레이션이 돌기 *전* 에 있어야 하는 것 (익스텐션, 역할,
  권한) 만. 테이블 / 컬럼은 항상 alembic 으로.
- **vision 컨테이너는 단일 프로세스 (`node server.js`, :3000)** — TLS / 라우팅 /
  body 한도는 모두 컨테이너 밖의 리버스 프록시 책임. `vision-infra` 가 띄울 땐
  엣지 nginx 가, 단독 배포 시엔 외부 nginx/Caddy/ALB 가 그 역할.
- **`videonizer` 의 자체 compose 는 백엔드 단독 dev 용**. 운영에선
  `vision-infra` 가 띄움. 서비스 이름 (`postgres`, `minio`) 은 양쪽이
  같으므로 백엔드 코드는 어느 환경에서 돌아도 동일.

---

## 디렉터리 구조

```
compose/
  docker-compose.yml       # 베이스: 전 서비스 정의 + healthcheck + 의존성
  docker-compose.dev.yml   # dev override: 로컬 빌드 + 포트 노출
  docker-compose.prod.yml  # prod override: 바인드 마운트 + 리소스 제한
nginx/
  nginx.conf               # 글로벌 nginx 설정
  conf.d/default.conf      # 라우팅 규칙 (/v1 → videonizer, / → vision)
  certs/                   # TLS 인증서 (.gitignore — 직접 마운트)
db/
  init/01-init.sql         # 첫 실행 시 postgres에 적용되는 init SQL
docs/
  architecture.md          # 아키텍처 + 향후 확장 (K8s) 노트 (영문)
.github/workflows/
  reusable-build-push.yml  # 앱 레포에서 호출하는 재사용 워크플로
  deploy.yml               # 운영 배포 워크플로
.env.example               # 운영자 환경변수 샘플
```

## 이미지 경로 컨벤션

모든 이미지(앱 + 베이스)는 단일 private registry 경로에서 가져옵니다:

```
${REGISTRY_URL}/${IMAGE_PREFIX}/<name>:<tag>
```

미러해야 할 이미지 (예: `harbor.example.com/paikku/` 아래):

| name | upstream |
|---|---|
| `vision` | (CI 가 자동 푸시) |
| `videonizer` | (CI 가 자동 푸시) |
| `postgres` | `docker.io/library/postgres` |
| `minio` | `docker.io/minio/minio` |
| `nginx` | `docker.io/library/nginx` |
| `python` | `docker.io/library/python` (cert-init / videonizer 베이스) |
| `node` | `docker.io/library/node` (vision 베이스) |
| `ffmpeg` | `docker.io/jrottenberg/ffmpeg` (videonizer 베이스) |

`REGISTRY_URL`/`IMAGE_PREFIX`/`REGISTRY_USERNAME`/`REGISTRY_PASSWORD` 는
`.env` 에서 설정 (CI 에서는 GitHub repo/org `vars` + `secrets` 로 동일한 이름).

## 사전 준비

상위 디렉터리에 `vision`, `videonizer` 레포가 형제로 클론되어 있어야 합니다.

```
parent/
  vision/
  videonizer/
  vision-infra/   <- 여기
```

## 로컬 dev 실행

```bash
# 1. 환경변수 준비 (compose/ 가 ../.env 를 읽음)
cp .env.example .env
# 최소: REGISTRY_URL, IMAGE_PREFIX, REGISTRY_USERNAME/PASSWORD 만 채워도 부팅됨.
# 나머지(DATABASE_URL, MINIO_*, ALLOWED_ORIGINS 등)는 빈 값일 때 compose 의
# ${VAR:-default} 와 코드 기본값(ALLOWED_ORIGINS=*) 으로 자동 채워짐.

# 2. 레지스트리 로그인 (1회 — ~/.docker/config.json 에 캐싱됨)
docker login "$REGISTRY_URL" -u "$REGISTRY_USERNAME" -p "$REGISTRY_PASSWORD"

# 3. 스택 기동 (베이스 이미지는 pull, 앱 이미지는 sibling 레포에서 빌드)
cd compose
docker compose --env-file ../.env \
  -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

폐쇄망(에어갭) 빌드:
- vision (npm) 은 Dockerfile ARG 기본값이 사내 Samsung Nexus 를 가리키므로
  별도 설정 없이 빌드됩니다. 외부망에서 빌드하려면 `.env` 에
  `NPM_REGISTRY=` / `NPM_PROXY=` / `NPM_HTTPS_PROXY=` / `NPM_STRICT_SSL=` 를
  빈 값으로 명시해 공개 npm 으로 폴백시키세요.
- videonizer (pip) 도 동일 — `PIP_INDEX_URL=` / `PIP_EXTRA_INDEX_URL=` /
  `PIP_TRUSTED_HOST=` 를 빈 값으로 명시.
- 다른 사설 미러를 가리키려면 `.env` 에 명시적 URL 로 교체.

기동 확인:

```bash
curl -sS http://localhost/edge-healthz       # nginx 자체
curl -sS http://localhost/healthz            # videonizer healthz (프록시 경유)
curl -sS http://localhost/                   # vision 프론트엔드
docker compose ps                            # 모든 서비스 healthy 인지
```

### 단일 이미지만 빌드 / 디버깅

`docker compose build` 가 `.env` 를 자동 인식하므로 raw `docker build` 보다
편합니다:

```bash
cd vision-infra/compose
docker compose --env-file ../.env \
  -f docker-compose.yml -f docker-compose.dev.yml build vision
```

raw `docker build` 가 꼭 필요하면 `.env` 를 셸로 export 하고 build args 를
명시해야 합니다 (compose 와 달리 `docker build` 는 `.env` 를 안 읽음):

```bash
set -a && . vision-infra/.env && set +a
docker build \
  --build-arg REGISTRY_URL \
  --build-arg IMAGE_PREFIX \
  --build-arg NODE_TAG \
  -t vision:dev vision/
```

## 운영 배포 (khavipw01)

```bash
# 1. 사전 준비 (1회) — docker-compose.prod.yml 상단 주석 참고.
# 2. 운영 .env 는 /appdata/app/vision-infra/.env 에 chmod 600 으로 배치
#    (REGISTRY_URL, IMAGE_PREFIX, REGISTRY_USERNAME/PASSWORD,
#     각 *_TAG 핀 포함).
# 3. 레지스트리 로그인 (1회):
#       docker login "$REGISTRY_URL" -u "$REGISTRY_USERNAME" -p "$REGISTRY_PASSWORD"

cd compose
docker compose --env-file /appdata/app/vision-infra/.env \
  -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose --env-file /appdata/app/vision-infra/.env \
  -f docker-compose.yml -f docker-compose.prod.yml up -d
```

## CI/CD

앱 레포(`vision`, `videonizer`)는 `.github/workflows/build.yml` 에서
이 레포의 `reusable-build-push.yml` 을 호출하기만 하면 됩니다.
이미지 빌드 → 레지스트리 푸시 → 매니페스트 태깅이 한 곳에서 관리되어
파이프라인 드리프트가 발생하지 않습니다.

GitHub 설정 (조직 레벨 권장 — 두 앱 레포 공유):

- **vars**: `REGISTRY_URL`, `IMAGE_PREFIX` (+ 선택: `NODE_TAG`,
  `PYTHON_TAG`, `FFMPEG_TAG`)
- **secrets**: `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`

`reusable-build-push.yml` 이 push 단계에서 `vars.REGISTRY_URL`/`IMAGE_PREFIX`
가 비어있으면 즉시 실패하므로 설정 누락이 무음으로 흘러가지 않습니다.

## 향후 확장 (K8s 등)

이 레포의 핵심 목적은 **compose 기반 운영** 의 단일 기준점을 두는 것.
K8s 이행은 핵심 목적은 아니지만, compose 작성 시 아래 원칙을 지키면
나중에 매니페스트 변환 비용이 작아지는 부수 효과가 있어서 그대로
따르고 있음. 자세한 내용은 `docs/architecture.md` 의 "Future
expansion" 절 참고.

1. 모든 볼륨은 named volume (PVC 1:1 매핑 가능)
2. 모든 설정은 env var (ConfigMap/Secret 으로 직행)
3. 모든 서비스에 healthcheck (readiness/liveness probe 로 전환)
4. 서비스 간 통신은 항상 서비스 이름 기반 (ClusterIP 동일 모델)
5. host network/host port 바인딩 없음 (엣지 nginx 만 80/443 바인딩 → Ingress 로 전환)
