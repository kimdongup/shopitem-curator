/// Immutable, transport-neutral snapshot of a browser-assisted shopping list.
final class BrowserProject {
  BrowserProject(
      {required this.id,
      required this.sourceImagePath,
      required this.revision,
      required List<BrowserProjectEntry> entries})
      : entries = List.unmodifiable(entries);

  final String id;
  final String sourceImagePath;
  final int revision;
  final List<BrowserProjectEntry> entries;
  int get selectedCount => entries.where((e) => e.status == 'selected').length;
  int get pendingCount => entries.where((e) => e.status == 'pending').length;

  factory BrowserProject.fromJson(Map<String, dynamic> json) => BrowserProject(
      id: json['id'] as String,
      sourceImagePath: json['source_image_path'] as String,
      revision: json['revision'] as int,
      entries: (json['entries'] as List)
          .map((e) =>
              BrowserProjectEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList());

  Map<String, Object?> toJson() => {
        'id': id,
        'source_image_path': sourceImagePath,
        'revision': revision,
        'entries': entries.map((e) => e.toJson()).toList()
      };
}

final class BrowserProjectEntry {
  const BrowserProjectEntry(
      {required this.id,
      required this.query,
      this.quantity = 1,
      this.isPersonal = false,
      this.status = 'pending',
      this.name = '',
      this.targetUrl = '',
      this.price = 0,
      this.imageVersion = '',
      this.operationId = ''});
  final String id;
  final String query;
  final int quantity;
  final bool isPersonal;
  final String status;
  final String name;
  final String targetUrl;

  /// Zero means unknown, never a promise that the product is free.
  final double price;
  final String imageVersion;
  final String operationId;

  factory BrowserProjectEntry.fromJson(Map<String, dynamic> j) =>
      BrowserProjectEntry(
          id: j['id'] as String,
          query: j['query'] as String,
          quantity: j['quantity'] as int,
          isPersonal: j['is_personal'] as bool,
          status: j['status'] as String,
          name: j['name'] as String,
          targetUrl: j['target_url'] as String,
          price: (j['price'] as num).toDouble(),
          imageVersion: j['image_version'] as String,
          operationId: j['operation_id'] as String);

  Map<String, Object?> toJson() => {
        'id': id,
        'query': query,
        'quantity': quantity,
        'is_personal': isPersonal,
        'status': status,
        'name': name,
        'target_url': targetUrl,
        'price': price,
        'image_version': imageVersion,
        'operation_id': operationId
      };
}
