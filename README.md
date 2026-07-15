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

## 현재 포함된 것 (1차 + 4차)

- `db` (PostgreSQL 16)
- `backend-dev` (`ghcr.io/jaram-plus/home-jaram-be:develop`)
- `frontend-dev` (`ghcr.io/jaram-plus/home-jaram-fe:develop`)
- `cloudflared` (Cloudflare Tunnel — 외부 ingress)

## 아직 미포함 (후속 차수)

- 2차: `backend-prod`, `frontend-prod` (`:main` 태그)
- 3차: `garage` (S3 호환 객체 스토리지)
- self-hosted runner는 설치 완료 (`scripts/install-actions-runner.sh` 참고)
- deploy job만 남음 — FE/BE 레포의 `image.yml`에서 self-hosted runner 사용

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

## Cloudflare Tunnel (4차)

`cloudflared` 서비스가 외부 트래픽을 dev 컨테이너로 라우팅한다. token 기반
remotely-managed tunnel — cloudflared는 Cloudflare edge 연결만 담당하고 ingress
rule은 Cloudflare API/dashboard에서 관리된다.

### 라우팅

| 호스트명 | 서비스 | 용도 |
|---|---|---|
| `dev.jaram.net` | `http://home-jaram-frontend-dev:80` | FE web |
| `devapi.jaram.net` | `http://home-jaram-backend-dev:8080` | BE API |
| catch-all | `http_status:404` | 미매칭 요청 |

`FRONTEND_DEV_API_BASE_URL`(`https://devapi.jaram.net`)과 `CORS_ALLOWED_ORIGINS`
(`https://dev.jaram.net`)가 이 매핑에 맞춰 설정되어 있음.

### 사전 준비

1. `.env`의 `TUNNEL_TOKEN`을 Zero Trust dashboard에서 발급받은 값으로 설정
2. `.env`의 `CF_API_TOKEN`을 별도 API token으로 설정
   - 발급: https://dash.cloudflare.com/profile/api-tokens
   - scope: Account → Cloudflare Tunnel → Edit
   - tunnel connector token(`TUNNEL_TOKEN`)으로는 API 호출 권한이 없어 별도 발급 필요

### 기동

```bash
cd /srv/jaram/infra

# cloudflared는 backend/frontend가 떠 있어야 의미가 있음 (depends_on 으로 순서 보장됨)
docker compose up -d cloudflared

# 로그 확인 — "Registered tunnel connection" 이 보이면 edge 연결 성공
docker compose logs -f cloudflared
```

### Ingress rule 주입

cloudflared가 떠 있어도 ingress rule이 없으면 404. 아래 둘 중 하나로 설정:

**방법 A: API 스크립트 (권장)**

```bash
./scripts/configure-cloudflare-tunnel.sh           # dev 라우팅 적용
./scripts/configure-cloudflare-tunnel.sh --show    # 현재 설정 확인만
```

**방법 B: Dashboard 수동 설정**

Zero Trust → Networks → Tunnels → [tunnel] → Public Hostname 탭에서 각 라인 추가:
- Subdomain: `dev`, Domain: `jaram.net`, Service: `HTTP`, URL: `home-jaram-frontend-dev:80`
- Subdomain: `devapi`, Domain: `jaram.net`, Service: `HTTP`, URL: `home-jaram-backend-dev:8080`

### 동작 확인

```bash
# FE web (dev.jaram.net -> frontend-dev:80)
curl -sI https://dev.jaram.net/ | head -5
# 기대: HTTP/2 200, text/html, cf-* 헤더 존재

# BE API (devapi.jaram.net -> backend-dev:8080)
curl -sI https://devapi.jaram.net/ | head -5
# 기대: HTTP/2 401 (루트는 인증 필요) 또는 비즈니스 응답, cf-* 헤더 존재
curl -s https://devapi.jaram.net/api/people | head -c 100
# 기대: {"exec":...} 형태 JSON

# config.js 가 BE URL을 devapi.jaram.net 으로 가리키는지 확인
curl -s https://dev.jaram.net/config.js
# 기대: window.__APP_CONFIG__.API_BASE_URL = "https://devapi.jaram.net";
```

### 주의사항

- token 기반 tunnel은 local `config.yml`의 ingress를 **무시**함. 로컬 ingress를
  쓰려면 cert.pem + credentials-file 방식(locally-managed tunnel)으로 전환 필요
- `TUNNEL_TOKEN`, `CF_API_TOKEN`은 시크릿 — `.env`에만 두고 커밋 금지
- ingress rule은 tunnel 재시작 없이 API/dashboard 변경 시 ~30초 내 반영

## Self-hosted runner (GitHub Actions org runner)

Org runner 하나가 VM에서 가동 중. FE/BE 레포의 workflow에서 deploy job을 실행할 때 사용.

### 구성

| 항목 | 값 |
|---|---|
| org | `jaram-plus` |
| runner group | `jaram-deploy` (repo access: `home-jaram-fe`, `home-jaram-be`) |
| labels | `self-hosted`, `linux`, `x64`, `jaram-vm`, `deploy` |
| 실행 사용자 | `github-runner` (`docker` group 소속 → `docker compose` 실행 가능) |
| 설치 경로 | `/home/github-runner/actions-runner` |
| systemd service | `actions.runner.jaram-plus.<host>.service` (enabled, 부팅 시 자동 시작) |

### 사전 준비 (Dashboard)

1. https://github.com/organizations/jaram-plus/settings/actions → Runner groups → New runner group
   - 이름: `jaram-deploy`
   - Repository access: **Selected repositories** → `home-jaram-fe`, `home-jaram-be`
2. 생성된 `jaram-deploy` 그룹 클릭 → **Add runner** → **New self-hosted runner** → **Linux x64**
3. 표시된 명령어에서 `--token` 뒤의 문자열만 복사 (1회성, 약 1시간 유효, 시크릿)

### 설치 (VM)

```bash
sudo ./scripts/install-actions-runner.sh '<TOKEN>' jaram-deploy
```

스크립트 동작 (idempotent, 재실행 시 이미 있으면 skip):
- `docker` group 존재 확인
- `actions/runner` tarball 다운로드 + SHA256 검증
- `github-runner` 유저 생성 + `docker` group 추가
- `/home/github-runner/actions-runner` 에 tarball extract
- `config.sh --url ... --token ... --labels ... --runnergroup jaram-deploy` 실행
- `svc.sh install github-runner` → systemd unit 등록
- 서비스 enable + start

주의: 매 실행 시 `systemctl restart`가 호출됨. 운영 중 재실행은 runner가 잡을 잡고 있지 않은 Idle 상태에서만 권장.

### 동작 확인

```bash
# systemd
systemctl is-active actions.runner.jaram-plus.server.service   # active
systemctl is-enabled actions.runner.jaram-plus.server.service   # enabled

# journal — "Listening for Jobs" 가 보이면 online
journalctl -u actions.runner.jaram-plus.server.service -n 20 --no-pager

# github-runner 가 docker 사용 가능한지
sudo -u github-runner docker ps

# Dashboard — runner 상태 Idle, labels 5개 표시 확인
# https://github.com/organizations/jaram-plus/settings/actions/runners
```

### 유지보수

**버전 업그레이드:**
1. `scripts/install-actions-runner.sh` 상단 `RUNNER_VERSION`, `RUNNER_SHA256` 업데이트
   - SHA256 출처: `https://api.github.com/repos/actions/runner/releases/latest` 에서
     asset `actions-runner-linux-x64-<VERSION>.tar.gz`의 `digest` 필드
2. 서비스 중지: `sudo systemctl stop actions.runner.jaram-plus.server.service`
3. install dir 제거: `sudo rm -rf /home/github-runner/actions-runner`
4. 캐시 tarball 제거: `rm /tmp/actions-runner-linux-x64-*.tar.gz`
5. 스크립트 재실행 (새 등록 token 필요)

**runner 제거:**
```bash
sudo systemctl stop    actions.runner.jaram-plus.server.service
sudo systemctl disable actions.runner.jaram-plus.server.service
sudo rm /etc/systemd/system/actions.runner.jaram-plus.server.service
sudo systemctl daemon-reload
# GitHub Dashboard에서 runner 삭제 (offline 표시 후 Remove) — 또는:
cd /home/github-runner/actions-runner && sudo -u github-runner ./config.sh remove --token <TOKEN>
sudo rm -rf /home/github-runner/actions-runner
```

### 주의사항

- 등록 token은 1회성 시크릿 — 스크립트 로그에 출력되지 않음
- `jaram-deploy` group이 `home-jaram-fe`, `home-jaram-be` 에만 접근 허용. 다른 repo에서 이 runner를 사용하려면 Dashboard에서 그룹의 repository access에 추가 필요
- runner working directory (`_work/`)가 커질 수 있음 — 주기적 확인 권장

## 주의사항

- `HOST_BIND=127.0.0.1` 기본값 — cloudflared 붙기 전엔 VM 내부에서만 접근 가능. Tailscale로 외부 접속 테스트하려면 `0.0.0.0` 또는 해당 인터페이스 IP로 변경
- `DB_PASSWORD`, `JWT_SECRET`은 `.env`에서 **반드시** 변경 — `.env.example`의 기본값은 placeholder
- `.env`는 절대 커밋 금지 (`.gitignore`에 의해 추적 제외됨)

## 파일 구조

```
.
├── compose.yml                          # 서비스 정의 (db, backend-dev, frontend-dev, cloudflared)
├── .env.example                         # compose가 참조하는 env 템플릿
├── .gitignore                           # .env 추적 제외
├── scripts/
│   ├── deploy-frontend.sh               # pull + up --wait + ps
│   ├── deploy-backend.sh                # 동일
│   ├── configure-cloudflare-tunnel.sh   # CF API로 tunnel ingress rule 주입
│   └── install-actions-runner.sh        # org self-hosted runner 설치 (idempotent)
└── README.md                            # 이 파일
```

## 확장 계획

compose.yml 내 주석으로 표시된 확장 자리:
- **2차** — `backend-prod`, `frontend-prod` (같은 postgres에 prod DB 추가 또는 분리)
- **3차** — `garage` (S3 호환 스토리지, dev/prod bucket 분리)

self-hosted runner는 본 VM에 설치 완료 (`scripts/install-actions-runner.sh`).
deploy job만 남음 — FE/BE 각 레포의 `.github/workflows/image.yml` 하단 주석 참고.
