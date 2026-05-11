# vision-infra

`vision` 프론트엔드와 `videonizer` 백엔드를 한 번에 띄우는 운영용 인프라
저장소입니다. **앱 코드는 들어 있지 않습니다** — 배포 토폴로지(엣지
nginx, postgres, minio, 리버스 프록시 라우팅)와 환경별 override만 관리합니다.

```
┌──────── nginx (edge, :80→301, :443 TLS) ────────┐
│                                                 │
│   /v1/* (auth/me/login/callback 포함), /healthz  │
│                       → videonizer:8000          │
│   그 외               → vision:3000              │
│                                                 │
└─────────────────────────────────────────────┘
        │                    │
        ▼                    ▼
   videonizer            vision (Next.js
   (FastAPI)             standalone, Node only)
        │
        ├─→ postgres:5432 (메타데이터)
        └─→ minio:9000 (오브젝트 스토리지)
```

엣지에서 TLS 종료, :80 은 `/edge-healthz` 만 남기고 전부 :443 으로 301
redirect. HSTS 헤더 1년. 세션은 `/v1/auth/callback` 가 발급한
`access_token` 쿠키가 단일 origin 안에서 vision/videonizer 양쪽에 보이는
구조 — 자세한 흐름은 `docs/architecture.md` 의 "Auth & session boundary" 절
참고.

## 운영 모드

세 가지 모드 중 하나를 골라서 띄우면 됩니다. 각 모드는 자기 레포의 `.env`
하나만 보고 동작합니다.

| 모드 | 시작 위치 / 명령 | 필요한 .env |
|---|---|---|
| A. vision 단독 | `cd vision && npm run dev` 또는 `docker run --env-file .env vision` | `vision/.env` (전부 비워도 부팅, UI 만 동작) |
| B. videonizer 단독 | `cd videonizer && docker compose up -d --build` | `videonizer/.env` (REGISTRY_URL/IMAGE_PREFIX 외 비워도 부팅) |
| C. 통합 스택 (이 레포) | `cd vision-infra && docker compose -f docker-compose.yml -f docker-compose.{dev,prod}.yml up -d` | `vision-infra/.env` (단일 소스) |

통합 모드(C)에서는 sub-repo 의 `.env` 가 사용되지 않습니다 — 이 레포의 `.env`
가 모든 서비스 환경변수를 책임합니다. `.env` 가 비어 있어도 `REGISTRY_URL` /
`IMAGE_PREFIX` 만 채우면 합리적 기본값으로 부팅하며, `.env.example` 의 vision
런타임 URL 3개(`VIDEONIZER_URL` 등)는 빈 값 = 엣지 nginx same-origin 라우팅이
기본이므로 localhost/IP/도메인 어디로 접속해도 CORS 없이 작동합니다 —
`ALLOWED_ORIGINS` 는 split-domain 운영이거나 dev override 가 :8000 으로 직접
호출될 때만 의미가 있습니다. (세션 쿠키를 쓰는 split-domain 운영에서는 `*` 가
무효이므로 명시적 origin CSV 가 필요 — videonizer 의 `.env.example` 참고.)

## 어디서 뭐를 바꾸나 (cheat sheet)

`vision-infra` 는 **배포 토폴로지** 만 책임합니다. 코드와 스키마는 앱 레포 소유.

| 바꾸고 싶은 것 | 어느 레포 | 어느 파일 |
|---|---|---|
| 프론트엔드 페이지 / 컴포넌트 | `vision` | `src/`, `app/` |
| FastAPI 라우트 / 비즈니스 로직 | `videonizer` | `app/routers/`, `app/main.py` |
| **DB 스키마 / 마이그레이션** | `videonizer` | `app/models.py` + `alembic/versions/` |
| 모델 가중치, ffmpeg 옵션 | `videonizer` | `weights/`, `app/normalize.py` |
| SSO IdP 메타데이터 / JWT 발급 로직 | `videonizer` | `app/routers/auth.py`, `app/auth.py` |
| nginx 라우팅 (`/v1` 등) | **`vision-infra`** | `nginx/conf.d/default.conf` |
| TLS 인증서 (dev/prod 동일) | 운영 호스트 | `/appdata/certs/vip/sso/{fullchain,privkey}.pem` (base compose 가 :ro 마운트) |
| IdP 서명 인증서 (dev/prod 동일) | 운영 호스트 | `/appdata/certs/vip/idp/saml-signing.pem` (base compose 가 :ro 마운트) |
| postgres 익스텐션 (스키마 *전*) | **`vision-infra`** | `db/init/*.sql` |
| postgres / minio 리소스 한도 | **`vision-infra`** | `docker-compose.prod.yml` |
| 서비스 의존성 / healthcheck | **`vision-infra`** | `docker-compose.yml` |
| 운영자 env (레지스트리, 자격증명, 태그, **AUTH_***) | **`vision-infra`** | `.env` |
| CI 빌드 로직 (재사용) | **`vision-infra`** | `.github/workflows/reusable-build-push.yml` |
| CI 빌드 호출 (얇은 caller) | `vision`, `videonizer` | 각자 `.github/workflows/build.yml` |

### 자주 헷갈리는 경계

- **DB 스키마는 `videonizer/alembic/`**, `vision-infra/db/init/` 이 아닙니다.
  `db/init/` 는 마이그레이션이 돌기 *전* 에 있어야 하는 것 (익스텐션, 역할,
  권한) 만. 테이블 / 컬럼은 항상 alembic 으로.
- **vision 컨테이너는 단일 프로세스 (`node server.js`, :3000)** — TLS / 라우팅 /
  body 한도는 모두 컨테이너 밖의 리버스 프록시 책임. `vision-infra` 가 띄울 때은
  엣지 nginx 가, 단독 배포 시엔 외부 nginx/Caddy/ALB 가 그 역할.
- **`videonizer` 의 자체 compose 는 백엔드 단독 dev 용**. 운영엔
  `vision-infra` 가 띄웁. 서비스 이름 (`postgres`, `minio`) 은 양쪽이
  같으므로 백엔드 코드는 어느 환경에서 돌아도 동일.
- **세션 쿠키는 videonizer 책임** — vision 은 `/v1/auth/me` 를 폴링해서
  로그인 상태를 읽기만 합니다. JWT 서명 검증을 vision 의 Edge middleware 로
  옮기지 마세요 (서명 키 분산 문제). middleware 는 쿠키 *존재* 만 확인하고
  실제 검증은 항상 videonizer 가 합니다.

---

## 디렉터리 구조

```
docker-compose.yml         # 베이스: 전 서비스 정의 + healthcheck + 의존성 + cert 마운트
docker-compose.dev.yml     # dev override: 로컬 빌드 + 포트 노출
docker-compose.prod.yml    # prod override: 운영 storage 바인드 마운트 + 리소스 제한
nginx/
  nginx.conf               # 글로벌 nginx 설정
  conf.d/default.conf      # 라우팅 규칙 (:80→:443 redirect, /v1 → videonizer)
  cert-init.sh             # /appdata/certs/vip/sso 의 TLS 인증서 검증자 (누락 시 fail-fast)
db/
  init/01-init.sql         # 첫 실행 시 postgres에 적용되는 init SQL
docs/
  architecture.md          # 아키텍처 + 라우팅/auth 경계 + K8s 확장 노트 (영문)
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

### 1) 레포 레이아웃

상위 디렉터리에 `vision`, `videonizer` 레포가 형제로 클론되어 있어야 합니다.

```
parent/
  vision/
  videonizer/
  vision-infra/   <- 여기
```

### 2) 인증서 디렉터리 (dev / prod 동일)

base compose 가 다음 두 경로를 :ro + `create_host_path:false` 로 마운트합니다 —
디렉터리가 없으면 compose-up 이 즉시 실패합니다 (self-signed 폴백 없음).

```bash
sudo mkdir -p /appdata/certs/vip/sso /appdata/certs/vip/idp
```

- **`/appdata/certs/vip/sso/{fullchain,privkey}.pem`** — 엣지 nginx TLS 인증서.
  운영엔 실제 인증서를 배치. 로컬 dev 라면 self-signed 를 직접 생성:

  ```bash
  sudo openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
      -subj '/CN=localhost' \
      -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
      -keyout /appdata/certs/vip/sso/privkey.pem \
      -out    /appdata/certs/vip/sso/fullchain.pem
  ```

- **`/appdata/certs/vip/idp/saml-signing.pem`** — IdP 의 id_token 서명 검증용 RSA
  인증서. `AUTH_DEV_MODE=true` (기본값) 일 때는 파일이 없어도 동작 — 디렉터리만
  존재하면 mount 통과. 운영 (`AUTH_DEV_MODE=false`) 에서는 IdP 발급 인증서를 배치.

## 로컬 dev 실행

```bash
# 1. 환경변수 준비 (레포 루트의 .env 가 단일 소스 — compose 가 자동 로드)
cp .env.example .env
# 최소: REGISTRY_URL, IMAGE_PREFIX, REGISTRY_USERNAME/PASSWORD 만 채워도 부팅됨.
# 나머지(DATABASE_URL, MINIO_*, ALLOWED_ORIGINS 등)는 빈 값일 때 compose 의
# ${VAR:-default} 또는 코드 기본값(ALLOWED_ORIGINS=*)으로 자동 채워짐.

# 2. 레지스트리 로그인 (1회 — ~/.docker/config.json 에 캐싱됨)
docker login "$REGISTRY_URL" -u "$REGISTRY_USERNAME" -p "$REGISTRY_PASSWORD"

# 3. 스택 기동 (베이스 이미지는 pull, 앱 이미지는 sibling 레포에서 빌드)
# 사전 준비 #2 (인증서 디렉터리) 가 끝난 상태여야 합니다.
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

폐쇄망(에어갑) 빌드:
- 기본값은 **공용** 입니다 — 외부망 / 공용 인터넷 CI 러너에서는 `.env` 에
  추가 설정이 필요 없습니다 (npm/pip 가 공용 레지스트리로 폴백).
- 사내 Samsung Nexus 같은 폐쇄망 미러를 써야 하면 `.env.example` 의
  `NPM_*` (vision) / `PIP_*` (videonizer) 주석 줄을 해제하세요. compose 가
  `.env` 를 읽어 vision / videonizer 빌드에 build args 로 흘려줍니다.
- 다른 사설 미러를 가리키려면 같은 줄을 명시적 URL 로 교체.
- `--build-arg` 를 손으로 타이핑할 필요 없습니다 — `.env` 만 만지면 됨.

기동 확인:

```bash
curl -sS http://localhost/edge-healthz                  # nginx 자체 (:80 헤스체크)
curl -skS https://localhost/edge-healthz                # :443 헤스체크 (self-signed 검증 skip)
curl -skS https://localhost/healthz                     # videonizer healthz (프록시 경유)
curl -skS https://localhost/v1/auth/me                  # 미로그인 → {"authenticated":false,"user":null}
curl -skS https://localhost/                            # vision 프론트엔드
docker compose ps                                       # 모든 서비스 healthy 인지
```

### 단일 이미지만 빌드 / 디버깅

`docker compose build` 가 `.env` 를 자동 인식하므로 raw `docker build` 보다
편합니다:

```bash
cd vision-infra
docker compose -f docker-compose.yml -f docker-compose.dev.yml build vision
```

raw `docker build` 가 꿀 필요하면 `.env` 를 셰로 export 하고 build args 를
명시해야 합니다 (compose 와 달리 `docker build` 는 `.env` 를 안 읽음):

```bash
set -a && . vision-infra/.env && set +a
docker build \
  --build-arg REGISTRY_URL \
  --build-arg IMAGE_PREFIX \
  --build-arg NODE_TAG \
  -t vision:dev vision/
```

## 인증 / SSO (Auth)

세션은 videonizer 의 `/v1/auth/*` 가 책임합니다. 모드 스위치는 단일 환경변수:

| 환경변수 | 기본 | 효과 |
|---|---|---|
| `AUTH_DEV_MODE` | `true` | `/v1/auth/login` 이 IdP 호출 없이 즉시 `AUTH_DEV_USER_*` 로 세션 발급. 신규 dev 환경이 IdP 자격 없이도 로그인된 UI 를 띄움. |
| `AUTH_DEV_MODE` | `false` | OIDC implicit + form_post 로 외부 IdP 호출. `AUTH_ENTITY_ID` / `AUTH_CLIENT_ID` / `AUTH_CERT_PATH` 모두 필요. |
| `AUTH_JWT_SECRET` | `dev-only-jwt-secret-change-me` | 서비스 발급 HS256 JWT 의 서명 키. 운영 배포 전 반드시 강한 랜덤값으로 교체. |
| `AUTH_COOKIE_SECURE` | `false` | HTTPS 엣지 뒤에서는 반드시 `true`. plain-HTTP dev 에서만 `false`. |
| `AUTH_COOKIE_DOMAIN` | `""` | same-origin 운영은 빈 값. split-domain 이면 `.your-domain` 형태. |
| `VISION_REQUIRE_AUTH` (vision) | `false` | `true` 이면 vision 의 Next.js middleware 가 `/projects/*` 쿠키 부재 시 `/v1/auth/login` 으로 302. |

### IdP 어드민에 등록할 값 (redirect_uri)

외부 SSO 콘솔에서 등록하는 redirect_uri 는 **엣지 nginx 의 공개 URL** 입니다.
백엔드 컨테이너의 :8000 은 도커 네트워크 내부 전용이고 IdP 에 절대 노출되지
않습니다.

| 등록 항목 | 값 (표준 HTTPS 443 운영 기준) |
|---|---|
| client_id | `AUTH_CLIENT_ID` 값과 일치 (예: `videonizer`) |
| **redirect_uri (callback URL)** | `https://<운영-호스트>/v1/auth/callback` |
| response_type | `code id_token` |
| response_mode | `form_post` |
| scope | `openid profile` |

예) 운영 도메인이 `vision.example.com` 이면 IdP 에 등록할 redirect_uri 는
`https://vision.example.com/v1/auth/callback` 한 줄. 표준 443 이므로 포트는
생략합니다.

요청 흐름 (포트가 누구 책임인지 한눈에):

```
브라우저 ─(1) GET https://vision.example.com/v1/auth/login (:443)──▶ nginx
                                                                       │
nginx ─(2) 내부 프록시 http://videonizer:8000/v1/auth/login ───────▶ videonizer
                                                                       │
videonizer ─(3) X-Forwarded-Proto/Host 헤더로 redirect_uri 재구성
              = "https://vision.example.com/v1/auth/callback"
            ─(4) 302 → IdP, state=<원래 path> ──────────────────────▶ 브라우저

브라우저 ────────────────────────── IdP 자체 도메인:포트 (사용자 인증 화면) ─▶ IdP

IdP ─(5) form-POST id_token 을 위 redirect_uri 로 ─────────────────▶ nginx :443
                                                                       │
nginx ─(6) 내부 프록시 → videonizer:8000/v1/auth/callback ─────────────▶ videonizer
                                                                       │
videonizer ─(7) id_token 검증 → access_token 쿠키 set → 302 next ──────▶ 브라우저
```

운영 배포 체크리스트:

1. `AUTH_DEV_MODE=false` 로 설정했는지 확인 — 빠뜨리면 누구나 `dev_user` 로 로그인됨.
2. `AUTH_JWT_SECRET` 이 기본값이 아닌지 확인.
3. `/appdata/certs/vip/sso/{fullchain,privkey}.pem` 에 실제 TLS 인증서가 있는지
   확인. base compose 가 :ro + create_host_path:false 로 마운트하므로 누락 시
   compose-up 이 fail-fast (dev/prod 동일, self-signed 폴백 없음).
4. `/appdata/certs/vip/idp/saml-signing.pem` 에 IdP 서명 인증서가 있는지 확인 —
   이 파일이 videonizer 컨테이너의 `AUTH_CERT_PATH` (=`/run/secrets/idp/saml-signing.pem`)
   에 마운트되어 id_token RS256 검증에 쓰입니다.
5. `AUTH_COOKIE_SECURE=true` + `AUTH_COOKIE_DOMAIN` 가 운영 도메인과 일치하는지 확인.
6. IdP 어드민에 `https://<운영-호스트>/v1/auth/callback` 이 정확히 등록돼 있는지 확인 — 한 글자라도 다르면 IdP 가 callback 을 거절합니다.
7. `curl -skS https://<host>/v1/auth/me` 가 `{"authenticated":false,...}` 를 반환하는지 확인 (auth 라우터가 살아 있는지).

## 운영 배포 (khavipw01)

```bash
# 1. 사전 준비 (1회) — docker-compose.prod.yml 상단 주석 + 위 "사전 준비" 참고.
# 2. 운영 .env 는 /appdata/app/vision-infra/.env 에 chmod 600 으로 배치
#    (REGISTRY_URL, IMAGE_PREFIX, REGISTRY_USERNAME/PASSWORD,
#     각 *_TAG 핀, AUTH_DEV_MODE=false + AUTH_JWT_SECRET + 나머지 AUTH_* 포함).
# 3. 레지스트리 로그인 (1회):
#       docker login "$REGISTRY_URL" -u "$REGISTRY_USERNAME" -p "$REGISTRY_PASSWORD"
# 4. 인증서 배치 — base compose 가 세 경로를 전부 :ro 로 마운트.
#    누락 시 compose-up 이 fail-fast (create_host_path:false).
#       /appdata/certs/vip/sso/fullchain.pem    (edge nginx TLS)
#       /appdata/certs/vip/sso/privkey.pem      (edge nginx TLS)
#       /appdata/certs/vip/idp/saml-signing.pem (videonizer SSO id_token 검증)

cd /appdata/app/vision-infra
docker compose --env-file /appdata/app/vision-infra/.env \
  -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose --env-file /appdata/app/vision-infra/.env \
  -f docker-compose.yml -f docker-compose.prod.yml up -d
```

## 외부 클라이언트 직접 접근 (Postgres / MinIO)

운영(prod)에서는 `docker-compose.prod.yml` 이 호스트 포트 **5432
(postgres)**, **9000 / 9001 (minio S3 API / 콘솔)** 을 `0.0.0.0` 으로
바인드합니다. 엣지 nginx 가 앞에 끼지 않는 다이렉트 노출이므로 호스트
방화벽에서 source-IP 화이트리스트를 반드시 적용한 뒤 사용하세요.

분석 / 점검용으로는 superuser(`POSTGRES_USER`) 가 아니라 read-only
역할 **`videonizer_ro`** 를 발급해 쓰세요. 역할은 `.env` 의
`VIDEONIZER_RO_PASSWORD` 가 채워진 상태에서 pgdata 가 비어 있는
첫 부팅 시 `db/init/02-readonly-role.sh` 가 자동 생성합니다.

자세한 절차(방화벽 / TLS / 백업 우선 / pgdata 재초기화 절차 /
연결 예시 / 비밀번호 로테이션)는 `docs/external-access.md` 참고.

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
2. 모든 설정은 env var (ConfigMap/Secret 으로 직행 — `AUTH_JWT_SECRET` 은 Secret)
3. 모든 서비스에 healthcheck (readiness/liveness probe 로 전환)
4. 서비스 간 통신은 항상 서비스 이름 기반 (ClusterIP 동일 모델)
5. host network/host port 바인딩 없음 (엣지 nginx 만 80/443 바인딩 → Ingress 로 전환)
