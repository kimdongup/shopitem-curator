import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shopitem_curator/core/models/matching_options.dart';
import 'package:shopitem_curator/core/services/scraper/target_request_policy.dart';
import 'matching_http_client.dart';

/// One isolated browser process per navigation; never attaches to user Chrome.
final class MatchingBrowserRuntime {
  MatchingBrowserRuntime(
      {required this.executable,
      this.node = 'node',
      this.script = 'server/browser/runner.cjs'});
  final String executable;
  final String node;
  final String script;
  final Set<Process> _processes = {};
  Future<Map<String, dynamic>>? _probe;
  bool _closed = false;
  int _active = 0;
  Future<Map<String, dynamic>> probe() => _probe ??=
      _invoke({'executable': executable}, probe: true).catchError((Object _) =>
          <String, dynamic>{'available': false, 'chrome_version': ''});

  Future<Map<String, dynamic>> render(Map<String, Object?> config) async {
    // Bound browser memory across simultaneous app clients, rather than
    // launching a browser for every item in an unbounded work queue.
    if (_closed || _active >= 1) {
      throw const TargetLookupException(TargetLookupFailure.rateLimited);
    }
    _active++;
    try {
      return await _invoke({...config, 'executable': executable});
    } finally {
      _active--;
    }
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> config,
      {bool probe = false}) async {
    if (_closed) throw StateError('Browser runtime is closed.');
    final process = await Process.start(node, [script, if (probe) '--probe'],
        includeParentEnvironment: false,
        environment: {
          for (final name in ['PATH', 'HOME', 'TMPDIR', 'LANG'])
            if (Platform.environment[name] != null)
              name: Platform.environment[name]!,
        });
    _processes.add(process);
    if (_closed) process.kill();
    final output = <int>[];
    final outputDone = Completer<void>();
    var overflow = false;
    final limit = probe ? 8192 : 4 * 1024 * 1024;
    final read = process.stdout.listen((chunk) {
      if (output.length + chunk.length > limit) {
        overflow = true;
        process.kill();
      } else {
        output.addAll(chunk);
      }
    }, onDone: outputDone.complete, onError: outputDone.completeError);
    final errors = process.stderr
        .listen((_) {}); // Never expose profile paths or proxy credentials.
    try {
      process.stdin.write(jsonEncode(config));
      await process.stdin.close();
      final exit =
          await process.exitCode.timeout(Duration(seconds: probe ? 6 : 16));
      await outputDone.future;
      if (exit != 0 || output.isEmpty || overflow) {
        throw StateError('Browser operation failed.');
      }
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(output)) as Map);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
      throw const TargetLookupException(TargetLookupFailure.timeout);
    } finally {
      _processes.remove(process);
      await read.cancel();
      await errors.cancel();
    }
  }

  void close() {
    _closed = true;
    for (final process in _processes) {
      process.kill();
    }
  }
}

final class MatchingBrowserClient extends http.BaseClient {
  MatchingBrowserClient(
      {required this.runtime,
      required this.options,
      required this.accessState,
      this.proxies = const []});
  final MatchingBrowserRuntime runtime;
  final MatchingOptions options;
  final TargetAccessState accessState;
  final List<MatchingProxy> proxies;
  int _index = 0;
  bool _closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed ||
        request.method != 'GET' ||
        !MatchingHttpClient.allowed(request.url)) {
      throw const TargetLookupException(TargetLookupFailure.invalidResponse);
    }
    final result = await runtime.render({
      'url': request.url.toString(),
      'headers': request.headers,
      'rotate_headers': options.has(MatchingStrategy.headerRotation),
      'interaction': options.has(MatchingStrategy.browserInteraction),
      'stealth': options.has(MatchingStrategy.stealthBrowser),
      'observe_json': options.has(MatchingStrategy.observedJson),
      'denied_hosts': {
        ...accessState.deniedHosts,
        ...accessState.rateLimitedHosts,
        for (final entry in accessState.retryAt.entries)
          if (DateTime.now().isBefore(entry.value)) entry.key
      }.toList(),
      'timeout_ms': 12000,
      if (proxies.isNotEmpty)
        'proxy': proxies[_index++ % proxies.length].browserJson(),
    });
    final status = result['status'];
    if (status is! int ||
        status < 100 ||
        status > 599 ||
        result['html'] is! String) {
      throw const TargetLookupException(TargetLookupFailure.invalidResponse);
    }
    final deniedHost = result['denied_host'];
    if (deniedHost is String &&
        [
          'target.com',
          'www.target.com',
          'redsky.target.com',
          'target.scene7.com'
        ].contains(deniedHost)) {
      TargetRequestPolicy(accessState: accessState).inspectResponse(
          Uri.https(deniedHost),
          http.Response('', status, headers: {
            if (result['retry_after'] is String &&
                (result['retry_after'] as String).isNotEmpty)
              'retry-after': result['retry_after'] as String
          }));
    }
    if (status == 504) {
      throw const TargetLookupException(TargetLookupFailure.timeout);
    }
    final bytes = utf8.encode(result['html'] as String);
    if (bytes.length > 3 * 1024 * 1024) {
      throw const TargetLookupException(TargetLookupFailure.invalidResponse);
    }
    return http.StreamedResponse(Stream.value(bytes), status,
        request: request,
        headers: {'content-type': 'text/html; charset=utf-8'},
        contentLength: bytes.length);
  }

  @override
  void close() {
    _closed = true;
  }
}
