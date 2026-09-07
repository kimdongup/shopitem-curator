# ShopItem Curator

사진 속 쇼핑 목록을 추출하고 Target 상품과 연결한 뒤, 하나의 흑백 캔버스 위에서 물품별 컬러 호버·가격 말풍선·구매 직링크를 제공하는 Flutter 앱입니다.

## 구조

- `lib/core/`: Flutter 의존성이 없는 Pure Dart 도메인 모델, 서비스, 저장소, BLoC
- `lib/ui/`: Flutter 화면, 위젯, 플랫폼 리소스 어댑터
- `lib/main.dart`: 의존성을 조립하는 Flutter composition root
- `server/`: 로컬 Tesseract OCR·Target 호출과 이미지 전달을 담당하는 인증 경계
- `assets/items/`: 검증된 상품 이미지, 합성 캔버스, 매니페스트
- `tool/`: 매니페스트/캔버스 및 독립 HTML 생성 도구

Core는 UI 타입을 알지 못하며, UI는 BLoC 이벤트와 상태 스트림을 통해 Core와 통신합니다. 자세한 요구사항은 [`agents.md`](agents.md), 실행·복구·배포 방법은 [`usage.md`](usage.md)를 참고하세요.

## 현재 제약과 배포 상태

Target 서버용 API 사용 권한이 없는 기본 환경에서는 RedSky API를 호출하지 않습니다. 공개 HTML에서 상품을 찾지 못하면 원인을 표시하며, 저장된 샘플 카탈로그는 실시간 가격·재고가 아닙니다. `big notebook`, `shoes for running`, `bicycle`의 자동 매칭은 아직 복구되지 않았습니다. 403에 대한 브라우저 위장·세션 교체·반복 요청은 사용하지 않습니다. [검토 결과와 변경 사항](docs/target-search-review.md)을 참고하세요.

Render 배포는 사용자 요청으로 보류 중이며 예산은 0원입니다. 현재 저장소는 로컬 실행용 소스이며, 운영 인증 gateway와 컨테이너 배포 구현은 아직 없습니다. [배포 계획](deploy.md)의 운영 확장안은 별도 승인이 필요합니다.

## 빠른 시작

```bash
flutter pub get
flutter analyze
flutter test

# macOS: OCR 엔진 + Target AVIF 디코더 설치 (API 키 불필요)
brew install tesseract libavif

# 터미널 1: 로컬 OCR 백엔드
export CURATOR_CORS_ALLOW_ORIGIN='http://localhost:3000'
dart run server/curator_proxy_server.dart

# 터미널 2: localhost Web은 127.0.0.1:8787 프록시를 자동 선택
flutter run -d chrome --web-port=3000
```

VS Code/Antigravity에서는 `Curator: Proxy + Chrome` 또는 `Curator: Proxy + macOS` 복합 실행 구성을 사용하면 두 프로세스를 함께 시작할 수 있습니다. 프록시 디버그 구성은 새 login shell에서 Dart/Tesseract의 PATH를 읽고, Flutter 디버그 구성은 서버 비밀 환경변수를 제거합니다. 기존 프로세스가 개발 포트 8787을 점유하면 stale 백엔드를 재사용하지 않고 명확한 오류로 중단합니다. CLI의 `flutter run -d macos`는 Flutter 앱만 시작하므로 프록시는 별도 터미널에서 먼저 실행해야 합니다.

Chrome/macOS에서 프록시 준비 확인과 앱 실행을 한 명령으로 처리하려면 각각 `bash tool/run_dev.sh --device chrome`, `bash tool/run_dev.sh --device macos`를 사용하세요. 기존 `bash tool/run_macos_dev.sh`도 호환 wrapper로 유지됩니다. 실행기는 `/health`의 서비스 ID와 `/ready`를 확인하고, 서버 비밀을 Flutter 프로세스에서 제거하며, 자신이 시작한 프록시만 앱 종료 시 함께 정리합니다.

`Terminal → Run Task`의 `Curator: Chrome (ready)`와 `Curator: macOS (ready)`도 login shell에서 공통 실행기를 시작하는 비디버그 대안으로 유지됩니다.

로컬 Web은 `CURATOR_BACKEND_URL`을 생략해도 `http://127.0.0.1:8787`을 사용합니다. 운영 Web은 계속 현재 origin의 `/v1/*`를 사용하므로 reverse proxy 라우팅이 필요합니다.

Flutter Web/데스크톱은 Target에 직접 접속하지 않습니다. OCR, 상품 조회, 재검토, 재스크래핑 및 원격 상품 이미지는 모두 Dart 백엔드 프록시를 거칩니다. OCR은 서버 내부 Tesseract 프로세스에서 실행되며 Google API 또는 다른 외부 OCR API 호출과 API 키가 필요 없습니다. 운영 인증/CORS 구성은 [`usage.md`](usage.md)를 참고하세요.

OCR 기본 언어는 영어(`eng`)입니다. 서버 환경변수 `CURATOR_TESSERACT_BIN`(기본 `tesseract`), `CURATOR_OCR_LANGUAGE`(기본 `eng`)로 경로와 설치된 언어를 지정합니다. Linux/Render 런타임에는 `tesseract-ocr`와 `tesseract-ocr-eng` 패키지가 필요합니다. 로컬 준비 상태는 `bash tool/run_dev.sh --check`, 실제 이미지 추출은 `dart run tool/check_local_ocr.dart`로 확인합니다.

Target의 AVIF 이미지는 서버의 `libavif` (`avifdec`)로 투명도를 보존한 8-bit PNG로 변환한 뒤 기존 Pure Dart 합성·윤곽선 처리에 전달합니다. macOS/Web 모두 같은 경로를 사용하며 Google API는 필요 없습니다. Linux 런타임에는 `libavif-bin`도 설치하고 `avifdec --help`에 `--size-limit`와 `--dimension-limit`가 있는지 확인하세요. PATH에서 찾지 못하면 서버 환경에 `CURATOR_AVIFDEC_BIN`을 지정합니다. 변경 적용 후 백엔드와 Flutter 앱을 재시작하고 해당 문서의 파이프라인을 다시 실행하세요. 상세 설치·검증은 [AVIF 지원](usage.md#target-avif-이미지-지원)을 참고하세요.

목록과 `Item / Description / Quantity` 표를 좌표 기반으로 해석합니다. 인식 품질은 사진의 선명도·언어 데이터에 따라 달라지며 손글씨·복잡한 문서에서 Gemini와 동일한 정확도를 보장하지 않습니다. 실패하면 샘플 목록으로 대체하지 않고 오류를 표시합니다.

Flutter가 프록시보다 먼저 시작되면 화면에 백엔드 대기 상태를 표시하고 `/ready` GET만 최대 2초 간격으로 다시 확인합니다. 제한 시간을 넘긴 readiness 요청은 실제 전송도 취소한 뒤 다음 확인을 시작합니다. 준비되는 즉시 초기 파이프라인을 한 번 시작하며 OCR·상품 조회 POST는 자동 재전송하지 않습니다. 호환성 오류 후의 `백엔드 다시 확인`도 이미지 POST가 아니라 readiness 확인부터 다시 시작합니다.

## 문서 관리

1번 화면의 드롭다운에서 **새 문서 추가…**로 JPEG/PNG 문서를 선택할 수 있습니다(최대 8 MiB·1,600만 화소). 각 문서의 휴지통 버튼은 확인 후 서버의 원본·전용 에셋을 삭제 목록으로 이동하며, 공유 에셋은 보존합니다. 삭제 파일은 `assets/.document_trash/`에서 수동 복구할 수 있습니다.

입력 문서는 서버 `assets/images/`에 저장되며 `CURATOR_ASSETS_DIR`로 저장소를 변경할 수 있습니다. 파일 선택 전의 원본이나 Flutter 번들을 지우지는 않습니다. 기능 적용에는 백엔드와 Flutter 앱의 완전 재시작이 필요합니다. 자세한 동작과 제약은 [문서 관리 사용법](usage.md#1-1번-화면의-문서-선택추가삭제)을 참고하세요.

Git과 Flutter 번들은 검토된 두 입력 샘플과 필요한 상품 에셋만 명시적으로 포함합니다. 새 업로드·개인별 생성 결과·휴지통·독립 HTML 내보내기·`.env`는 공개 대상에서 제외합니다. 별도의 공개 샘플을 추가하려면 `.gitignore`와 `pubspec.yaml`을 함께 검토하세요.

## 생성 도구

```bash
# 로컬 상품 이미지로 합성 캔버스와 윤곽선 재생성
dart run tool/generate_curator_assets.dart --rebuild-only

# 현재 전체 매니페스트로 self-contained HTML 생성
dart run tool/export_curator_html.dart
```

기존 `python3 generate_standalone_map.py` 명령도 동일한 Dart HTML 내보내기 도구를 호출합니다.
