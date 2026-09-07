# 📖 ShopItem Curator - 사용 및 배포 가이드 (`usage.md`)

본 문서는 **ShopItem Curator** 애플리케이션의 로컬 실행 방법, 파일 선택 및 4단계 큐레이션 파이프라인 기능 사용법, 플랫폼별 빌드 및 배포 절차를 안내합니다.

---

## 📋 1. 사전 요구사항 (Prerequisites)

* **Flutter SDK**: 3.22.0 이상 (권장 3.44.x+)
* **Dart SDK**: 3.4.0 이상 (권장 3.12.x+)
* **서버 OCR**: Tesseract와 영어 언어 데이터 (`brew install tesseract`; Debian/Ubuntu는 `tesseract-ocr tesseract-ocr-eng`)
* **Target AVIF 디코더**: 서버에 `libavif`의 `avifdec` 설치 (`brew install libavif`; Debian 13은 `libavif-bin`)
* **구성된 플랫폼**: Web (Chrome, Safari 등), macOS 데스크톱
* `.metadata`, `web/`, `macos/` 스캐폴딩과 VS Code Chrome/macOS 실행 구성이 저장소에 포함되어 있습니다.

---

## 🚀 2. 로컬 실행 및 개발 (Local Development)

### 2.1 패키지 설치

```bash
cd /Users/mac/Antigravity/shopitem-curator
flutter pub get
```

### 2.2 Pure Dart Core 비즈니스 로직 독립 테스트

```bash
# Pure Dart 단위 테스트 실행 (Flutter 엔진 없이 순수 Dart VM으로 구동)
dart test test/core_bloc_test.dart
```

### 2.3 전체 정적 분석 및 회귀 테스트

```bash
flutter analyze
flutter test
```

> `dart test`만 실행하면 `widget_test.dart`가 필요로 하는 Flutter 엔진(`dart:ui`)을 로드할 수 없습니다. 전체 테스트 스위트는 반드시 `flutter test`로 실행하세요.

### 2.4 애플리케이션 실행

Flutter 앱은 외부 OCR API나 Target에 직접 요청하지 않습니다. OCR은 서버에서 로컬 실행됩니다. 로컬에서도 먼저 Dart 프록시를 실행한 뒤 앱을 실행합니다.

**터미널 1 — 백엔드 프록시**

```bash
# macOS 최초 설치 (Google 계정 / API 키 불필요)
brew install tesseract libavif
tesseract --list-langs
avifdec --version

# Chrome 개발 서버의 정확한 origin만 허용
export CURATOR_CORS_ALLOW_ORIGIN='http://localhost:3000'
dart run server/curator_proxy_server.dart
```

`.env.example`은 설정 템플릿일 뿐입니다. 서버는 `.env`를 자동으로 읽지 않고 시작된 **프로세스 환경**의 값만 읽습니다.

#### Target AVIF 이미지 지원

Target은 URL에 `fmt=pjpeg`가 있어도 AVIF를 반환할 수 있습니다. 이미지 프록시는 MIME 및 실제 파일의 AVIF 브랜드를 확인한 뒤 서버의 `avifdec`로 PNG로 변환합니다. 투명도를 보존하므로 기존 `package:image` 합성과 정밀 윤곽선 추출을 macOS/Web에서 그대로 사용합니다. Pure Dart 코어에 Flutter 또는 FFI 의존성을 추가하지 않습니다.

- 서버에 `brew install libavif`를 실행합니다. Linux는 `libavif-bin`을 런타임에 설치합니다(Debian 13의 1.2.1 이상 기준). `avifdec --help`에 `--size-limit`, `--dimension-limit`가 모두 있어야 합니다.
- 기본 실행 파일은 `avifdec`입니다. IDE PATH 문제가 있으면 **서버 프로세스**에 `CURATOR_AVIFDEC_BIN=/usr/local/bin/avifdec`(Intel Mac), `/opt/homebrew/bin/avifdec`(Apple Silicon), `/usr/bin/avifdec`(Linux)를 지정합니다.
- 변환은 첫 프레임·8-bit PNG, 최대 1,600만 화소·한 변 8,192px, 입력 최대 8 MiB, 출력 `CURATOR_MAX_IMAGE_BYTES` 이하로 제한됩니다. 동시에 2개 작업(각 2스레드), 최대 대기 32개이며 대기 포함 최대 10초입니다.
- 디코더가 없으면 이미지 endpoint는 `503/avif_decoder_unavailable`, 잘못된 AVIF는 `502/avif_decode_failed`를 반환합니다. 기존 `/ready`는 OCR 준비 상태 확인이며 AVIF 설치 검증을 대신하지 않습니다.
- 기존 JPEG/PNG/WebP/GIF는 그대로 전달됩니다. 새 상품 URL의 `raster=png-v1`은 이전 AVIF HTTP 캐시와 구분하기 위한 고정 버전입니다. 백엔드와 Flutter 앱을 함께 재시작한 뒤 문서를 다시 실행해야 이미 계산된 fallback 윤곽선도 재생성됩니다.

실제 디코더와 투명 AVIF → 인증 프록시 → Pure Dart 윤곽선 경로 검증:

```bash
CURATOR_TEST_AVIF=1 dart test test/avif_image_decoder_test.dart test/target_avif_pipeline_test.dart
# 외부 Target 이미지 3개까지 검증할 때만 네트워크 테스트 활성화
CURATOR_TEST_AVIF=1 CURATOR_TEST_TARGET_AVIF=1 dart test test/target_avif_pipeline_test.dart
```

기본 테스트는 외부 Target과 설치된 네이티브 디코더에 의존하지 않도록 해당 통합 테스트를 생략합니다. [libavif CLI](https://github.com/AOMediaCodec/libavif/blob/main/doc/avifdec.1.md), [Debian 패키지](https://packages.debian.org/trixie/libavif-bin).

**터미널 2 — Flutter Web**

```bash
flutter run -d chrome --web-port=3000
```

localhost/127.0.0.1/IPv6 loopback에서 실행되는 Web과 macOS에서는 미지정 백엔드 주소가 `http://127.0.0.1:8787`이므로 별도 define 없이 실행할 수 있습니다. 다른 개발 API를 사용할 때만 `--dart-define=CURATOR_BACKEND_URL=...`을 지정합니다.

```bash
flutter run -d macos
```

`flutter run -d macos`는 앱만 시작하고 프록시를 자동 실행하지 않습니다. 위의 터미널 1 프록시를 계속 실행한 상태에서 사용하세요.

한 터미널에서 프록시 준비 확인 후 앱까지 실행하려면 공통 개발 실행기를 사용할 수 있습니다.

```bash
bash tool/run_dev.sh --device chrome
bash tool/run_dev.sh --device macos
```

실행기는 자신이 시작한 프록시의 `/health` 서비스 ID와 `/ready`에서 OCR 실행 파일·언어 데이터 준비 여부를 검증한 뒤 앱을 실행합니다. 기존 프록시는 인증·CORS 계약을 안전하게 확인할 수 없으므로 재사용하지 않으며, 포트가 사용 중이면 중단합니다. 서버 인증 환경변수는 Flutter에 전달하지 않습니다. 실행기가 시작한 프록시가 종료되면 Flutter도 정리합니다.

기존 `bash tool/run_macos_dev.sh`는 macOS용 호환 wrapper입니다. 앱을 띄우지 않고 프록시와 OCR 엔진 준비만 확인하려면 `bash tool/run_dev.sh --check`를 사용합니다. 이 확인은 `/health`와 `/ready`만 호출하며 이미지 추출이나 Target 조회를 실행하지 않습니다. 실제 OCR 검증은 `dart run tool/check_local_ocr.dart`를 사용하세요.

VS Code/Antigravity에서는 `Curator: Proxy + Chrome` 또는 `Curator: Proxy + macOS`로 함께 시작합니다. 프록시 wrapper는 새 login shell의 Dart/Tesseract PATH를 사용하며 API 키 누락 검사는 없습니다. PATH에서 엔진을 찾지 못하면 `CURATOR_TESSERACT_BIN=/usr/local/bin/tesseract`(Intel Mac) 또는 `/opt/homebrew/bin/tesseract`(Apple Silicon)를 서버 환경에 지정하세요. 기존 8787 listener가 있으면 수동 백엔드를 종료한 뒤 복합 실행을 시작합니다.

앱이 프록시보다 먼저 시작되면 `/ready` GET만 200ms에서 최대 2초까지 backoff하며 계속 확인하고, 화면에는 자동 복구 대기 상태가 표시됩니다. 응답이 멈춘 readiness GET은 `AbortableRequest`로 취소되고 종료된 뒤에만 다음 GET을 시작하므로 요청이 겹쳐 쌓이지 않습니다. 프록시의 OCR 엔진이 준비되면 초기 이미지를 한 번만 제출합니다. OCR·Target POST는 자동으로 재시도하지 않습니다. 호환되지 않는 readiness 응답 등으로 초기화가 중단된 경우 `백엔드 다시 확인`은 `/ready`부터 다시 검증하며 이미지 bytes를 직접 전송하지 않습니다. `Terminal → Run Task`의 ready task는 같은 login-shell 정책을 사용하는 비디버그 대안입니다.

`CURATOR_BACKEND_URL`만 공개 클라이언트 설정이며, 경로 prefix가 있는 `https://example.com/curator-api/`도 지원합니다.

### 2.5 VS Code Flutter 확장 복구

이 저장소에는 Dart/Flutter 확장 권장 목록과 SDK 경로, Chrome/macOS 실행 구성이 `.vscode/`에 포함되어 있습니다. VS Code에서 디버깅, 자동 완성, 장치 목록이 보이지 않으면 다음 순서로 확인합니다.

1. `lib/`가 아닌 `/Users/mac/Antigravity/shopitem-curator` 폴더 전체를 VS Code에서 엽니다.
2. Extensions 패널에서 `Dart`(`dart-code.dart-code`)와 `Flutter`(`dart-code.flutter`)가 이 워크스페이스에서 Enabled 상태인지 확인합니다.
3. Command Palette의 `Flutter: Change SDK`에서 `/usr/local/share/flutter`를 선택합니다. 같은 값이 `.vscode/settings.json`에도 고정되어 있습니다.
4. `Developer: Reload Window`를 실행한 뒤 `Dart: Restart Analysis Server`를 실행합니다.
5. VS Code 터미널에서 `/usr/local/share/flutter/bin/flutter doctor -v`와 `/usr/local/share/flutter/bin/flutter devices`를 실행해 SDK와 Chrome/macOS 장치를 확인합니다.
6. 계속 작동하지 않으면 View → Output의 `Dart` 및 `Flutter` 채널에서 첫 오류를 확인한 뒤 VS Code를 완전히 종료하고 다시 엽니다.

`code` 명령이 쉘 PATH에 없는 것은 VS Code 내부의 Dart/Flutter 확장 활성화와는 별개입니다. 필요하면 VS Code의 `Shell Command: Install 'code' command in PATH`를 실행하세요.

---

## 🎯 3. 주요 기능 및 4단계 파이프라인 사용법

### 1) 1번 화면의 문서 선택·추가·삭제

- 드롭다운은 백엔드 `assets/images/`의 실제 JPEG/PNG 목록을 표시합니다. 두 예제 이름이 더 이상 고정 목록으로 사용되지 않습니다.
- **새 문서 추가…**를 선택하면 macOS/브라우저의 파일 선택창이 열립니다. JPEG/PNG, 최대 8 MiB·1,600만 화소를 지원하며 PDF는 아직 지원하지 않습니다.
- 추가한 파일은 백엔드에 복사되어 앱/백엔드를 다시 실행해도 남습니다. 이름이 같으면 접미사를 붙이며 기존 파일은 덮어쓰지 않습니다. 파일 선택 전의 원본은 수정하거나 삭제하지 않습니다.
- 각 문서 행의 **휴지통 버튼 → 삭제 확인**으로 입력 원본, 그 문서를 `source_image`로 참조하는 매니페스트, 그 매니페스트에서만 사용하는 캔버스·상품 에셋을 활성 저장소에서 제거합니다. 다른 매니페스트에서도 참조하는 공유 에셋과 소유 관계가 확인되지 않는 파일은 보존합니다.
- 삭제 파일은 `<CURATOR_ASSETS_DIR>/.document_trash/<삭제 ID>/{images,items}/`로 이동합니다. 복구 UI는 없으며 서버를 중단한 상태에서 해당 파일을 같은 상대 경로로 되돌린 뒤 목록을 새로고침합니다. 같은 이름의 파일이 있으면 덮어쓰지 말고 먼저 충돌을 해결하세요. 휴지통 자동 영구 삭제는 하지 않습니다.
- 선택한 문서를 삭제하면 미리보기·분석 결과를 비우고 1번 화면에 남습니다. 마지막 문서도 삭제할 수 있고, 이후 새 문서를 추가할 수 있습니다. OCR 실패 시에도 메뉴와 **문서 분석 다시 시도**가 표시됩니다.
- **새로고침**은 다른 클라이언트나 서버 파일 작업으로 변경된 목록을 다시 읽습니다.

기본 저장소는 프로젝트 루트에서 실행한 서버의 `./assets`입니다. 다른 저장소는 서버 환경변수 `CURATOR_ASSETS_DIR`로 지정합니다. 별도 저장소는 빈 목록으로 시작하며 예제를 자동 복사하지 않습니다. 프록시 한 프로세스가 한 저장소를 관리하는 공유 카탈로그이며, 사용자별 분리는 아직 없습니다. 운영에서는 인증과 문서 관리 권한, 영구 저장소, 휴지통 보존/백업 정책을 먼저 구성하세요.

이번 기능은 백엔드 라우트와 네이티브 플러그인이 추가되었으므로 **백엔드와 Flutter 앱을 모두 종료 후 재실행**해야 합니다. hot reload만으로 적용되지 않습니다. macOS 파일 선택에는 Flutter 공식 [`file_selector`](https://pub.dev/packages/file_selector)의 사용자 선택 파일 읽기 전용 권한을 사용합니다.

### 2) 4단계 자동 큐레이션 파이프라인 동작

파일을 선택하면 Pure Dart BLoC가 다음 4단계를 순차적으로 실행하며 진행 상황을 표시합니다:

1. **1단계 (`BackendProxyGateway` → `OcrExtractorService`)**: 백엔드의 로컬 Tesseract로 글자·좌표 인식 후 Pure Dart에서 물품명·수량·개인용 표시 및 표 설명 해석
2. **2단계 (`BackendProxyGateway` → `TargetFetcherService`)**: 백엔드에서 Target 상품 이미지·가격·구매 URL 검색
3. **3단계 (`CanvasCompositorService`)**: 수집된 물품들을 단일 캔버스 레이어로 자동 합성
4. **4단계 (`ContourSegmenterService`)**: 각 물품의 1:1 정밀 윤곽선(Polygon Silhouette)을 도려내어 세그멘테이션 완료

앱 실행 중의 파이프라인 결과는 메모리에서 BLoC 상태로 유지됩니다. 새 입력 문서는 서버 저장소에 저장되지만, 새 분석의 매니페스트와 합성 PNG까지 자동 저장하지는 않습니다. Flutter에 번들된 `assets/`는 읽기 전용이며, 문서 관리는 이 번들이 아닌 백엔드 파일과 인증 API를 사용합니다. 매니페스트와 합성 PNG를 파일로 저장하려면 개발 도구를 별도로 실행해야 합니다.

```bash
# 기본 예제 이미지 2개의 manifest_*.json과 canvas_*.png 재생성
dart run tool/generate_curator_assets.dart

# 특정 입력만 재생성
dart run tool/generate_curator_assets.dart assets/images/new.jpg

# 가능한 경우 실시간 Target 카탈로그 탐색을 우선
dart run tool/generate_curator_assets.dart --live

# 공식 Target PDP의 현재 메인 이미지로 로컬 item_*.jpg/png도 교체 후 재생성
dart run tool/generate_curator_assets.dart --refresh-images

# 네트워크/OCR 없이 현재 로컬 이미지로 합성 PNG와 윤곽선만 재생성
dart run tool/generate_curator_assets.dart --rebuild-only
```

생성물은 `assets/items/`에 씁니다. 개인 문서가 공개 저장소나 Flutter 번들에 섞이지 않도록 새 파일은 기본적으로 Git·번들에서 제외됩니다. 공개 가능한 샘플만 검토 후 `.gitignore`와 `pubspec.yaml`의 명시적 목록에 추가하고 앱을 다시 빌드하세요. 일반 사용자 업로드는 인증된 백엔드 문서 API에서 읽으므로 번들 등록이 필요 없습니다.

Target 자동 검색에는 외부 접근 제한이 있습니다. 서버용 API 접근 승인이 없는 기본 설정에서는 RedSky를 호출하지 않으며, 공개 HTML에 상품 데이터가 없으면 미해결 이유를 표시합니다. 저장된 카탈로그 결과의 가격·재고는 실시간 검증값이 아닙니다. 권한이 있는 운영자만 서버에 `CURATOR_TARGET_REDSKY_KEY`를 설정하세요. 401/403은 같은 프로세스에서 반복하지 않습니다. [상세 검토 결과](docs/target-search-review.md)를 참고하세요.

현재 매니페스트와 상품 이미지로 복사 가능한 self-contained HTML도 만들 수 있습니다. 기본 입력은 전체 25종 매니페스트이며, 이전 Python 명령은 같은 Dart 구현을 호출하는 호환 래퍼입니다.

```bash
dart run tool/export_curator_html.dart

# 입력 매니페스트와 출력 파일을 직접 지정
dart run tool/export_curator_html.dart \
  assets/items/manifest_new.json \
  build/curator_new.html

# 기존 명령 호환
python3 generate_standalone_map.py
```

### 3) 흑백 ➔ 컬러 전환 및 말풍선 가격 태그

* **기본 상태**: 차분한 흑백(Grayscale) 상태로 단일 레이어에 렌더링
* **마우스 호버 / 터치**: 마우스 커서를 올리거나 터치하면 **해당 물품의 1:1 윤곽선만 선명한 풀컬러(Color)**로 전환
* **클릭 시 말풍선 가격 태그**: 물품을 클릭하면 상단에 **꼬리표 말풍선 가격 태그**가 등장하며, **[Target에서 바로 구매하기 ↗]** 링크를 클릭하면 브라우저로 공식 Target 페이지가 열립니다.

구매 버튼은 HTTPS `target.com` 상품 상세(PDP) URL만 활성화합니다. 검색 결과(`/s/...`), 이미지 CDN, 타 도메인, 검증되지 않은 URL은 직링크로 표시하지 않으며 새 PDP가 확인될 때까지 비활성화됩니다.

---

## 🌐 4. 플랫폼별 빌드 및 배포 (Build & Deployment)

### 4.1 빌드

```bash
# 권장: 웹 앱과 /v1 프록시가 같은 origin인 배포
flutter build web --release

# 별도 API origin을 쓰는 배포
flutter build web --release \
  --dart-define=CURATOR_BACKEND_URL=https://api.example.com/curator/

# macOS 데스크톱 앱 릴리즈 빌드
flutter build macos --release
```

Web에서 `CURATOR_BACKEND_URL`을 지정하지 않으면 loopback origin은 로컬 `http://127.0.0.1:8787`, 그 밖의 운영 origin은 현재 Web origin의 root를 사용합니다. 운영에서는 이 같은 same-origin 구성이 CORS와 인증 운영을 가장 단순하게 만듭니다. macOS 앱에는 프록시 통신을 위한 App Sandbox의 `com.apple.security.network.client` entitlement가 Debug/Profile과 Release 구성 모두에 포함되어 있습니다.

### 4.2 운영 토폴로지와 인증

```text
Flutter Web ── HTTPS/사용자 인증 ──> 우리 Reverse Proxy
                                       └──> Dart Curator Proxy
                                               ├──> 로컬 Tesseract (외부 통신 없음)
                                               └──> Target/Scene7
```

`Flutter Web → 우리 백엔드 → 외부 API`라는 말은 브라우저가 외부 서비스의 키나 스크래핑 세부사항을 알지 못하고, 우리가 운영하는 서버의 버전화된 `/v1/*` API만 호출한다는 뜻입니다. 서버는 Target/Scene7 host 허용 목록, 요청·이미지 크기, timeout, IP별 rate limit을 강제합니다.

운영 권장 구성은 다음과 같습니다.

1. Dart 서버를 `CURATOR_PROXY_HOST=127.0.0.1`로 외부에 직접 노출하지 않습니다.
2. TLS·세션/OIDC 인증을 담당하는 reverse proxy에서 브라우저의 `/v1/*` 요청을 인증합니다.
3. reverse proxy가 클라이언트의 `X-Curator-Authenticated` 헤더를 반드시 제거한 뒤, 인증 성공 요청에만 `X-Curator-Authenticated: 1`을 주입합니다.
4. Dart 서버에 `CURATOR_TRUSTED_AUTH_HEADER=X-Curator-Authenticated`를 설정합니다. 이 모드는 loopback bind에서만 허용됩니다.
5. `CURATOR_CORS_ALLOW_ORIGIN` 는 실제 Web origin만 쉼표로 구분해 지정합니다. 예: `https://curator.example.com,https://admin.example.com`.

`CURATOR_PROXY_TOKEN`은 서버-서버 또는 OS 안전 저장소를 사용하는 통제된 네이티브 호출을 위한 대안 인증입니다. **공개 Flutter Web의 소스, `--dart-define`, JavaScript 번들에 이 토큰을 넣지 마세요.** Web은 same-origin reverse proxy의 사용자 세션과 내부 헤더/토큰 주입을 사용해야 합니다.

### 4.3 서버 환경변수

OCR은 Google API를 사용하지 않으며 키가 필요 없습니다. `CURATOR_TESSERACT_BIN`(기본 `tesseract`)과 `CURATOR_OCR_LANGUAGE`(기본 `eng`)를 선택적으로 지정합니다. 엔진 또는 언어 데이터가 없으면 `/ready`와 OCR endpoint가 `503`을 반환합니다. 설치 후 readiness는 자동 회복하며 환경변수 변경은 백엔드 재시작이 필요합니다. 한글은 `kor` 언어 데이터를 별도 설치하고 `CURATOR_OCR_LANGUAGE=eng+kor`로 지정하세요. `.env` 자동 로드는 없습니다.

입력은 단일 프레임 JPEG/PNG, 8 MiB 및 1,600만 화소 이하입니다. 임시 입력 파일은 요청 완료/실패 시 삭제하고 외부 OCR 서버로 전송하지 않습니다. 프로세스당 OCR 동시 실행은 2개이며 초과 요청은 `429`입니다. OCR 시간 초과 시 자식 프로세스를 종료합니다. 나머지 기본값은 loopback `127.0.0.1:8787`, body 12 MiB, catalog 50개, upstream 45초, Flutter 요청 60초, IP별 분당 60회입니다.

인식 실패 `422`는 더 선명한 목록·표 이미지로 다시 시도하세요. 인식 품질은 손글씨·기울기·언어에 영향을 받으며 의미 이해 기반 Gemini와 동등한 정확도는 보장하지 않습니다. 프로덕션은 파일명에 따른 고정 샘플을 반환하지 않습니다. `DemoItemExtractionGateway`는 테스트/명시적 데모 조립에서만 사용합니다.

조정 가능한 값은 `CURATOR_TESSERACT_BIN`, `CURATOR_OCR_LANGUAGE`, `CURATOR_CORS_ALLOW_ORIGIN`, `CURATOR_PROXY_TOKEN`, `CURATOR_TRUSTED_AUTH_HEADER`, `CURATOR_ALLOW_UNAUTHENTICATED_LOOPBACK`, `CURATOR_MAX_BODY_BYTES`, `CURATOR_MAX_IMAGE_BYTES`, `CURATOR_MAX_CATALOG_ITEMS`, `CURATOR_UPSTREAM_TIMEOUT_SECONDS`, `CURATOR_RATE_LIMIT_PER_MINUTE`입니다. `/health`는 인증 없는 liveness, `/ready`는 OCR 실행 파일과 언어 데이터 확인까지 포함한 readiness이며 둘 다 비밀값을 노출하지 않습니다.

과거 소스나 Web 빌드에 포함된 API 키가 있다면 폐기하세요. 이전 `GEMINI_API_KEY`/`GEMINI_MODEL` 환경변수는 이제 읽지 않으며 설정할 필요가 없습니다.
