// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:convert';
import 'dart:typed_data';

import '../contracts/catalog_gateways.dart';
import '../contracts/curator_use_cases.dart';
import '../models/curator_item.dart';
import 'binary_resource_loader.dart';
import 'canvas_compositor_service.dart';
import 'contour_segmenter_service.dart';

/// Orchestrates the 4-step dynamic curation pipeline:
/// 1. Extract item names from image
/// 2. Fetch first matching item's image and metadata from Target
/// 3. Dynamically composite items into a single unified canvas layer
/// 4. Extract pixel-derived silhouette contours for interaction
class CurationPipelineService implements CurationPipeline, ManifestRebuilder {
  CurationPipelineService({
    required this.ocrService,
    required this.targetFetcherService,
    CanvasCompositorService? compositorService,
    ContourSegmenterService? segmenterService,
    BinaryResourceLoader? resourceLoader,
  })  : compositorService = compositorService ??
            CanvasCompositorService(resourceLoader: resourceLoader),
        segmenterService = segmenterService ?? const ContourSegmenterService();

  final ItemExtractionGateway ocrService;
  final TargetProductGateway targetFetcherService;
  final CanvasCompositorService compositorService;
  final ContourSegmenterService segmenterService;

  @override
  Future<CuratorManifest> runPipeline({
    required String sourceImagePath,
    List<int>? imageBytes,
    PipelineProgressCallback? onProgress,
  }) async {
    // Step 1: Extract item names through the injected OCR gateway.
    onProgress?.call('1단계: 사진에서 준비물 목록 추출 중...', 0.25);
    final extractedEntries = await ocrService.extractItemsFromImage(
      sourceImagePath,
      imageBytes: imageBytes,
    );

    // Step 2: Fetch Target 1st item product photos and URLs
    onProgress?.call('2단계: Target 웹사이트 검색 ➔ 1위 상품 사진 및 가격 수집 중...', 0.50);
    final targetProducts =
        await targetFetcherService.fetchTargetProducts(extractedEntries);

    // Step 3: Composite items into a single unified canvas layer
    onProgress?.call('3단계: 검색된 물품 사진들을 단일 캔버스 레이어로 자동 합성 중...', 0.75);
    final canvasResult = await compositorService.compositeItemsToCanvas(
      products: targetProducts,
      sourceImagePath: sourceImagePath,
    );

    // Step 4: Segment exact contour silhouettes
    onProgress?.call('4단계: 각 물품 1:1 정밀 윤곽선 도려내기 중...', 0.90);
    final segmentedItems =
        await segmenterService.segmentPlacedItems(canvasResult.placedItems);
    onProgress?.call('4단계: 정밀 윤곽선 및 합성 PNG 생성 완료', 1.0);

    return CuratorManifest(
      sourceImage: sourceImagePath,
      canvasImage: _pngDataUri(canvasResult.canvasPngBytes),
      canvasWidth: canvasResult.canvasWidth,
      canvasHeight: canvasResult.canvasHeight,
      items: segmentedItems,
    );
  }

  @override
  Future<CuratorManifest> rebuildManifest(CuratorManifest manifest) async {
    final approvalById = <String, bool>{
      for (final item in manifest.items) item.id: item.isApproved,
    };
    final products = manifest.items
        .map(
          (item) => TargetProductData(
            id: item.id,
            name: item.name,
            category: item.category,
            isPersonal: item.isPersonal,
            quantity: item.quantity,
            price: item.price,
            priceCurrency: item.priceCurrency,
            description: item.description,
            targetUrl: item.targetUrl,
            imageUrl: item.imageUrl,
          ),
        )
        .toList(growable: false);

    final canvasResult = await compositorService.compositeItemsToCanvas(
      products: products,
      sourceImagePath: manifest.sourceImage,
    );
    final rebuiltItems = await segmenterService.segmentPlacedItems(
      canvasResult.placedItems,
    );

    return CuratorManifest(
      sourceImage: manifest.sourceImage,
      canvasImage: _pngDataUri(canvasResult.canvasPngBytes),
      canvasWidth: canvasResult.canvasWidth,
      canvasHeight: canvasResult.canvasHeight,
      items: [
        for (final item in rebuiltItems)
          item.copyWith(isApproved: approvalById[item.id] ?? item.isApproved),
      ],
    );
  }

  static String _pngDataUri(Uint8List? bytes) {
    if (bytes == null || !_hasPngSignature(bytes)) return '';
    return 'data:image/png;base64,${base64Encode(bytes)}';
  }

  static bool _hasPngSignature(Uint8List bytes) {
    const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }
}
