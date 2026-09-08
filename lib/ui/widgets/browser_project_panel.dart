import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/bloc/curator_state.dart';

/// Presentation only: pairing, persistence and composition live behind BLoC.
class BrowserProjectPanel extends StatelessWidget {
  const BrowserProjectPanel(
      {super.key,
      required this.state,
      required this.onPair,
      required this.onRefresh,
      required this.onApply});
  final CuratorLoadedState state;
  final VoidCallback onPair;
  final VoidCallback onRefresh;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final project = state.browserProject!;
    final busy = state.browserBusy ||
        state.isRescraping ||
        state.documentOperationInProgress;
    return Container(
        constraints: const BoxConstraints(maxWidth: 780),
        padding: const EdgeInsets.all(18),
        margin: const EdgeInsets.only(bottom: 20),
        decoration: BoxDecoration(
            color: const Color(0xFF182532),
            borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('브라우저에서 직접 고르기',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Chrome에 extension 폴더를 설치한 뒤 Target 탭에서 확장 아이콘을 누르세요. '
              '연결 코드를 입력하면 페이지 위의 이동식 Curator 버튼으로 한 품목씩 검색하고 담을 수 있습니다. '
              'Target 로그인이나 서버 검색 API는 사용하지 않습니다. '
              '확장 팝업의 서버 주소에는 현재 앱 주소(로컬은 http://127.0.0.1:8787)를 입력하세요.'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                onPressed: busy ? null : onPair,
                icon: const Icon(Icons.link),
                label: const Text('확장 프로그램 연결 코드')),
            OutlinedButton.icon(
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('선택 내용 새로고침')),
            FilledButton(
                onPressed: busy || project.selectedCount == 0 ? null : onApply,
                child: Text('선택 결과 적용 (${project.selectedCount})')),
          ]),
          if (state.browserPairingCode case final String code) ...[
            const SizedBox(height: 10),
            const Text('일회용 코드 · 발급 후 2분 · 프로젝트 하나에만 연결'),
            SelectableText(code,
                style: const TextStyle(fontFamily: 'monospace')),
            TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('연결 코드를 복사했습니다.')));
                  }
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('코드 복사')),
          ],
          if (state.browserMessage case final String message)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(message)),
          Text(
              '담음 ${project.selectedCount} / 전체 ${project.entries.length} · 미선택 ${project.pendingCount}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final entry in project.entries)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(
                      switch (entry.status) {
                        'selected' => Icons.check_circle,
                        'skipped' => Icons.skip_next,
                        _ => Icons.radio_button_unchecked
                      },
                      size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('${entry.query} × ${entry.quantity}'
                          '${entry.status == 'selected' ? ' → ${entry.name}' : entry.status == 'skipped' ? ' · 건너뜀' : ''}')),
                ])),
          const SizedBox(height: 8),
          const Text(
              '일부만 담아도 적용할 수 있습니다. 빠진 품목은 캔버스에 추가되지 않습니다. '
              '상품 변경은 Target의 위젯에서 목록 항목을 다시 선택해 담으세요. 가격은 직접 입력하며 구매 전 재확인이 필요합니다.',
              style: TextStyle(fontSize: 12)),
        ]));
  }
}
