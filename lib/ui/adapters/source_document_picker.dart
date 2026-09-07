import 'package:file_selector/file_selector.dart';

class PickedSourceDocument {
  const PickedSourceDocument(this.filename, this.bytes);
  final String filename;
  final List<int> bytes;
}

typedef SourceDocumentPicker = Future<PickedSourceDocument?> Function();

/// Platform dialog only; persistence and document lifecycle belong to the core.
Future<PickedSourceDocument?> pickSourceDocument() async {
  final file = await openFile(acceptedTypeGroups: const [
    XTypeGroup(
        label: '문서 이미지 (JPEG, PNG)',
        extensions: ['jpg', 'jpeg', 'png'],
        uniformTypeIdentifiers: ['public.jpeg', 'public.png']),
  ]);
  if (file == null) return null;
  if (await file.length() > 8 * 1024 * 1024) {
    throw const FormatException('8 MiB 이하의 문서를 선택하세요.');
  }
  return PickedSourceDocument(file.name, await file.readAsBytes());
}
