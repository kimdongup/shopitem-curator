/// Persisted input images. Implementations own storage and path validation;
/// callers never remove arbitrary filesystem paths.
abstract interface class SourceDocumentRepository {
  Future<List<String>> listDocuments();
  Future<List<int>> readDocument(String sourceImagePath);
  Future<String> importDocument(String filename, List<int> bytes);

  /// Removes the source and exclusively owned generated assets from the active
  /// catalog. Shared assets and the user's original picked file are preserved.
  Future<void> deleteDocument(String sourceImagePath);
}
