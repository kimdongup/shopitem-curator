# 🎒 ShopItem Curator - System Architecture & Requirements (`agents.md`)

> **문서 목적**: 본 문서는 `shopitem-curator` 애플리케이션의 핵심 요구사항, BLoC 디자인 패턴 규칙, Pure Dart 비즈니스 로직과 Flutter UI 레이어 간의 완전 분리 원칙 및 4단계 큐레이션 파이프라인 구조를 정의합니다.

---

## 📌 1. 핵심 비즈니스 요구사항 (Core Requirements)

1. **입력 이미지 선택 및 물품 추출 (Image Item Extraction)**
   - `assets/images/`에 배치된 이미지(`new.jpg`, `media_1787068853075.jpg` 등)를 화면 드롭다운 메뉴에서 선택합니다.
   - 선택된 사진에서 물품 목록 및 규격을 추출합니다 (`OcrExtractorService`).

2. **쇼핑몰(Target) 상품 매칭 & 데이터 저장 (`assets/items/`)**
   - 각 추출 물품에 대해 Target 사이트의 대상 물품 이미지, 대상 구매 URL, 가격 정보를 수집하여 `assets/items/`에 구조화된 JSON 메타데이터 및 이미지 에셋으로 저장합니다 (`TargetFetcherService`).

3. **단일 캔버스 레이어 합성 (Canvas Compositor)**
   - 수집된 물품 이미지들을 하나의 통합 캔버스 레이어에 자연스럽게 배치/합성합니다 (`CanvasCompositorService`).
   - **기본 상태**: 차분한 흑백(Grayscale)으로 렌더링.

4. **1:1 정밀 윤곽선 도려내기 (Exact Silhouette Segmentation)**
   - 각 물품의 정확한 실루엣 외곽선을 다각형(Polygon) 벡터로 추출합니다 (`ContourSegmenterService`).
   - **마우스 호버 / 터치 인터랙션**: 마우스 커서가 올라가거나 터치 시 해당 물품 영역만 부드러운 애니메이션과 함께 생생한 컬러(Color)로 전환.

5. **말풍선(Speech Balloon) 가격 태그 & 구매 링크**
   - 물품을 클릭(또는 탭)하면 물품 위에 위치 기반 **말풍선 형태의 가격 태그(Price Tag Balloon)**가 등장합니다.
   - 말풍선 내부에는 **물품 이름**, **가격**, **클릭 시 바로 열리는 구매 URL 링크(Target 직링크)**가 포함됩니다.
   - 전체 기능을 **1개의 반응형 단일 화면(Single Screen)**에서 모아서 직관적으로 제공합니다.

---

## 🏛️ 2. 아키텍처 원칙: Pure Dart 와 UI의 완전 분리 (BLoC Pattern)

> [!IMPORTANT]
> **핵심 전략**: 추후 Flutter UI 레이어를 네이티브(Swift/SwiftUI, Kotlin/Jetpack Compose)로 통째로 교체할 수 있도록, **Core Business Logic은 `package:flutter`에 대한 의존성이 0%인 Pure Dart로만 작성**되어야 합니다.

### 2.1 계층 구조 및 의존성 규칙

```
┌─────────────────────────────────────────────────────────────┐
│                     Presentation Layer                      │
│                  (Flutter UI / Widgets)                     │
│  - CuratorScreen (사진 선택 메뉴, 진행 표시기, 단일 화면)     │
│  - CuratorCanvas (흑백 ➔ 컬러 전환 애니메이션 & 폴리곤 클리퍼)│
│  - SpeechBalloonTag (말풍선 가격태그 & Target 직링크 버튼)    │
└──────────────────────────────┬──────────────────────────────┘
                               │ (UI는 Core를 호출 및 Stream 구독)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                    Pure Dart Core Layer                     │
│                 (Zero Flutter Dependencies)                 │
│  - Services:                                                │
│    1. OcrExtractorService (물품 목록 추출)                  │
│    2. TargetFetcherService (Target 상품 매칭 & 저장)        │
│    3. CanvasCompositorService (단일 캔버스 레이어 합성)      │
│    4. ContourSegmenterService (1:1 정밀 윤곽선 도려내기)    │
│    5. CurationPipelineService (4단계 파이프라인 오케스트레이터)│
│  - BLoC: CuratorBloc (Events, States via Dart Streams)      │
│  - Repositories: ItemRepository (Manifest 로더)              │
│  - Domain Models: CuratorItem, CuratorPoint, CuratorManifest│
│  - Ports: ItemExtractionGateway, TargetProductGateway       │
│  - Adapter: BackendProxyGateway (인증 프록시 호출)           │
│  - *Strict Rule: No 'package:flutter/...' imports allowed*  │
└──────────────────────────────┬──────────────────────────────┘
                               │ HTTPS `/v1/*` (비밀키 없음)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                  Authenticated Server Boundary              │
│  - Tesseract 로컬 OCR (API 키·외부 OCR 통신 없음)            │
│  - 로컬 OCR 및 Target 조회/이미지 프록시 실행              │
│  - 인증, CORS allowlist, 요청 제한, Target host allowlist    │
└─────────────────────────────────────────────────────────────┘
```

Flutter 앱은 외부 OCR 또는 Target 데이터 API를 직접 호출하지 않습니다. OCR 인식은 서버의 `TesseractTextRecognizer`, 목록 해석은 Pure Dart의 `OcrExtractorService`가 담당합니다. 운영 Web은
동일 출처의 인증 reverse proxy를 사용하고, 개발 환경만 loopback 서버의 제한된
무인증 모드를 사용할 수 있습니다. Target 구매 버튼의 검증된 PDP 링크 이동은
사용자가 명시적으로 실행하는 별도 동작입니다.

---

## 📁 3. 디렉토리 구조 (Directory Structure)

### 브라우저 선택 모드 (로컬 MVP)

- 기본 로컬 조립은 `BrowserProjectGateway`를 BLoC에 주입합니다. OCR 목록을 만든 후 사용자의 상품 선택을 기다리며 Target 조회 포트를 호출하지 않습니다.
- Chrome `extension/`은 Target 페이지 위의 이동식 위젯으로 일반 검색 페이지를 열고, 사용자 클릭으로 현재 PDP URL과 직접 선택한 PNG 영역만 로컬 백엔드에 전달합니다. 쿠키/세션/상품 DOM 수집은 하지 않습니다.
- `BrowserProjectStore`는 파일별 목록·선택 결과를 `assets/.curator_projects/`에 저장합니다. 문서 삭제와 함께 해당 프로젝트·캡처도 보관 삭제하고 확장 연결 권한을 폐기합니다. 이 저장소는 공개 Git 및 Flutter 번들에 포함하지 않습니다.
- `/v1/browser-projects/*`는 기존 앱 인증을 사용합니다. `/v1/browser-bridge/*`는 loopback 전용이며 2분 일회용 코드 → 8시간 프로젝트 한정 연결 권한으로 인증합니다. 다른 앱 라우트의 인증/CORS는 완화하지 않습니다.
- 선택한 이미지는 `ManifestRebuilder`를 통해 기존 Pure Dart 합성·윤곽선 경로에 합류합니다. UI는 BLoC 이벤트/상태만 사용하며 Flutter 의존성을 Core에 추가하지 않습니다.
- 원격 배포에서 확장 연결은 아직 지원하지 않습니다. 자동 모드는 유지하되 Target 접근 제한은 별도 문제로 명시합니다.

```text
shopitem-curator/
├── agents.md                       # 요구사항 및 아키텍처 정의 (본 문서)
├── USAGE.md                        # 사용법 및 배포 가이드
├── pubspec.yaml                    # Flutter & Dart 의존성 정의
├── assets/                         # 정적 자산
│   ├── images/                     # 원본 입력 사진들 (new.jpg, media_1787068853075.jpg)
│   └── items/                      # Target 매칭 아이템 이미지 및 매니페스트
├── lib/
│   ├── main.dart                   # Flutter composition root (공개 proxy URL만)
│   ├── core/                       # [Pure Dart] 순수 비즈니스 로직 & BLoC
│   │   ├── bloc/                   # CuratorBloc, CuratorEvent, CuratorState
│   │   ├── contracts/              # UI/전송과 독립적인 application ports
│   │   ├── models/                 # CuratorItem, CuratorPoint, CuratorManifest
│   │   ├── repositories/           # ItemRepository 인터페이스 및 구현
│   │   └── services/               # 4단계 파이프라인 분리 서비스
│   │       ├── backend_proxy_gateway.dart
│   │       ├── ocr_extractor_service.dart
│   │       ├── target_fetcher_service.dart
│   │       ├── canvas_compositor_service.dart
│   │       ├── contour_segmenter_service.dart
│   │       └── curation_pipeline_service.dart
│   └── ui/                         # [Flutter UI] 프레젠테이션 레이어
│       ├── screens/                # 단일 화면 (CuratorScreen: 파일선택/진행뷰/캔버스)
│       ├── widgets/                # CuratorCanvas, SpeechBalloonTag
│       └── theme/                  # AppColors
├── server/
│   ├── tesseract_text_recognizer.dart # 로컬 프로세스/이미지 전처리 어댑터
│   └── curator_proxy_server.dart   # [Dart VM] 인증/CORS/SSRF 방어 프록시
└── test/
    ├── core_bloc_test.dart         # Pure Dart 유닛 테스트
    └── widget_test.dart            # Flutter UI 테스트
```
