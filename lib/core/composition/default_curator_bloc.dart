// Pure Dart composition helper (Zero Flutter Dependencies)

import '../bloc/curator_bloc.dart';
import '../repositories/item_repository.dart';
import '../services/curation_pipeline_service.dart';
import '../services/demo_item_extraction_gateway.dart';
import '../services/target_catalog_rescraper.dart';
import '../services/target_fetcher_service.dart';

/// Creates an explicit offline demo BLoC for tests and non-Flutter demos.
///
/// Flutter production wiring lives in `lib/main.dart`, where platform resource
/// loading and a shared HTTP client are supplied explicitly.
CuratorBloc createDefaultCuratorBloc() {
  final targetFetcher = TargetFetcherService();
  final pipeline = CurationPipelineService(
    ocrService: const DemoItemExtractionGateway(),
    targetFetcherService: targetFetcher,
  );
  return CuratorBloc(
    itemRepository: const DefaultItemRepository(),
    pipelineService: pipeline,
    manifestRebuilder: pipeline,
    productReviewGateway: targetFetcher,
    catalogRescraper: TargetCatalogRescraper(targetFetcher),
    onDispose: targetFetcher.close,
  );
}
