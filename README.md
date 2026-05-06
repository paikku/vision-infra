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

## 어디서 뭘 바꾸나 (cheat sheet)

`vision-infra` 는 **배포 토폴로지** 만 책임집니다. 코드, 스키마, API 계약은 앱 레포 소유.

| 바꾸고 싶은 것 | 어느 레포 | 어느 파일 |
|---|---|---|
| 프론트엔드 페이지 / 컴포넌트 | `vision` | `src/`, `app/` |
| FastAPI 라우트 / 비즈니스 로직 | `videonizer` | `app/routers/`, `app/main.py` |
| **DB 스키마 / 마이그레이션** | `videonizer` | `app/models.py` + `alembic/versions/` |
| API 계약 (URL, 스키마, 상태 코드) | `videonizer` 가 원본, `vision` 이 사본 | 둘 다 `API_CONTRACT.md` |
| 모델 가중치, ffmpeg 옵션 | `videonizer` | `weights/`, `app/normalize.py` |
| nginx 라우팅 (`/v1` 등) | **`vision-infra`** | `nginx/conf.d/default.conf` |
| postgres 익스텐션 (스키마 *전*) | **`vision-infra`** | `db/init/*.sql` |
| postgres / minio 리소스 한도 | **`vision-infra`** | `compose/docker-compose.prod.yml` |
| 서비스 의존성 / healthcheck | **`vision-infra`** | `compose/docker-compose.yml` |
| 운영자 env (이미지 태그, 자격증명) | **`vision-infra`** | `.env` |
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
  architecture.md          # 아키텍처 + K8s 마이그레이션 노트 (영문)
.github/workflows/
  reusable-build-push.yml  # 앱 레포에서 호출하는 재사용 워크플로
  deploy.yml               # 운영 배포 워크플로
.env.example               # 운영자 환경변수 샘플
```

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
# 1. 환경변수 준비 (compose/ 가 .env 를 읽음)
cp .env.example .env

# 2. 앱 이미지 미리 빌드 (또는 dev override의 build로 자동 빌드)
(cd ../vision && docker build -t vision:dev .)
(cd ../videonizer && docker build -t videonizer:dev .)

# 3. 스택 기동
cd compose
docker compose --env-file ../.env \
  -f docker-compose.yml -f docker-compose.dev.yml up -d
```

기동 확인:

```bash
curl -sS http://localhost/edge-healthz       # nginx 자체
curl -sS http://localhost/healthz            # videonizer healthz (프록시 경유)
curl -sS http://localhost/                   # vision 프론트엔드
docker compose ps                            # 모든 서비스 healthy 인지
```

## 운영 배포 (khavipw01)

```bash
# 1. 사전 준비 (1회) — docker-compose.prod.yml 상단 주석 참고.
# 2. 운영 .env 는 /appdata/app/vision-infra/.env 에 chmod 600 으로 배치.
# 3. 이미지 태그를 .env 에 운영 레지스트리 경로로 지정.

cd compose
docker compose --env-file /appdata/app/vision-infra/.env \
  -f docker-compose.yml -f docker-compose.prod.yml up -d
```

## CI/CD

앱 레포(`vision`, `videonizer`)는 `.github/workflows/build.yml` 에서
이 레포의 `reusable-build-push.yml` 을 호출하기만 하면 됩니다.
이미지 빌드 → 레지스트리 푸시 → 매니페스트 태깅이 한 곳에서 관리되어
파이프라인 드리프트가 발생하지 않습니다.

## K8s 확장 메모

자세한 내용은 `docs/architecture.md` 참조. 핵심 원칙:

1. 모든 볼륨은 named volume (PVC 1:1 매핑)
2. 모든 설정은 env var (ConfigMap/Secret 매핑)
3. 모든 서비스에 healthcheck (readiness/liveness probe로 전환)
4. 서비스 간 통신은 항상 서비스 이름 기반 (ClusterIP 동일 모델)
5. host network/host port 바인딩 없음 (엣지 nginx만 80/443 바인딩 → Ingress로 전환)
