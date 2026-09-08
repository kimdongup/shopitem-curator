import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Render archive ownership workaround stays in the build stage', () {
    final stages = File('Dockerfile')
        .readAsStringSync()
        .split(RegExp(r'^FROM ', multiLine: true));
    expect(stages, hasLength(4));
    expect(stages[1], contains('ENV TAR_OPTIONS=--no-same-owner'));
    expect(stages[1].indexOf('ENV TAR_OPTIONS='),
        lessThan(stages[1].indexOf('RUN git clone')));
    expect(stages.last, isNot(contains('TAR_OPTIONS')));
    expect(stages.last, isNot(contains('USER root')));
  });

  test('IDE launches proxy from login env and strips secrets from Flutter', () {
    final launch = jsonDecode(File('.vscode/launch.json').readAsStringSync())
        as Map<String, dynamic>;
    final configurations = (launch['configurations'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    final proxy = configurations.singleWhere(
      (configuration) => configuration['name'] == 'Curator Proxy Server',
    );
    expect(
      proxy['customTool'],
      r'${workspaceFolder}/tool/dart_proxy_with_login_env.sh',
    );
    expect(
      (proxy['env'] as Map<String, dynamic>).containsKey('GEMINI_API_KEY'),
      isFalse,
    );

    for (final name in ['Flutter: Chrome', 'Flutter: macOS']) {
      final flutter = configurations.singleWhere(
        (configuration) => configuration['name'] == name,
      );
      expect(
        flutter['customTool'],
        r'${workspaceFolder}/tool/flutter_without_server_secrets.sh',
      );
    }

    final proxyWrapper =
        File('tool/dart_proxy_with_login_env.sh').readAsStringSync();
    expect(proxyWrapper, contains('/bin/zsh -lic'));
    expect(proxyWrapper, isNot(contains(r'${GEMINI_API_KEY:-}')));
    final runner = File('tool/run_dev.sh').readAsStringSync();
    expect(runner, isNot(contains('GEMINI_API_KEY is missing')));
    expect(runner, contains('CURATOR_TESSERACT_BIN'));
    expect(proxyWrapper, contains('Port 8787 is already occupied'));
    expect(proxyWrapper, contains('--noproxy 127.0.0.1'));

    final flutterWrapper =
        File('tool/flutter_without_server_secrets.sh').readAsStringSync();
    expect(flutterWrapper, contains('-u GEMINI_API_KEY'));
    expect(flutterWrapper, contains('-u CURATOR_PROXY_TOKEN'));
    expect(flutterWrapper, contains('-u CURATOR_PREVIEW_PASSWORD'));
    expect(runner, contains('-u CURATOR_PREVIEW_PASSWORD'));
    expect(flutterWrapper, contains('-u CURATOR_TARGET_REDSKY_KEY'));
    expect(runner, contains('-u CURATOR_TARGET_REDSKY_KEY'));
    expect(flutterWrapper, contains('-u CURATOR_MATCHING_PROXY_POOL'));
    expect(runner, contains('-u CURATOR_MATCHING_PROXY_POOL'));
  });
}
