import '../models/browser_project.dart';
import '../models/curator_item.dart';

/// Human-selected products. This port never searches or downloads from Target.
abstract interface class BrowserProjectGateway {
  Future<BrowserProject> openBrowserProject(String sourceImagePath);
  Future<BrowserProject> refreshBrowserProject(String projectId);
  Future<String> pairBrowserProject(String projectId);
  Future<CuratorManifest> readBrowserSelection(BrowserProject project);
}
