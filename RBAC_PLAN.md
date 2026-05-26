# RBAC(권한 관리) 도입 계획

> vision(프론트) · videonizer(백엔드) · vision-infra(인프라) 3개 레포에 걸친
> 권한 시스템 도입 계획서. 정책 결정은 확정 상태이며, 이 문서는 구현 로드맵이다.
> 작업 브랜치(전 레포 공통): `claude/affectionate-cray-MOrm9`

---

## 1. 목표와 현재 상태

**목표**: 프로젝트 단위 협업 권한 관리. "읽기는 모두 개방, 쓰기는 역할로 통제".

**현재 상태(조사 결과)**:
- 인증(JWT 쿠키, `login_id`+`dept`)·사용자 디렉터리(`users`)·활동 감사(`activities`)는 구비.
- **인가(authorization)는 전무** — 로그인한 누구나 모든 프로젝트를 읽고/수정/삭제 가능.
- 프로젝트 소유는 `Project.created_by`(text) 한 칸, 멤버십은 `participants`(JSON) 뿐 → 역할 개념 없음.
- 따라서 이번 작업은 "변경"이 아니라 인증 위에 인가 계층을 **새로 얹는** 것. 인프라 추가 컴포넌트는 불필요.

---

## 2. 설계 핵심 원칙

1. **2축 모델**: 전역(시스템) 역할 + 프로젝트별 멤버십 역할.
2. **백엔드가 단일 진실원**: 프론트는 역할 로직을 모른다. 백엔드가 계산한 **불리언 capability 플래그**만 소비.
3. **capability 플래그는 리소스에 동봉**: 별도 권한 스토어/동기화 없음. 리소스 응답이 자기 권한을 같이 싣고 온다.
4. **읽기 개방 / 쓰기 통제**: 모든 조회는 로그인 사용자 전체에게 개방(폐쇄망). 역할은 쓰기에만 작용.
5. **즉시 반영**: 역할은 JWT가 아니라 매 요청 DB 조회 → 권한 회수가 다음 요청부터 즉시 적용.

---

## 3. 확정 정책

### 3.1 역할 4종

| role | 축 | 정의 |
|---|---|---|
| **admin** | 시스템 | 전권 + 프로젝트 생성/삭제 + 서버 세그멘테이션(GPU) |
| **manager** | 프로젝트 | 프로젝트 쓰기 전반(소유 무관 ANY), 멤버 관리 |
| **editor** | 프로젝트 | 업로드·캡처·라벨링·라벨셋, 자기 소유분만 수정·삭제 |
| **viewer** | 프로젝트 | 읽기 전용 멤버 |
| (member) | — | 멤버십 없는 일반 로그인 사용자 = 읽기만 |

### 3.2 읽기 권한 — 로그인한 모든 사용자 (멤버십·프로젝트 무관)

프로젝트 조회 · 리소스 조회 · 비디오 재생/시킹/프리뷰 · 이미지 조회 · 라벨셋 조회 ·
어노테이션 조회 · 활동 피드 · 내보내기(검증·JSON·ZIP)

### 3.3 쓰기 권한 — 프로젝트 role 별

범례: **O** 허용 · **X** 불가 · **OWN** 본인 소유분 · **ANY** 전체

| 카테고리 | 권한 | manager | editor | viewer |
|---|---|:---:|:---:|:---:|
| 프로젝트 | 메타 수정 (이름·설명·기술·수익) | O | X | X |
| 프로젝트 | 참여자 관리 | O | X | X |
| 리소스 | 업로드 (비디오·이미지 배치) | O | O | X |
| 리소스 | 수정 (이름·태그) | ANY | OWN | X |
| 리소스 | 삭제 (캐스케이드) | ANY | OWN | X |
| 프레임추출 | 프레임 캡처·저장 | O | O | X |
| 이미지 | 태그 수정 (단건·벌크) | ANY | OWN | X |
| 이미지 | 삭제 (캐스케이드) | ANY | OWN | X |
| 라벨셋 | 생성 | O | O | X |
| 라벨셋 | 메타 수정 (이름·설명) | O | O | X |
| 라벨셋 | 삭제 | ANY | OWN | X |
| 어노테이션 | 작성·편집·삭제 (bbox·polygon·classify·라벨제외) | O | O | X |
| 어노테이션 | 클래스 관리 (생성·수정·삭제·단축키) | O | O | X |

### 3.4 전역 권한 (admin 전용)

프로젝트 생성 · 프로젝트 삭제 · 서버 세그멘테이션(GPU)

### 3.5 소유권(OWN) 판정 — 컨테이너 소유

| 대상 | 기준 | 비고 |
|---|---|---|
| 리소스 | `Resource.created_by == me` | 신규 컬럼 |
| 이미지 | 부모로 파생: `Image → resource_id → Resource.created_by == me` | 추가 컬럼 없음 |
| 라벨셋 | `LabelSet.created_by == me` | 기존 컬럼 |

> 이미지는 리소스의 자식. 누가 올렸든 소유권은 리소스 소유자에게 귀속(컨테이너 소유).
> 리소스 통삭제가 하위 이미지를 모두 지우는 것도 일관됨.

### 3.6 멤버십 미세 조정 (역할 + override)

`project_members`에 `overrides JSONB`(`{"grant":[...], "deny":[...]}`)를 둬서 역할 기준선에서 개별 조정 가능.

```
effective = ROLE_PERMS[role] - overrides.deny + overrides.grant
```

- 기한(만료) 기능은 **불채택**.
- override 부여는 granter 권한 범위 내로 제한(권한 상승 차단), 그 이상은 admin만.
- 우선 순수 역할만 운영하고, override는 실제 예외가 생기면 활성화(컬럼은 미리 둠).

---

## 4. 데이터 모델 / 스키마 변경 (videonizer/alembic)

신규 마이그레이션 1개로 묶음:

```sql
-- 전역 역할
ALTER TABLE users ADD COLUMN system_role TEXT NOT NULL DEFAULT 'member';
ALTER TABLE users ADD CONSTRAINT ck_users_role CHECK (system_role IN ('admin','member'));

-- 프로젝트 멤버십
CREATE TABLE project_members (
    project_id    UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    user_login_id TEXT NOT NULL REFERENCES users(login_id) ON DELETE CASCADE,
    role          TEXT NOT NULL,
    overrides     JSONB NOT NULL DEFAULT '{}',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    TEXT,
    PRIMARY KEY (project_id, user_login_id),
    CHECK (role IN ('manager','editor','viewer'))
);
CREATE INDEX ix_project_members_user ON project_members(user_login_id);

-- 리소스 소유자
ALTER TABLE resources ADD COLUMN created_by TEXT;  -- 업로드 시 세션에서 스탬프
```

**백필**: 기존 프로젝트의 `created_by` → `project_members`에 `manager`로 삽입. 기존 `participants[]` → `editor`로 삽입. 기존 리소스는 `created_by=null`(→ editor는 못 건드리고 manager/admin만).

---

## 5. 레포별 작업

### 5.1 videonizer (백엔드) — 권한의 단일 진실원

- [ ] `app/permissions.py` 신규 — `Perm` enum + `ROLE_PERMS` 매핑(§3 매트릭스 그대로) + 소유권 판정 헬퍼.
- [ ] Alembic 마이그레이션(§4).
- [ ] `app/models.py` — `system_role`, `ProjectMember`, `Resource.created_by` 반영.
- [ ] `require_perm(perm, scope)` FastAPI 의존성 — admin 바이패스 → system_role → 멤버십 role(+override) 판정 → 403.
  - 필드 단위 분기 2곳: `PATCH /projects/{id}`(메타 vs 멤버), `PATCH /labelsets/{lsid}`(메타 vs 클래스). 멤버는 전용 엔드포인트로 분리 권장.
- [ ] 전 라우터에 `require_perm` 부착(아래 "엔드포인트 가드 표" 기준). **바이트 서빙(source/bytes/thumb/previews)도 누락 없이.**
- [ ] 응답에 `permissions` 플래그 주입(프로젝트·리소스·라벨셋 등 리소스 객체별).
- [ ] `GET /v1/auth/me`에 전역 `capabilities`(isAdmin, canCreateProject) 추가.
- [ ] 멤버 관리 엔드포인트: `POST/PATCH/DELETE /v1/projects/{id}/members`.
- [ ] admin 엔드포인트: `GET /v1/admin/users`, `PATCH /v1/admin/users/{login_id}`(system_role).
- [ ] 누수 지점 보강: `activity?scope=project`(프로젝트 view 검사), `normalize/jobs`(소유자/프로젝트 미연결 — 범위 결정 필요, §8 참고).
- [ ] dev `?as=<login_id>` 로그인(아래 §6). `auth_dev_mode`일 때만.
- [ ] 역할/멤버 변경을 `activities`에 기록.
- [ ] `API_CONTRACT.md` 동시 갱신(권한 필드·신규 엔드포인트·`?as=`).

### 5.2 vision (프론트) — 플래그 소비 + 관리 UI

- [ ] `features/projects/types.ts` — `ProjectPermissions` 타입 + `Project.permissions`.
- [ ] `lib/auth.ts` — `AuthUser.capabilities` 추가.
- [ ] `components/access/Can.tsx` 신규 — 게이팅 프리미티브(hide/disable + 사유 툴팁).
- [ ] 페이지 게이팅: `ProjectsPage`(생성 타일=capabilities, 카드 케밥=permissions), 워크스페이스(세그멘테이션 등).
- [ ] `/admin` 페이지 — 사용자 역할/프로젝트/활동 로그(미들웨어+클라 isAdmin 게이팅).
- [ ] 프로젝트 설정 `/projects/{id}/settings` — 멤버 탭(manager), 메타 탭(manager), 위험구역(admin).
  - 진입점: 프로젝트 카드 케밥 `멤버 관리` + 프로젝트 헤더 `관리` 버튼(canManageMembers 게이팅).
- [ ] dev 전용 유저 스위처(헤더, dev 빌드에서만) → `/v1/auth/login?as=`.
- [ ] `API_CONTRACT.md` 미러 동기화.

### 5.3 vision-infra (인프라) — 최소

- [ ] `AUTH_BOOTSTRAP_ADMINS` env 추가(compose/문서) — 최초 admin 부트스트랩.
- [ ] (스키마·라우팅 변경 없음. nginx `/v1/*` 프록시 그대로.)
- [ ] 이 계획서(`RBAC_PLAN.md`) 유지·갱신.

---

## 6. dev 모드 권한 테스트

- `/v1/auth/login?as=<login_id>` — `auth_dev_mode == True`일 때만 해석. SSO만 건너뛰고 신원을 그 id로 발급.
- **역할 주입 없음**: 그 id의 권한은 DB(`system_role`+`project_members`)에서 읽힘. 운영과 동일 코드 경로 → dev/운영 패리티.
- 역할 부여는 **실제 운영 흐름**으로: `?as=admin` → `/admin`에서 프로젝트·manager 지정 → `?as=manager` → 멤버 배정 → `?as=editor`로 검증.
- 운영(SSO)에선 `as` 완전 무시 → 사칭 불가.

---

## 7. 롤아웃 순서

1. **정책 파일** — `permissions.py`(Perm + ROLE_PERMS). 코드 영향 없는 순수 정의 → 리뷰 용이.
2. **스키마** — 마이그레이션 + 모델 + 백필.
3. **강제 + 플래그** — `require_perm` 의존성, 라우터 부착, 응답 `permissions`/`capabilities`. (mutation부터 강제, 읽기는 개방 유지)
4. **관리/리소스 경로** — 멤버·admin 엔드포인트, `resources.created_by` 스탬프, dev `?as=`.
5. **프론트** — `Can`, 게이팅, `/admin`, 멤버 탭, dev 스위처.
6. **부트스트랩 + 검증** — `AUTH_BOOTSTRAP_ADMINS`, dev `?as=`로 전 역할 매트릭스 검증.

각 단계는 독립 커밋/PR 단위. plan-first 규칙상 각 코드 단계 진입 전 확인.

---

## 8. 미결/확인 필요 항목

- **normalize jobs 범위**: `Job`에 `project_id`/소유자가 없어 잡 결과가 잡 ID만 알면 조회 가능. 권한으로 막으려면 잡↔프로젝트 연결 필요. 막을지/열어둘지 결정.
- **contributor 폐기 확정**: 읽기 전면 개방으로 view 전용 역할 의미 축소. viewer를 "명시적 멤버 표식"으로만 유지.
- **override UI 노출 시점**: 1차는 역할만, override는 실제 예외 발생 시 활성화.

---

## 부록: 엔드포인트 가드 표 (요약)

| 영역 | 대표 엔드포인트 | 필요 권한 |
|---|---|---|
| 세션 | `/v1/auth/*`, `/v1/users*` | require_user (권한 없음) |
| 프로젝트 | `GET /v1/projects*` | 읽기 개방 |
| 프로젝트 | `POST /v1/projects` | PROJECT_CREATE (admin) |
| 프로젝트 | `PATCH /v1/projects/{id}` | 메타=PROJECT_EDIT, 멤버=MEMBER_MANAGE |
| 프로젝트 | `DELETE /v1/projects/{id}` | PROJECT_DELETE (admin) |
| 리소스 | 조회/소스/프리뷰 | 읽기 개방 |
| 리소스 | `POST` 업로드/`/images`/`/previews` | RESOURCE_UPLOAD / FRAME_CAPTURE |
| 리소스 | `PATCH`/`DELETE /{rid}` | RESOURCE_EDIT/DELETE (ANY/OWN) |
| 이미지 | 조회/bytes/thumb | 읽기 개방 |
| 이미지 | `PATCH /{iid}`, `POST /tags`, `DELETE /{iid}` | IMAGE_TAG_EDIT / IMAGE_DELETE (ANY/OWN) |
| 라벨셋 | 조회/annotations GET | 읽기 개방 |
| 라벨셋 | `POST`/`PATCH`/`DELETE` | LABELSET_CREATE / EDIT / DELETE(ANY/OWN), classes=CLASS_MANAGE |
| 라벨셋 | `PUT /{lsid}/annotations` | ANNOTATION_WRITE |
| 내보내기 | `/export/*` | 읽기 개방(폐쇄망) |
| 세그멘테이션 | `POST /v1/segment` | SEGMENTATION_CALL (admin) |
| admin | `/v1/admin/*` | admin |
| 멤버 | `/v1/projects/{id}/members*` | MEMBER_MANAGE |
