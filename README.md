# home-jaram-infra

home-jaram 프로젝트의 **배포/운영 인프라**를 다루는 레포. Docker Compose 기반으로 dev/prod 환경을 구성한다.

## 역할과 위치

- **로컬 (개발 머신)**: 이 레포에서 코드 작업. MacBook 등.
- **VM (`/srv/jaram/infra`)**: 이 레포를 clone 받아 실제 서비스 실행.

```bash
sudo mkdir -p /srv/jaram
sudo chown -R $USER:$USER /srv/jaram
cd /srv/jaram
git clone https://github.com/jaram-plus/home-jaram-infra.git infra
cd infra
```

소스코드 레포(`home-jaram-fe`, `home-jaram-be`)는 VM에 clone하지 않는다. GHCR에서 이미지만 pull.

## 현재 포함된 것 (1차)

- `db` (PostgreSQL 16)
- `backend-dev` (`ghcr.io/jaram-plus/home-jaram-be:develop`)
- `frontend-dev` (`ghcr.io/jaram-plus/home-jaram-fe:develop`)

## 아직 미포함 (후속 차수)

- 2차: `backend-prod`, `frontend-prod` (`:main` 태그)
- 3차: `garage` (S3 호환 객체 스토리지)
- 4차: `cloudflared` (tunnel ingress)
- self-hosted runner + deploy job (FE/BE 레포의 `image.yml`)

## VM에서 1차 수동 검증

### 사전 준비

```bash
# 1. 레포 clone (위 절차)

# 2. .env 복사 및 값 채우기
cp .env.example .env
vim .env
# DB_PASSWORD, JWT_SECRET 등 필수 값을 실제 값으로 교체

# 3. (GHCR 이미지가 private인 경우) 로그인
echo "<GITHUB_PAT>" | docker login ghcr.io -u "<USERNAME>" --password-stdin
# PAT scope: read:packages 권한 필요
```

### 서비스 기동

```bash
cd /srv/jaram/infra

# DB 먼저 (의존 관계상 backend가 healthy하려면 db가 떠 있어야 함)
docker compose up -d db

# 백엔드
docker compose up -d backend-dev

# 프론트엔드 (backend 상태와 무관하게 독립 기동)
docker compose up -d frontend-dev

# 상태 확인 (전체 healthy가 목표)
docker compose ps
```

또는 deploy script 사용:
```bash
chmod +x scripts/deploy-frontend.sh scripts/deploy-backend.sh
./scripts/deploy-backend.sh
./scripts/deploy-frontend.sh
```

### 동작 확인

```bash
# 백엔드 health (HTTP 응답만 확인, 상태 코드 무관)
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8081/

# 백엔드 public API
curl http://127.0.0.1:8081/api/people

# 프론트엔드 사이트
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3001/

# 런타임 config.js (브라우저가 읽어갈 API URL이 여기 박힘)
curl http://127.0.0.1:3001/config.js
# 기대 출력:
# window.__APP_CONFIG__ = window.__APP_CONFIG__ || {};
# window.__APP_CONFIG__.API_BASE_URL = "http://localhost:8081";
```

브라우저로 접속 (VM 로컬 또는 Tailscale/Headscale 내부망):
- 프론트: http://localhost:3001
- 백엔드: http://localhost:8081

### 로그 확인

```bash
docker compose logs -f backend-dev
docker compose logs -f frontend-dev
docker compose logs -f db
```

### 종료 / 롤백

```bash
# 전체 중지 (볼륨은 유지)
docker compose down

# 특정 서비스만 재배포 (롤백 포함)
./scripts/deploy-backend.sh sha-ca11d58   # 특정 SHA 태그로 1회성 override
./scripts/deploy-frontend.sh sha-fb1ee5a
```

영구 롤백은 `.env`의 `BACKEND_DEV_TAG` / `FRONTEND_DEV_TAG`를 변경 후 `docker compose up -d`.

## 주의사항

- `HOST_BIND=127.0.0.1` 기본값 — cloudflared 붙기 전엔 VM 내부에서만 접근 가능. Tailscale로 외부 접속 테스트하려면 `0.0.0.0` 또는 해당 인터페이스 IP로 변경
- `DB_PASSWORD`, `JWT_SECRET`은 `.env`에서 **반드시** 변경 — `.env.example`의 기본값은 placeholder
- `.env`는 절대 커밋 금지 (`.gitignore`에 의해 추적 제외됨)

## 파일 구조

```
.
├── compose.yml             # 서비스 정의 (image-only, build context 없음)
├── .env.example            # compose가 참조하는 env 템플릿
├── .gitignore              # .env 추적 제외
├── scripts/
│   ├── deploy-frontend.sh  # pull + up --wait + ps
│   └── deploy-backend.sh   # 동일
└── README.md               # 이 파일
```

## 확장 계획

compose.yml 내 주석으로 표시된 확장 자리:
- **2차** — `backend-prod`, `frontend-prod` (같은 postgres에 prod DB 추가 또는 분리)
- **3차** — `garage` (S3 호환 스토리지, dev/prod bucket 분리)
- **4차** — `cloudflared` (tunnel ingress, jaram.net/dev.jaram.net/dev-api.jaram.net 라우팅)

self-hosted runner + deploy job은 FE/BE 각 레포의 `.github/workflows/image.yml` 하단 주석 참고.
