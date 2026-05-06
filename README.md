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
