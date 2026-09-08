import '../models/matching_options.dart';
import 'curator_use_cases.dart';

final class MatchingServices {
  const MatchingServices(
      {required this.pipeline, required this.review, required this.rescraper});
  final CurationPipeline pipeline;
  final ProductReviewGateway review;
  final CatalogRescraper rescraper;
}

abstract interface class MatchingStrategyProvider {
  Future<List<MatchingCapability>> capabilities();
  MatchingServices servicesFor(MatchingOptions options);
}

/// Composition roots supply adapters; the BLoC knows neither HTTP nor Flutter.
final class CallbackMatchingStrategyProvider
    implements MatchingStrategyProvider {
  const CallbackMatchingStrategyProvider(
      {required this.loadCapabilities, required this.createServices});
  final Future<List<MatchingCapability>> Function() loadCapabilities;
  final MatchingServices Function(MatchingOptions) createServices;
  @override
  Future<List<MatchingCapability>> capabilities() => loadCapabilities();
  @override
  MatchingServices servicesFor(MatchingOptions options) =>
      createServices(options);
}
