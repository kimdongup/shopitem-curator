import 'dart:async';
import 'dart:io';
import 'curator_proxy_server.dart';
import 'curator_web_gateway.dart';

/// One supervised process owns both listeners and OCR child processes.
Future<void> main() async {
  CuratorProxyServer? proxy;
  CuratorWebGateway? gateway;
  final client = HttpClient();
  try {
    final env = Platform.environment;
    final origin = Uri.parse(
        env['CURATOR_PUBLIC_ORIGIN'] ?? env['RENDER_EXTERNAL_URL'] ?? '');
    final password = env['CURATOR_PREVIEW_PASSWORD'] ?? '';
    if (password.length < 20) {
      throw StateError(
          'Set CURATOR_PREVIEW_PASSWORD (at least 20 characters).');
    }
    // Do not let runtime env accidentally weaken the loopback/auth contract.
    proxy = CuratorProxyServer.fromPlatformEnvironment(
        config: CuratorProxyConfig(
      bindAddress: InternetAddress.loopbackIPv4,
      port: 0,
      trustedAuthHeader: CuratorWebGateway.trustedHeader,
      allowUnauthenticatedLoopback: false,
      rateLimit: 300,
    ));
    await proxy.start();
    final readiness =
        await (await client.getUrl(proxy.baseUri.resolve('/ready')))
            .close()
            .timeout(const Duration(seconds: 10));
    await readiness.drain<void>();
    if (readiness.statusCode != 200) {
      throw StateError('Local OCR readiness failed.');
    }
    gateway = CuratorWebGateway(
        publicOrigin: origin,
        upstream: proxy.baseUri,
        webDirectory: Directory(env['CURATOR_WEB_DIR'] ?? 'build/web'),
        password: password);
    await gateway.start(port: int.parse(env['PORT'] ?? '10000'));
    stdout.writeln(
        'Curator preview ready (session authentication, ephemeral storage).');
    final stopped = Completer<void>();
    final term = ProcessSignal.sigterm.watch().listen((_) {
      if (!stopped.isCompleted) stopped.complete();
    });
    final interrupt = ProcessSignal.sigint.watch().listen((_) {
      if (!stopped.isCompleted) stopped.complete();
    });
    await stopped.future;
    await term.cancel();
    await interrupt.cancel();
  } catch (_) {
    stderr.writeln(
        'Curator preview startup failed. Check password/origin, web build and OCR installation.');
    exitCode = 1;
  } finally {
    client.close(force: true);
    await gateway?.close();
    await proxy?.close();
  }
}
