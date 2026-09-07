# ShopItem Curator 배포 계획

> 기준일: 2026-09-07
>
> 주 배포 대상: Render.com
>
> 상태: **사용자 요청으로 Render 배포 보류. 예산 0원.** GitHub 소스 공개만 승인됨. 현재 저장소에는 아직 운영용 `Dockerfile`, 인증 게이트웨이, `render.yaml`이 없다.

## 1. 결론

**현재는 Render 서비스를 생성하거나 배포하지 않는다.** 무료 체험 배포도 아직 승인되지 않았다. 아래의 유료 서비스·영구 디스크·운영 확장안은 향후 예산과 별도 승인이 있을 때의 검토안이며 실행 지시가 아니다.

예산 0원으로 재개한다면 Free Web Service만 검토하되, 업로드 보존과 자동 Target 검색의 제한을 먼저 합의해야 한다. 무료 서비스는 유휴 종료·재시작·재배포 때 로컬 변경을 잃으며 영구 디스크를 연결할 수 없다. 무료 인스턴스 시간은 워크스페이스 전체에서 공유되고, 결제 수단이 있으면 대역폭·빌드 한도 초과 비용도 생길 수 있으므로 `Free` 선택만으로 총비용 0원을 보장하지 않는다. 기존 서비스 사용량과 비용 제한을 먼저 확인한다. [Render Free 제한](https://render.com/docs/free)

Target 승인 API/피드 권한이 없고 현재 공개 검색 HTML에서 세 품목의 상품 데이터가 나오지 않는다. 이번 수정은 무권한 API·403 반복 요청 중단과 진단 개선이지 검색 복구 보장이 아니다. [Target 조회 검토](docs/target-search-review.md)

향후 문서 보존이 필요한 운영안은 **Render Docker Web Service 한 개 + 승인된 영구 저장소**를 기준으로 검토한다.

```text
사용자 브라우저
  └─ HTTPS + 사용자 인증
      └─ Render public gateway (0.0.0.0:$PORT)
          ├─ Flutter Web 정적 파일 제공
          ├─ 인증 토큰/JWT 검증, CSRF·Origin·사용자별 rate limit
          └─ /v1/* 전달
              └─ Curator Dart Proxy (127.0.0.1:8787)
                  ├─ 로컬 Tesseract OCR (외부 API/키 없음)
                  └─ Target / Scene7
```

이 구조를 선택하는 이유는 다음과 같다.

- Flutter Web에는 서버 Bearer token을 넣을 수 없다. OCR은 서버 프로세스에서 로컬 실행한다.
- 현재 Dart 프록시의 trusted-header 인증은 의도적으로 loopback bind에서만 허용된다.
- Render Web Service는 외부 트래픽을 받는 프로세스가 `0.0.0.0:$PORT`에 bind해야 한다. [Render Web Service port binding](https://render.com/docs/web-services#port-binding)
- 따라서 public gateway가 사용자를 인증한 뒤에만 내부 프록시에 신뢰 헤더를 주입하는 구성이 현재 보안 모델과 가장 잘 맞는다.
- Flutter Web은 운영 도메인에서 `/v1/*`를 같은 origin으로 호출하므로 클라이언트에 별도 API URL이나 비밀값이 필요 없다.

Render Static Site와 공개 API Web Service를 바로 분리하는 구성은 1차 선택으로 사용하지 않는다. Render의 외부 URL rewrite는 가능하지만, 공식 문서가 OCR `POST` body·쿠키 전달이나 인증 헤더 주입을 운영 계약으로 보장하지 않는다. 무엇보다 rewrite 자체가 사용자 인증을 제공하지 않는다. [Render redirects and rewrites](https://render.com/docs/redirects-rewrites)

## 2. 현재 배포 준비도

| 항목 | 현재 상태 | 배포 전 조치 |
|---|---|---|
| Flutter Web API 경계 | 운영 도메인에서는 same-origin `/v1/*` 사용 | 유지 |
| 로컬 OCR | Tesseract 프로세스와 Pure Dart 목록 파서 | 런타임에 엔진·언어 데이터 설치, API 키 불필요 |
| API 프록시 | OCR, 상품 조회, 재검토, 재스크래핑, 이미지 프록시 구현 | public 인터넷에 직접 노출하지 않음 |
| 인증 | Bearer 또는 loopback trusted header 지원 | 사용자 인증 public gateway 구현 |
| CORS | exact-origin allowlist 지원 | staging/prod 도메인을 각각 정확히 설정, `*` 금지 |
| 네트워크 | 개발 기본값 `127.0.0.1:8787` | gateway는 `$PORT`, 내부 proxy는 `8787` 사용 |
| 상태 확인 | `/health` liveness와 OCR 실행 파일·언어 데이터를 확인하는 `/ready` 구현, 앱 시작 시 취소 가능한 GET backoff | public gateway에서도 같은 계약 전달 |
| 프로세스 수명주기 | `flutter run`과 프록시는 별도 프로세스 | 컨테이너 시작기가 gateway와 proxy를 함께 감독 |
| 요청 시간 제한 | Flutter gateway 기본 60초, 서버 upstream 기본 45초 | 단일 요청은 client > gateway > upstream 순서를 유지 |
| rate limit | proxy가 원격 IP 기준으로 메모리 제한 | public gateway에서 인증 사용자/IP 기준으로 제한 |
| 런타임 저장 | 입력 문서는 서버 파일로 저장·삭제, 분석 결과는 브라우저 메모리 | 영구 저장소와 휴지통 보존 정책 필요 (10절) |
| 배포 파일 | 없음 | `Dockerfile`, `.dockerignore`, gateway, entrypoint, `render.yaml` 추가 |

현재 Chrome/macOS 연결 실패에서 확인된 것처럼 앱 프로세스만 실행되고 proxy가 없으면 두 플랫폼 모두 실패한다. 운영 컨테이너는 public gateway를 열기 전에 내부 proxy의 readiness를 확인하고, 둘 중 하나가 종료되면 컨테이너 전체가 실패하도록 만들어 Render가 재시작하게 해야 한다.

## 3. 인증 전략

### 3.1 내부 사용자·소규모 베타

가장 빠른 권장안은 **Cloudflare Access**를 Render custom domain 앞에 두는 것이다.

1. Cloudflare Access에서 허용 이메일/그룹/IdP 정책을 설정한다.
2. gateway가 `Cf-Access-Jwt-Assertion`의 서명, `iss`, `aud`, `exp`를 검증한다.
3. 헤더가 있다는 사실만 신뢰하지 않는다. Cloudflare 역시 origin에서 JWT 검증이 필요하다고 명시한다. [Access application token](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/application-token/)
4. gateway는 외부 요청의 `X-Curator-Authenticated`를 항상 삭제한다.
5. JWT 검증 성공 후 내부 요청에만 `X-Curator-Authenticated: 1`을 넣는다.
6. custom domain 검증 후 Render의 기본 `onrender.com` subdomain을 비활성화한다. Render는 custom domain이 있으면 이를 지원한다. [Render custom domains](https://render.com/docs/custom-domains)

Cloudflare를 쓰지 않으면 gateway에 OIDC 로그인을 구현하고 `Secure`, `HttpOnly`, `SameSite` 세션 쿠키와 CSRF 검증을 적용한다. Basic Auth는 일시적인 비공개 preview 외에는 사용하지 않는다.

### 3.2 공개 사용자 서비스

공개 가입이 필요한 경우 Cloudflare Access 정책 대신 애플리케이션 계정 체계를 사용한다.

- OIDC Authorization Code + PKCE
- 서버 발급 `HttpOnly` 세션
- 로그인/로그아웃/만료/철회
- POST 요청의 CSRF 및 exact `Origin` 검사
- 사용자별 OCR 실행량, CPU 시간 및 일일 요청 상한
- 계정 삭제와 업로드 이미지 처리에 관한 개인정보 정책

## 4. Render 배포 선행 구현

### P0-1. Production gateway

`server/curator_web_gateway.dart` 또는 동등한 서버 경계를 추가한다.

- `0.0.0.0:$PORT`에 bind
- `build/web`의 정적 파일 제공
- 존재하지 않는 UI route는 `index.html`로 fallback
- `/v1/*`와 `/health`, `/ready`는 SPA fallback보다 먼저 처리
- 사용자 인증 검증
- 외부 `Authorization`, `X-Curator-Authenticated`, 전달용 내부 헤더 제거
- 인증 성공 요청만 `http://127.0.0.1:8787/v1/*`로 전달
- request body streaming 또는 엄격한 12 MiB 상한
- 응답 body 무제한 buffering 금지
- gateway request ID를 내부 proxy와 응답에 전달
- `index.html`과 service worker는 `no-cache`, fingerprint asset은 장기 immutable cache
- CSP, HSTS, `X-Content-Type-Options`, `Referrer-Policy` 설정

Core/BLoC에는 이 gateway의 HTTP·인증 타입을 넣지 않는다. 변경 범위는 `server/`, 배포 설정, Flutter composition root로 한정하고 `lib/core/`의 Flutter 의존성 0% 원칙을 유지한다.

### P0-2. 내부 proxy 설정

단일 컨테이너에서 현재 Dart proxy는 다음처럼 유지한다.

- `CURATOR_PROXY_HOST=127.0.0.1`
- `CURATOR_PROXY_PORT=8787`
- `CURATOR_TRUSTED_AUTH_HEADER=X-Curator-Authenticated`
- `CURATOR_ALLOW_UNAUTHENTICATED_LOOPBACK=false`
- trusted header의 허용 값은 현재 계약대로 `1`
- staging/prod의 `CURATOR_CORS_ALLOW_ORIGIN`은 exact HTTPS origin만 허용

gateway는 브라우저의 `Origin`을 검증한 뒤 내부 hop에서는 제거하거나, 내부 proxy가 exact production origin을 허용하도록 설정한다.

### P0-3. 시작과 readiness

운영 entrypoint는 다음 순서를 강제한다.

1. 필수 환경변수의 존재만 확인하고 값을 출력하지 않는다.
2. Dart proxy를 loopback에서 시작한다.
3. 내부 liveness와 `/ready`의 Tesseract 실행 파일·언어 데이터 준비 여부를 확인한다. 외부 OCR 호출은 없다.
4. 준비 완료 후 public gateway를 `$PORT`에서 시작한다.
5. 자식 프로세스 하나가 종료되면 다른 프로세스도 종료하고 non-zero로 끝낸다.
6. `SIGTERM`에서 신규 요청을 중단하고 진행 중 요청에 제한된 종료 시간을 준다.

Render health check는 gateway의 `/ready`를 사용한다. Render의 HTTP health check는 5초 안에 `2xx`/`3xx`가 필요하고, 새 배포가 준비되지 않으면 기존 배포를 유지할 수 있다. [Render health checks](https://render.com/docs/health-checks)

### P0-4. 제한값 정렬

- 이미지 원본: 최대 8 MiB
- JSON body: Base64 증가분을 포함해 최대 12 MiB
- catalog 항목: 현재 최대 50개
- 제안 timeout: upstream 45초, gateway 55초, Flutter 60초
- public rate limit 초깃값: OCR 사용자당 분당 5회, catalog 계열 분당 30회
- 내부 proxy의 IP rate limit은 모든 요청이 loopback으로 보이므로 보조 안전장치로만 사용
- 로컬 OCR은 프로세스당 최대 2개 실행, 초과 시 `429`; CPU·메모리 경고와 이미지 1,600만 화소 상한을 적용

Flutter proxy 60초와 서버 upstream 45초로 단일 요청의 기본 순서는 정렬했다. 앱 시작은 취소 가능한 `/ready` GET만 최대 2초 간격으로 반복하고, 개별 readiness timeout 시 실제 HTTP 요청 종료를 확인한 뒤 다음 probe를 보낸다. 준비 완료 후 초기 파이프라인을 한 번 제출하며 초기화 오류의 수동 재시도도 readiness gate를 다시 통과한다. 이미 처리됐을 가능성이 있는 OCR/Target POST는 자동 반복하지 않는다. 다만 대량 products/rescrape는 동기 HTTP 예산을 넘을 수 있으므로 배포 전 chunk 또는 비동기 job API로 분리한다.

현재 Dart의 `Future.timeout`은 제한 시간이 지나도 이미 시작한 원본 작업 자체를 취소하지 않는다. 따라서 운영 gateway를 열기 전에 장기 catalog 작업을 취소 가능한 job으로 전환하거나, 전역 동시 실행 상한과 작업 만료를 적용해 timeout 후 outbound 요청이 누적되지 않게 한다. reverse proxy 뒤에서는 내부 proxy가 모든 요청을 loopback IP 하나로 보므로, 실제 사용자별 rate limit은 인증 gateway에서 검증된 사용자 ID를 기준으로 적용한다.

### P0-5. 개인정보와 외부 서비스 정책

- 문서 메뉴로 추가한 원본은 `CURATOR_ASSETS_DIR/images`에 보존한다. 삭제 시 원본·전용 에셋은 `.document_trash`로 이동하며 자동 영구 삭제는 아직 없다. 운영 전 휴지통 보존 기간·용량 상한·영구 삭제 절차를 정한다. OCR 전처리용 임시 PNG는 요청 완료/실패 시 별도로 삭제한다.
- 이미지, Base64 body, API key, 인증 쿠키, Target upstream URL을 로그에 남기지 않는다.
- 이미지가 우리 백엔드에서만 OCR 처리되며 외부 OCR 서비스로 전달되지 않는다는 점, 원본·휴지통·백업의 보존 정책을 고지한다.
- 이전에 소스나 산출물에 들어간 API 키는 폐기한다. OCR용 새 키는 발급하지 않는다.
- Target 이용약관과 자동 조회 허용 범위를 검토하고 차단 우회 기능을 운영하지 않는다.
- 상품 응답 캐시와 요청 빈도를 보수적으로 설정한다.

## 5. 필요한 배포 산출물

다음 파일은 구현 단계에서 추가한다.

| 파일 | 목적 |
|---|---|
| `Dockerfile` | Flutter Web과 Dart 실행 파일의 multi-stage build |
| `.dockerignore` | `.env`, build cache, IDE 파일과 로컬 산출물 제외 |
| `server/curator_web_gateway.dart` | 정적 파일, 사용자 인증, `/v1` forwarding |
| `tool/render_entrypoint.sh` | proxy readiness와 두 프로세스 수명주기 관리 |
| `render.yaml` | Render 서비스, health check, 환경변수 이름을 IaC로 관리 |
| `test/production_gateway_test.dart` | 인증, spoofing, CSRF, route, size limit 회귀 테스트 |

Docker build의 Flutter/Dart SDK는 검증한 revision으로 고정한다. 서버 런타임에는 Debian/Ubuntu의 `tesseract-ocr`, `tesseract-ocr-eng` 및 동적 라이브러리를 설치한다. Dart 실행 파일만 scratch 컨테이너로 복사하면 OCR을 실행할 수 없다. 이미지 빌드 시 `tesseract --list-langs`로 `eng`를 확인한다. [Tesseract 설치](https://tesseract-ocr.github.io/tessdoc/Installation.html)

Target AVIF를 정밀 윤곽선 처리에 사용하려면 **최종 서버 런타임 이미지**에 `libavif-bin` 및 해당 동적 라이브러리도 설치한다. Debian 13의 1.2.1 이상을 기준으로 `avifdec --help`에서 `--size-limit`, `--dimension-limit`를 확인한다. 빌드 단계에만 설치하거나 Dart 실행 파일만 복사하면 AVIF 이미지 요청이 503으로 실패한다. 서버는 AVIF를 투명도가 보존되는 PNG로 변환하며 Flutter Web과 Pure Dart 코어에는 네이티브 라이브러리를 포함하지 않는다. [Debian libavif-bin](https://packages.debian.org/trixie/libavif-bin)

빌드/CI에서 `CURATOR_TEST_AVIF=1 dart test test/avif_image_decoder_test.dart test/target_avif_pipeline_test.dart`로 실제 디코더·인증 프록시·윤곽선 처리를 검증한다. `/ready`는 OCR만 확인하므로 AVIF 검증을 생략하지 않는다. 기존 fallback은 백엔드/프런트엔드 재배포 후 문서 파이프라인을 다시 실행해야 갱신된다.

OCR은 별도 API 요금이 없지만 CPU·메모리를 소비한다. 512 MiB 적합성을 가정하지 않고 2 GB 런타임에서 최대 이미지 2개 동시 실행 부하 테스트를 시작한다. 빌드/이미지 레이어에는 인증 비밀을 포함하지 않는다.

## 6. Render 환경변수

| 이름 | 분류 | 예시/정책 |
|---|---|---|
| `CURATOR_TESSERACT_BIN` | 비밀 아님 | Linux 런타임 `/usr/bin/tesseract` |
| `CURATOR_AVIFDEC_BIN` | 비밀 아님 | Linux 런타임 `/usr/bin/avifdec` |
| `CURATOR_OCR_LANGUAGE` | 비밀 아님 | `eng`; 추가 언어는 traineddata도 설치 |
| `CF_ACCESS_TEAM_DOMAIN` | 환경별 설정 | Cloudflare Access 사용 시 |
| `CF_ACCESS_AUD` | 환경별 설정 | JWT audience 검증값 |
| `CURATOR_PROXY_HOST` | 고정 | `127.0.0.1` |
| `CURATOR_PROXY_PORT` | 고정 | `8787` |
| `CURATOR_TRUSTED_AUTH_HEADER` | 고정 | `X-Curator-Authenticated` |
| `CURATOR_ALLOW_UNAUTHENTICATED_LOOPBACK` | 고정 | `false` |
| `CURATOR_CORS_ALLOW_ORIGIN` | 환경별 설정 | `https://staging.example.com` 또는 production origin |
| `CURATOR_MAX_BODY_BYTES` | 제한 | `12582912` |
| `CURATOR_MAX_IMAGE_BYTES` | 제한 | `8388608` |
| `CURATOR_MAX_CATALOG_ITEMS` | 제한 | `50` |
| `CURATOR_UPSTREAM_TIMEOUT_SECONDS` | 제한 | 초기값 `45` |
| `CURATOR_RATE_LIMIT_PER_MINUTE` | 내부 안전장치 | 부하 테스트 후 결정 |
| `PORT` | Render 제공 | public gateway만 사용 |

Render는 환경변수와 secret file을 지원한다. Blueprint의 `sync: false`는 최초 생성 시 값 입력을 요청하지만 기존 서비스 갱신과 preview 환경에는 제약이 있으므로, 운영 secret은 Dashboard와 환경별 environment group에서 관리한다. [Render environment variables and secrets](https://render.com/docs/configure-environment-variables)

## 7. 배포 설정 보류

현재 예산과 배포 보류 결정을 반영해, 바로 복사할 수 있었던 유료 Blueprint 초안을 제거했다. 서비스 생성 설정은 배포 재개 승인, 인증 gateway·컨테이너 구현, 저장 방식 합의 후 작성한다. 예산이 0원인 동안 유료 compute·disk·database를 선언하거나 만들지 않는다.

Render Blueprint는 기본적으로 저장소 루트의 `render.yaml`을 사용하며 Docker, health check, secret placeholder, auto-deploy를 선언할 수 있다. [Render Blueprint specification](https://render.com/docs/blueprint-spec)

custom domain이 연결되기 전에는 `renderSubdomainPolicy: disabled`를 넣지 않는다. domain 검증과 인증 우회 테스트가 끝난 뒤 기본 `onrender.com` 주소를 비활성화한다.

## 8. 배포 단계

### 단계 A — 배포 차단 항목 구현

- [ ] production gateway와 인증 구현
- [ ] 내부 trusted-header spoofing 테스트
- [ ] proxy readiness 및 프로세스 감독 구현
- [ ] timeout 후 장기 작업 취소 또는 bounded job 실행 구현
- [ ] 인증 사용자별 rate limit 구현
- [ ] timeout·body limit·rate limit 정렬
- [ ] Docker multi-stage build와 secret scan
- [ ] `render.yaml` 작성 및 schema 검증
- [ ] 개인정보 안내와 Target 정책 검토

### 단계 B — Staging

1. Tesseract와 언어 데이터가 포함된 runtime 이미지를 준비한다.
2. 로컬 OCR 부하 검증은 Render `1c-2g` Web Service로 시작하고 측정 결과로 조정한다.
3. staging custom domain과 Access/OIDC 정책을 먼저 설정한다.
4. OCR 경로/언어와 인증 환경별 값을 Dashboard에 입력한다. OCR API 키는 필요 없다.
5. `/ready`가 통과한 뒤 아래 smoke test를 실행한다.
6. 최소 24시간 동안 오류율, cold start가 아닌 실제 latency, 메모리와 egress를 관찰한다.

Render Free Web Service는 15분 유휴 후 내려가며 다음 요청의 재기동이 약 1분 걸릴 수 있고, Render도 운영용으로 권장하지 않는다. OCR UX와 readiness 검증 때문에 production에는 사용하지 않는다. [Render Free limitations](https://render.com/docs/free)

### 단계 C — Production

1. production 환경과 secret을 staging에서 분리한다.
2. custom domain과 자동 TLS를 검증한다.
3. 인증되지 않은 `/v1/*`가 `401` 또는 `403`인지 확인한다.
4. 외부에서 위조한 trusted header가 거절되는지 확인한다.
5. Render 기본 subdomain을 비활성화하고 우회 접근을 재검사한다.
6. CI checks 통과 배포만 허용한다.
7. 배포 직후 30분 집중 모니터링 후 정상 전환을 선언한다.

### 단계 D — 확장

단일 서비스의 CPU, 메모리, 장애 영역 또는 권한 분리가 문제가 될 때 다음으로 분리한다.

```text
Render Web Service: 정적 Web + 인증 gateway
        │ Render private network + generated bearer
        ▼
Render Private Service: Curator Dart Proxy + Tesseract
```

private proxy에는 생성된 `CURATOR_PROXY_TOKEN`을 사용하고 gateway만 그 값을 가진다. Flutter Web에는 전달하지 않는다. 동일 region의 Render private network를 사용한다. Static Site는 private network에 참여하지 않으므로 public gateway를 생략할 수 없다. [Render private networking](https://render.com/docs/private-network)

## 9. CI/CD 및 릴리스 게이트

모든 배포 후보에서 다음을 실행한다.

```bash
dart format --output=none --set-exit-if-changed lib server test tool
flutter analyze
flutter test
flutter build web --release
dart compile exe server/curator_proxy_server.dart
docker build .
```

추가 검증:

- 서버/클라이언트에 Google OCR endpoint 호출이 없고 Web bundle에 과거 API key pattern이 없는지 검사
- container가 비밀 없이 빌드되는지 검사
- `/health`와 `/ready`
- 미인증 API 차단
- 만료·잘못된 audience·위조 JWT 차단
- trusted header spoofing 차단
- 인증된 OCR `POST`
- Target 조회·검토·재스크래핑·이미지 proxy
- 허용/비허용 Origin
- 8 MiB 이미지와 12 MiB body 경계
- `413`, `429`, upstream timeout, client disconnect
- Flutter SPA deep link fallback
- 이전 Render deploy로 rollback 연습

기본 CI는 OCR 인식 port/프로세스와 Target을 mock한다. Tesseract가 설치된 CI에서는 `CURATOR_TEST_LOCAL_OCR=1 dart test test/tesseract_text_recognizer_test.dart`로 두 샘플 및 새 생성 이미지의 실제 추출을 검증한다. Staging은 비민감 이미지로 OCR과 Target의 인증된 endpoint를 확인한다.

## 10. 저장소와 데이터 보존

문서 추가·삭제 기능으로 서버는 더 이상 stateless가 아니다. 위 Blueprint 초안에는 아직 disk 설정이 없으므로 그대로 배포하면 문서 보존을 보장하지 않는다. 파일 저장소를 유지하는 첫 배포에서는 유료 Render 서비스에 `/var/data` Persistent Disk를 연결하고 `CURATOR_ASSETS_DIR=/var/data/curator-assets`를 지정한다. 재배포 후에도 업로드와 삭제 결과가 유지되는지 확인한다. [Render Persistent Disks](https://render.com/docs/disks)

디스크는 런타임에만 사용 가능하며, 같은 저장소에는 프록시 프로세스 하나만 실행한다. 이 선택은 단일 인스턴스로 제한되고 배포 시 잠깐의 중단이 발생한다. 초기 샘플을 원하면 최초 런타임에만 명시적으로 복사하고, 이후 시작 때는 삭제한 문서를 다시 복사하지 않는다. `.document_trash`를 정적 Web 경로로 공개하지 않는다. [디스크 제약](https://render.com/docs/disks#disk-limitations-and-considerations)

현재 문서 카탈로그는 인증된 앱 사용자 사이에서 공유된다. 공개 서비스 전환 전에는 사용자별 소유권과 삭제 권한을 추가해야 한다. 자동 생성 파이프라인 결과는 여전히 브라우저 메모리이며, 모든 매니페스트가 서버에 자동 저장되는 것은 아니다.

향후 사용자별 큐레이션을 저장할 경우:

- 원본/상품 이미지와 canvas: S3 또는 Cloudflare R2
- manifest와 사용자 상태: Postgres
- 브라우저에는 만료가 짧은 signed URL만 제공
- 삭제·보존 기간·백업·복원 절차 정의

다중 인스턴스로 확장할 때는 현재 `SourceDocumentRepository`의 파일 구현을 object storage 기반 구현으로 교체하고, 소유권 메타데이터를 별도로 저장한다.

## 11. 모니터링과 비용

수집할 지표:

- route별 요청 수, p50/p95/p99 latency, `4xx`/`5xx`
- 로컬 OCR `429`(동시 실행 초과), `422`(판독 실패), 프로세스 timeout
- Target 조회·이미지 proxy 실패율
- request body 크기와 거절 횟수
- 인증 실패와 rate-limit 횟수
- CPU, 메모리, 재시작, readiness 실패
- Render outbound bandwidth, OCR CPU 시간·메모리 사용량

로그에는 request ID, route, status, duration, 인증 사용자 hash만 남긴다. 이미지, body, cookie, token, API key, 전체 Target URL은 기록하지 않는다.

Render는 외부 API 호출과 브라우저로 보내는 응답을 outbound bandwidth로 집계하므로 이미지 proxy의 cache 정책과 전송량을 특히 관찰한다. [Render outbound bandwidth](https://render.com/docs/outbound-bandwidth)

로컬 OCR로 CPU·메모리 사용이 늘었으므로 초기 부하 검증은 `1c-2g`(1 CPU, 2 GB)에서 시작한다. 충분한 여유가 측정되면 축소를 검토하고, p95 메모리가 70%를 지속해서 넘으면 상향한다. [Render compute plans](https://render.com/docs/compute-plans)

## 12. 장애 대응과 rollback

- health/readiness 실패: Render가 새 배포로 트래픽을 전환하지 않도록 한다.
- 오류율 급증: 직전 성공 deploy로 즉시 rollback한다.
- OCR readiness 실패: 실행 파일 PATH, 언어 traineddata, 파일 권한을 점검한다. OCR 실패는 고정 샘플 데이터로 숨기지 않는다.
- Target 장애: OCR 결과는 보존하되 상품 조회 실패를 명확히 표시하고 무한 재시도하지 않는다.
- 인증 장애: API는 fail-closed하며 인증을 우회해 복구하지 않는다.
- 문서 저장소는 별도 백업·복원 정책에 따라 RPO를 정한다. 코드 deploy rollback이 업로드·삭제까지 되돌려 주지는 않는다. 휴지통은 동일 디스크에 있으므로 독립 백업을 대체하지 않으며, 사용자 브라우저의 진행 중 분석 결과도 별도로 저장되지 않는다.

## 13. 대안 플랫폼

| 선택지 | 추천 상황 | 장점 | 주의점 |
|---|---|---|---|
| Render Docker Web Service | 현재 1순위 | 기존 선호 플랫폼, Docker·TLS·health·rollback 단순 | 사용자 인증 gateway를 직접 준비해야 함 |
| Railway | Render와 유사한 개발 경험 | Docker, variables, private networking이 간단 | Serverless wake 첫 요청 실패 가능성, 사용자 인증은 별도 |
| Fly.io | 다중 region과 VM 제어가 중요한 경우 | 지역 배치, Machines, runtime secrets | 운영 복잡도가 높고 volume은 단일 host/region 제약 |

Google 서비스 없이 운영하려는 현재 요구에서는 Render를 유지하고 Railway/Fly.io를 대안으로 검토한다.

Railway는 [Variables](https://docs.railway.com/variables), [Serverless](https://docs.railway.com/deployments/serverless), [Volumes](https://docs.railway.com/volumes/reference)를 기준으로 검토한다. Fly.io는 [runtime secrets](https://fly.io/docs/apps/secrets/)와 [Fly Proxy autostop/autostart](https://fly.io/docs/reference/fly-proxy-autostop-autostart/)를 기준으로 검토한다.

## 14. 최종 Go/No-Go 기준

다음 항목이 모두 충족될 때만 production DNS를 전환한다.

- [ ] Flutter bundle과 container image에 비밀값 없음
- [ ] 인증 없는 모든 `/v1/*` 요청 차단
- [ ] JWT/session 검증과 trusted-header spoofing 테스트 통과
- [ ] production origin 외 요청 차단
- [ ] proxy가 먼저 준비되고 gateway가 나중에 traffic을 받음
- [ ] Tesseract 또는 언어 데이터 누락 시 `/ready` 실패
- [ ] OCR, Target 상품, 이미지 proxy end-to-end 성공
- [ ] 요청 크기, rate limit, timeout 실패가 사용자에게 안전하게 표시됨
- [ ] 로그에 이미지·token·key·upstream response body 없음
- [ ] custom domain TLS와 `onrender.com` 우회 차단 확인
- [ ] rollback 연습 완료
- [ ] 개인정보 고지와 Target 정책 검토 완료
- [ ] Render 자원·비용 경고 설정 완료
