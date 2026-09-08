# ShopItem Curator · Render 개인용 무료 체험 배포

기준일: 2026-09-07. 사용자가 **예산 0원, 업로드 소실 가능성, 비밀번호 보호** 조건을 승인했다. 공개 소스는 [kimdongup/shopitem-curator](https://github.com/kimdongup/shopitem-curator), 대상은 승인된 Render **My Workspace**다. 기존 다른 서비스는 변경하지 않는다.

## 현재 상태

인증 게이트웨이·원격 확장 연결·Dockerfile·render.yaml의 로컬 검증을 완료했다. 전체 테스트 316개 통과(선택적 통합 6개 제외), 정적 분석 오류 없음, 확장 테스트 7개 통과, Blueprint 유효를 확인했다. 512 MiB/0.5 CPU 컨테이너에서 실제 Chrome 로그인 → 공개 샘플 OCR → 한글 화면 → 로그아웃 검증도 통과했다. 화면 로딩은 외부 서버에 연결하지 않았다. Render 생성/Live 확인은 아직 진행 전이며 아래 링크는 **배포 설정 화면**이다.

사용자는 Render 결제 수단이 등록되어 있지 않다고 확인했다. 추가 과금 자원이나 결제 수단을 등록하지 않는다. 무료 공유 한도 초과 시 빌드·서비스가 제한될 수 있다.

## Render 설정

1. Dashboard Billing에서 기존 서비스들과 공유하는 무료 사용량, 결제 수단, 빌드·대역폭 초과 비용 설정을 확인한다. **Free 인스턴스 선택만으로 총비용 0원을 보장하지 않는다.** 초과 유료 사용은 승인되지 않았다. [Render Free 제한](https://render.com/docs/free)
2. 배포용 파일을 GitHub main에 올린 뒤 [Blueprint 생성 화면](https://dashboard.render.com/blueprint/new?repo=https://github.com/kimdongup/shopitem-curator)을 연다. CLI로 서비스를 생성했다면 중복 생성하지 않는다.
3. My Workspace, shopitem-curator Web Service 하나, **Free / Oregon**을 확인한다. 디스크·DB·Worker는 추가하지 않는다.
4. Apply로 배포한다. Render가 `CURATOR_PREVIEW_PASSWORD`를 무작위로 생성한다. 비밀번호는 소스·Flutter 빌드에 넣지 않는다.
5. 서비스 Environment에서 위 비밀번호를 확인한다. 비밀번호를 채팅이나 GitHub에 붙여 넣지 않는다.
6. 상태가 Live이면 Dashboard에 표시된 실제 HTTPS 앱 주소를 열고 로그인한다.
7. Chrome 확장 팝업의 서버 주소에 이 앱 주소를 입력하고 해당 호스트 연결 권한을 허용한다. 앱 2단계의 새 연결 코드로 연결한다.

연결된 Render 도구는 Docker 서비스 **신규 생성**을 지원하지 않는다. 공식 Render CLI 로그인 또는 Dashboard Apply가 필요하다. 생성 후 상태·로그 확인은 연결 도구로 할 수 있다.

## 이용 범위

- 개인용 체험 공간 하나다. 비밀번호를 공유하면 모든 문서의 열람·삭제 권한도 공유된다. 사용자별 소유권 분리는 없다.
- 무료 서비스의 유휴 종료·재시작·재배포로 업로드 문서·캡처·프로젝트가 사라질 수 있다. 결과는 **HTML 다운로드**로 보관하고 원본 문서도 따로 보관한다. HTML은 프로젝트 복원용 백업이 아니다.
- 무료 서버가 깨어나는 데 시간이 걸리므로 확장보다 앱을 먼저 연다. 강제 주기 요청으로 계속 깨워 두지 않는다.
- 서버 재시작 후에는 앱 로그인과 확장 연결을 다시 한다. 앱 세션은 8시간, 연결 코드는 2분·일회용, 확장 권한은 프로젝트 하나에 8시간이다.
- 자동 Target 검색의 접근 제한은 배포로 해결되지 않는다. 기본은 **브라우저에서 직접 고르기**다.
- 무료 컨테이너에는 서버용 Chrome·Node를 설치하지 않는다. 메모리가 큰 서버 브라우저 전략은 비활성화된다. 사용자 PC Chrome 확장 기능은 사용할 수 있다. 유료 프록시도 구매하지 않는다.
- OCR은 영어(eng), 동시 작업 1개로 제한한다. 큰 이미지 처리와 512 MiB 무료 환경의 실제 부하 한계는 배포 후 확인한다.

## 인증 경계

```text
사용자 Chrome ── HTTPS + HttpOnly 세션 ──┐
                                         ▼
                           게이트웨이 0.0.0.0:$PORT
                           ├─ 로그인·로그아웃·Flutter Web
                           ├─ 앱 /v1/*: 세션 + Origin 검사
확장 ── 프로젝트 코드/권한 ────────────┤─ 지정된 bridge 라우트만
                           └─ 허용 헤더만 전달 + 신뢰 헤더 주입
                                         ▼
                           내부 프록시 127.0.0.1:임의포트
                           ├─ Tesseract OCR / AVIF 변환
                           ├─ 문서·프로젝트·상품 이미지
                           └─ 기존 Target 접근 제한 정책
```

`server/curator_web_server.dart` 한 프로세스가 두 리스너와 OCR 자원을 소유한다. OCR readiness 확인 후 공개 리스너를 열고 SIGTERM/SIGINT 시 정리한다. 개발용 127.0.0.1:8787 서버는 변경하지 않는다.

- 비밀번호 누락·20자 미만 또는 잘못된 origin이면 fail-closed한다.
- 무작위 메모리 세션, Secure/HttpOnly/SameSite=Strict 쿠키, 로그인 시도 제한, 만료·로그아웃을 적용한다. 개발용 http://127.0.0.1에서만 Secure 없이 테스트한다.
- 모든 앱 API와 정적 파일은 로그인 후에만 제공한다. 상태 확인·로그인만 공개한다.
- 변경 요청은 정확한 Origin과 JSON을 요구한다. 앱 Authorization·Cookie·전달 헤더는 내부 프록시로 전달하지 않는다.
- 확장은 앱 비밀번호/세션 대신 프로젝트 권한을 사용한다. 공개 bridge는 pair/read/select/disconnect만 허용하며 일반 웹 Origin은 거절한다. 내부 저장소가 코드·권한을 반드시 검증한다.
- 확장은 사용자가 허용한 정확한 HTTPS Render 호스트에만 연결한다. Target 쿠키·로그인·전체 스크린샷·페이지 DOM을 수집하지 않는다.
- 요청/응답 크기, 동시 요청, 처리 시간, 전역 요청 수를 제한한다. 프록시 응답은 크기를 제한하며 스트리밍한다.
- 헤더 위조·경로 탈출·심볼릭 링크 노출·외부 redirect를 차단한다. 비밀번호·코드·이미지·본문을 로그에 쓰지 않는다.

## 빌드·환경변수

Flutter **3.47.2**, 커밋 `d3b14c876900e553bc736ca19295fc09e3853e8e`를 고정한다. Flutter Web은 CDN 없이 자체 호스팅하고 서버는 Dart AOT 바이너리로 컴파일한다.

한글 UI 글꼴 Noto Sans KR도 OFL 라이선스와 함께 번들에 포함한다. 따라서 일반 화면 표시를 위해 Google Fonts CDN이나 API에 연결하지 않는다. 특수 문자·이모지의 자동 fallback 요청은 외부 연결 보안 정책에 의해 제한될 수 있다.

Minimus BusyBox 빌더/런타임을 digest로 고정하고 검증된 UID 1000으로 실행한다. Tesseract 5.5.3-r0·영어 데이터·libavif apps 1.4.2-r0와 필요한 동적 라이브러리만 복사한다. 런타임에는 Flutter SDK·Git·apk를 넣지 않는다.

Minimus 갤러리는 선택한 BusyBox 1.38.0 **기본 이미지**의 알려진 취약점을 0개로 표시한다. 이는 OCR/AVIF 라이브러리를 추가한 최종 이미지 전체의 스캔 결과가 아니다. [이미지 사양](https://images.minimus.io/images/busybox/lines/latest/versions/1.38.0/specification)

`.dockerignore`는 기본 거절 방식이다. 공개 샘플만 허용하며 개인 문서·휴지통·확장 캡처·.env를 중간 레이어에도 포함하지 않는다.

| 변수 | 용도 |
|---|---|
| CURATOR_PREVIEW_PASSWORD | Render 생성 비밀번호, 런타임 전용 |
| RENDER_EXTERNAL_URL | Render가 제공하는 실제 앱 origin |
| CURATOR_PUBLIC_ORIGIN | 선택적 origin 재정의, 일반 배포에서는 생략 |
| PORT | 공개 포트, 기본 10000 |
| CURATOR_OCR_MAX_CONCURRENT_JOBS | 무료 체험: 1 |
| OMP_THREAD_LIMIT | OCR 엔진 스레드: 1 |
| CURATOR_ASSETS_DIR | /app/assets, 영구 저장소 아님 |

## 검증·업데이트

```bash
flutter analyze
flutter test --concurrency=1
node --test extension/test/worker.test.cjs
docker build --platform linux/amd64 -t shopitem-curator:preview .
render blueprints validate render.yaml
```

게이트웨이 테스트는 미인증 요청, 잘못된 비밀번호, CSRF, 세션 만료·로그아웃, 헤더 위조, 확장 경계, 크기 제한, 경로 탈출을 확인한다. 기존 Core/파이프라인 테스트는 유지한다.

배포 후 최신 deploy Live, /ready 200, 미인증 /v1/documents 401, 로그인 후 목록 200을 확인한다. 공개 샘플로 OCR → 확장 연결 → 담기 → 캔버스 → HTML 다운로드를 확인하고 로그·메모리를 점검한다. 실제 Target 자동 검색 실패를 성공으로 보고하지 않는다.

`autoDeployTrigger: off`로 GitHub push만으로 재배포하지 않는다. 검증된 변경만 Manual Deploy로 적용해 빌드 사용과 문서 소실을 줄인다. 재배포/비밀번호 변경 후 재로그인·확장 재연결이 필요하다.

장애 시 직전 성공 deploy로 rollback한다. **코드 rollback은 사라진 업로드를 복구하지 않는다.** 인증 우회나 승인 없는 유료 업그레이드로 복구하지 않는다.

## 운영 전환 전

영구 저장소는 별도 선택/승인이 필요하다. 다중 사용자 서비스에는 OIDC, 사용자별 소유권·삭제 권한·할당량, 개인정보 정책, 백업/복원 절차가 필요하다. 현재 공유 비밀번호 체험은 이를 대체하지 않는다. 유료 컴퓨트·DB·스토리지·도메인은 이번 승인 범위가 아니다.
