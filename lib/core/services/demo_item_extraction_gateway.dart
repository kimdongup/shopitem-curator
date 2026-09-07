// Explicit offline fixture for demos and tests. Never used by the server.
import '../contracts/catalog_gateways.dart';
export '../contracts/catalog_gateways.dart'
    show ExtractedItemEntry, ItemExtractionGateway;

class DemoItemExtractionGateway implements ItemExtractionGateway {
  const DemoItemExtractionGateway();
  @override
  Future<List<ExtractedItemEntry>> extractItemsFromImage(String imagePath,
      {List<int>? imageBytes}) async {
    return _hardcodedItems(imagePath);
  }

  /// Hardcoded fallback / demo data matching the two known images.
  List<ExtractedItemEntry> _hardcodedItems(String imagePath) {
    if (imagePath.contains('new.jpg')) {
      return const [
        ExtractedItemEntry(
            rawName: 'Hand sanitizer',
            cleanName: 'Hand sanitizer',
            isPersonal: false,
            quantity: 1),
        ExtractedItemEntry(
            rawName: 'White Board Markers',
            cleanName: 'White Board Markers',
            isPersonal: false,
            quantity: 1),
        ExtractedItemEntry(
            rawName: 'Backpack*',
            cleanName: 'Backpack',
            isPersonal: true,
            quantity: 1),
      ];
    }
    // Default: 25 items from media_1787068853075.jpg
    return const [
      ExtractedItemEntry(
          rawName: 'Hand sanitizer',
          cleanName: 'Hand sanitizer',
          isPersonal: false,
          quantity: 2),
      ExtractedItemEntry(
          rawName: 'Wipes', cleanName: 'Wipes', isPersonal: false, quantity: 1),
      ExtractedItemEntry(
          rawName: 'Hand Soap',
          cleanName: 'Hand Soap',
          isPersonal: false,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Composition Notebook',
          cleanName: 'Composition Notebook',
          isPersonal: false,
          quantity: 2),
      ExtractedItemEntry(
          rawName: 'Folder Paper',
          cleanName: 'Folder Paper',
          isPersonal: false,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Folders',
          cleanName: 'Folders',
          isPersonal: false,
          quantity: 4),
      ExtractedItemEntry(
          rawName: 'Glue Stick',
          cleanName: 'Glue Stick',
          isPersonal: false,
          quantity: 8),
      ExtractedItemEntry(
          rawName: 'White Board Markers',
          cleanName: 'White Board Markers',
          isPersonal: false,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Pencil with Eraser',
          cleanName: 'Pencil with Eraser',
          isPersonal: false,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Eraser',
          cleanName: 'Eraser',
          isPersonal: false,
          quantity: 2),
      ExtractedItemEntry(
          rawName: 'Sharpie',
          cleanName: 'Sharpie',
          isPersonal: false,
          quantity: 2),
      ExtractedItemEntry(
          rawName: 'Construction Paper',
          cleanName: 'Construction Paper',
          isPersonal: false,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Tissue Box',
          cleanName: 'Tissue Box',
          isPersonal: false,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Backpack*',
          cleanName: 'Backpack',
          isPersonal: true,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Supplies container*',
          cleanName: 'Supplies container',
          isPersonal: true,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Pencil box/bag*',
          cleanName: 'Pencil box',
          isPersonal: true,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Scissors*',
          cleanName: 'Scissors',
          isPersonal: true,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Colored Pencils*',
          cleanName: 'Colored Pencils',
          isPersonal: true,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Crayons*',
          cleanName: 'Crayons',
          isPersonal: true,
          quantity: 2),
      ExtractedItemEntry(
          rawName: 'Markers*',
          cleanName: 'Markers',
          isPersonal: true,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Pencil Sharpener*',
          cleanName: 'Pencil Sharpener',
          isPersonal: true,
          quantity: 2),
      ExtractedItemEntry(
          rawName: 'Watercolor Paints*',
          cleanName: 'Watercolor Paints',
          isPersonal: true,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Flash cards (Addition)*',
          cleanName: 'Flash cards (Addition)',
          isPersonal: true,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Flash cards (Subtraction)*',
          cleanName: 'Flash cards (Subtraction)',
          isPersonal: true,
          quantity: 1),
      ExtractedItemEntry(
          rawName: 'Headphones*',
          cleanName: 'Headphones',
          isPersonal: true,
          quantity: 1),
    ];
  }
}
