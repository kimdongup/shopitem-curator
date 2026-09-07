import 'package:flutter/material.dart';

import '../adapters/source_document_picker.dart';
import '../theme/app_colors.dart';

class SourceDocumentMenu extends StatefulWidget {
  const SourceDocumentMenu({
    super.key,
    required this.documents,
    required this.selected,
    required this.onSelect,
    required this.onImport,
    required this.onDelete,
    required this.onRefresh,
    this.busy = false,
    this.canManage = true,
    this.pickDocument = pickSourceDocument,
  });

  final List<String> documents;
  final String selected;
  final ValueChanged<String> onSelect;
  final ValueChanged<PickedSourceDocument> onImport;
  final ValueChanged<String> onDelete;
  final VoidCallback onRefresh;
  final bool busy;
  final bool canManage;
  final SourceDocumentPicker pickDocument;

  @override
  State<SourceDocumentMenu> createState() => _SourceDocumentMenuState();
}

class _SourceDocumentMenuState extends State<SourceDocumentMenu> {
  static const _importValue = '\u0000import';
  bool _picking = false;

  Future<void> _import() async {
    if (_picking || widget.busy) return;
    setState(() => _picking = true);
    try {
      final document = await widget.pickDocument();
      if (mounted && document != null) widget.onImport(document);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('문서를 열지 못했습니다. 8 MiB 이하의 JPEG 또는 PNG를 선택하세요.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _confirmDelete(String path) async {
    // Dismiss only the open dropdown before displaying a separate confirmation.
    Navigator.of(context).pop();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('문서와 에셋 삭제'),
              content: Text('${path.split('/').last} 문서를 삭제할까요?\n\n'
                  '앱에 저장된 문서 원본과 전용 매니페스트·캔버스·상품 에셋이 목록에서 제거됩니다. '
                  '공유 에셋과 파일 선택 전의 원본 파일은 보존됩니다.\n\n'
                  '삭제 파일은 서버의 에셋 휴지통에서 복구할 수 있습니다.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('취소')),
                FilledButton(
                    key: const Key('confirm_document_delete'),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('삭제')),
              ],
            ));
    if (mounted && confirmed == true && !widget.busy) widget.onDelete(path);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.busy || _picking;
    final values = [...widget.documents, if (widget.canManage) _importValue];
    return Container(
      constraints: const BoxConstraints(maxWidth: 620),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accentCyan.withAlpha(80)),
      ),
      child: Row(children: [
        const Icon(Icons.folder_open, size: 18, color: AppColors.accentCyan),
        const SizedBox(width: 10),
        Expanded(
            child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
          key: const Key('source_document_dropdown'),
          isExpanded: true,
          value: widget.documents.contains(widget.selected)
              ? widget.selected
              : null,
          hint: const Text('문서 선택 / 새 문서 추가', overflow: TextOverflow.ellipsis),
          dropdownColor: AppColors.surface,
          style: const TextStyle(fontSize: 13, color: AppColors.accentCyan),
          selectedItemBuilder: (context) => values
              .map((path) => Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        path == _importValue
                            ? '새 문서 추가…'
                            : path.split('/').last,
                        overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          items: values.map((path) {
            if (path == _importValue) {
              return const DropdownMenuItem(
                  value: _importValue,
                  child: Row(children: [
                    Icon(Icons.add, size: 18),
                    SizedBox(width: 8),
                    Text('새 문서 추가…'),
                  ]));
            }
            return DropdownMenuItem(
                value: path,
                child: Row(children: [
                  Expanded(
                      child: Text(path.split('/').last,
                          overflow: TextOverflow.ellipsis)),
                  if (widget.canManage)
                    IconButton(
                      key: ValueKey('delete_document_$path'),
                      tooltip: '${path.split('/').last} 삭제',
                      onPressed: disabled ? null : () => _confirmDelete(path),
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.redAccent, size: 20),
                    ),
                ]));
          }).toList(),
          onChanged: disabled
              ? null
              : (path) {
                  if (path == _importValue) {
                    _import();
                  } else if (path != null && path != widget.selected) {
                    widget.onSelect(path);
                  }
                },
        ))),
        if (disabled)
          const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)))
        else if (widget.canManage)
          IconButton(
              key: const Key('refresh_documents'),
              tooltip: '문서 목록 새로고침',
              onPressed: widget.onRefresh,
              icon: const Icon(Icons.refresh, size: 20)),
      ]),
    );
  }
}
