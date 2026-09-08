import 'package:flutter/material.dart';
import '../../core/bloc/curator_bloc.dart';
import '../../core/bloc/curator_event.dart';
import '../../core/bloc/curator_state.dart';
import '../../core/models/matching_options.dart';

/// Presentation only: flags and execution decisions belong to the BLoC.
class MatchingStrategyPanel extends StatelessWidget {
  const MatchingStrategyPanel(
      {super.key, required this.bloc, required this.state});
  final CuratorBloc bloc;
  final CuratorLoadedState state;

  @override
  Widget build(BuildContext context) {
    final busy = state.documentOperationInProgress ||
        state.isRescraping ||
        state.reviewStatus == ReviewStatus.loading ||
        state.urlInspectionStatus == UrlInspectionStatus.loading;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('자동 매칭 전략 · 개별 / 조합 선택',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                  '체크하지 않으면 기본 HTTP 조회입니다. 어떤 전략도 접근 허용이나 403 해소를 보장하지 않습니다. '
                  '401/403은 중지하며, 설정 변경으로 중지 상태를 초기화하지 않습니다.'),
              for (final strategy in MatchingStrategy.values)
                Builder(builder: (context) {
                  final capability = state.matchingCapabilities
                      .where((c) => c.strategy == strategy)
                      .firstOrNull;
                  final selected = state.matchingOptions.has(strategy);
                  return CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(strategy.title),
                      subtitle: Text(
                          '${strategy.description}\n${capability?.reason ?? '전략 상태를 새로고침하세요.'}'),
                      value: selected,
                      onChanged: busy ||
                              (!(capability?.available ?? false) && !selected)
                          ? null
                          : (value) => bloc.add(SetMatchingStrategyEvent(
                              strategy, value ?? false)));
                }),
              if (state.matchingStatus.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(state.matchingStatus)),
              Wrap(spacing: 12, runSpacing: 8, children: [
                FilledButton.icon(
                    onPressed: busy ||
                            state.selectedSourceImage.isEmpty ||
                            state.matchingOptions.enabled.any((s) => !state
                                .matchingCapabilities
                                .any((c) => c.strategy == s && c.available))
                        ? null
                        : () => bloc.add(const RunMatchingEvent()),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('자동 매칭 실행')),
                TextButton.icon(
                    onPressed: busy
                        ? null
                        : () =>
                            bloc.add(const RefreshMatchingCapabilitiesEvent()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('전략 상태 새로고침')),
              ]),
            ])));
  }
}
