import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../server/avif_image_decoder.dart';
import 'fixtures/transparent_avif.dart';

void main() {
  test('detects AVIF major/compatible brands and AVIS, rejects invalid boxes',
      () {
    final bytes = transparentLShapeAvif();
    expect(isAvifImage(bytes), isTrue);
    bytes.setRange(8, 12, 'mif1'.codeUnits);
    expect(isAvifImage(bytes), isTrue);
    bytes.setRange(16, 20, 'avis'.codeUnits);
    expect(isAvifImage(bytes), isTrue);
    bytes.setRange(16, 20, 'heic'.codeUnits);
    expect(isAvifImage(bytes), isFalse);
    expect(isAvifImage(Uint8List.sublistView(bytes, 0, 12)), isFalse);
    bytes[0] = 255;
    expect(isAvifImage(bytes), isFalse);
    expect(isAvifImage(Uint8List.fromList([137, 80, 78, 71])), isFalse);
  });

  test('missing executable has an actionable, sanitized failure', () async {
    final decoder =
        AvifDecImageDecoder(executable: '/nonexistent/private-avifdec');
    addTearDown(decoder.close);
    await expectLater(_decode(decoder), _fails(AvifDecodeFailure.unavailable));
  });

  test('invalid or oversized input is rejected before launching a process',
      () async {
    final decoder = AvifDecImageDecoder(executable: '/nonexistent/avifdec');
    addTearDown(decoder.close);
    await expectLater(
        decoder.decodeToPng(Uint8List(3),
            maxOutputBytes: 1024, timeout: const Duration(seconds: 1)),
        _fails(AvifDecodeFailure.invalidImage));
    await expectLater(
        decoder.decodeToPng(Uint8List(8 * 1024 * 1024 + 1),
            maxOutputBytes: 1024, timeout: const Duration(seconds: 1)),
        _fails(AvifDecodeFailure.oversized));
  });

  test(
      'subprocess has bounded arguments, returns PNG and removes temporary input',
      () async {
    final engine = await _fakeEngine();
    final decoder = AvifDecImageDecoder(executable: engine.path);
    addTearDown(decoder.close);
    final png = await _decode(decoder);
    expect(img.decodePng(png)!.width, 8);
    final args = await File('${engine.parent.path}/args').readAsLines();
    expect(args.take(15), [
      '--jobs',
      '2',
      '--depth',
      '8',
      '--png-compress',
      '3',
      '--size-limit',
      '16000000',
      '--dimension-limit',
      '8192',
      '--index',
      '0',
      '--',
      args[13],
      args[14]
    ]);
    expect(await File(args[13]).parent.exists(), isFalse);
  }, skip: Platform.isWindows);

  test('oversized output and non-PNG output are rejected', () async {
    final engine = await _fakeEngine();
    final decoder = AvifDecImageDecoder(executable: engine.path);
    addTearDown(decoder.close);
    await expectLater(_decode(decoder, maxOutputBytes: 8),
        _fails(AvifDecodeFailure.oversized));
    await File('${engine.parent.path}/fixture.png').writeAsBytes([1, 2, 3]);
    await expectLater(_decode(decoder), _fails(AvifDecodeFailure.invalidImage));
  }, skip: Platform.isWindows);

  test('codec failure does not expose its stderr or private file paths',
      () async {
    final engine =
        await _fakeEngine(body: 'echo private-codec-error >&2\nexit 1');
    final decoder = AvifDecImageDecoder(executable: engine.path);
    addTearDown(decoder.close);
    await expectLater(_decode(decoder), _fails(AvifDecodeFailure.invalidImage));
  }, skip: Platform.isWindows);

  test('timeout kills jobs, bounds the queue and cleans input directories',
      () async {
    final engine = await _fakeEngine(body: 'exec /bin/sleep 30');
    final decoder = AvifDecImageDecoder(
        executable: engine.path, maxConcurrentJobs: 1, maxQueuedJobs: 1);
    addTearDown(decoder.close);
    final first = expectLater(
        _decode(decoder, timeout: const Duration(seconds: 8)),
        throwsA(isA<TimeoutException>()));
    // Process startup can exceed 400ms on a busy CI/macOS host. Confirm that
    // the fake codec has actually started before testing its running job and
    // queued job, rather than accidentally testing a pre-launch timeout.
    final argsFile = File('${engine.parent.path}/args');
    final startupDeadline = DateTime.now().add(const Duration(seconds: 7));
    while (
        !await argsFile.exists() && DateTime.now().isBefore(startupDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await argsFile.exists(), isTrue, reason: 'Fake codec did not start');
    final second = expectLater(
        _decode(decoder, timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()));
    await expectLater(_decode(decoder), _fails(AvifDecodeFailure.busy));
    await Future.wait([first, second]);
    final args = await argsFile.readAsLines();
    expect(await File(args[13]).parent.exists(), isFalse);
    // Released permits can be used by a later request.
    await expectLater(
        _decode(decoder, timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()));
  }, skip: Platform.isWindows);

  test('close cancels queued work and rejects further requests', () async {
    final decoder = AvifDecImageDecoder(
        executable: (await _fakeEngine()).path, maxConcurrentJobs: 1);
    final first =
        expectLater(_decode(decoder), _fails(AvifDecodeFailure.unavailable));
    final second =
        expectLater(_decode(decoder), _fails(AvifDecodeFailure.unavailable));
    decoder.close();
    await Future.wait([first, second]);
    await expectLater(_decode(decoder), _fails(AvifDecodeFailure.unavailable));
  }, skip: Platform.isWindows);

  test('real libavif preserves RGBA and rejects truncated AVIF', () async {
    final decoder = AvifDecImageDecoder.fromEnvironment();
    addTearDown(decoder.close);
    final image = img.decodePng(await _decode(decoder))!;
    expect(image.width, 64);
    expect(image.height, 64);
    expect(image.getPixel(0, 0).a, 0);
    expect(image.getPixel(32, 16).a, 0); // L-shaped concavity
    expect(image.getPixel(16, 16).a, 255);
    expect(image.getPixel(16, 16).r, closeTo(230, 1));
    await expectLater(
        decoder.decodeToPng(
            Uint8List.sublistView(transparentLShapeAvif(), 0, 40),
            maxOutputBytes: 1024,
            timeout: const Duration(seconds: 3)),
        _fails(AvifDecodeFailure.invalidImage));
  }, skip: Platform.environment['CURATOR_TEST_AVIF'] != '1');
}

Matcher _fails(AvifDecodeFailure kind) =>
    throwsA(isA<AvifDecodeException>().having((e) => e.kind, 'kind', kind));

Future<Uint8List> _decode(AvifImageDecoder decoder,
        {int maxOutputBytes = 1024 * 1024,
        Duration timeout = const Duration(seconds: 3)}) =>
    decoder.decodeToPng(transparentLShapeAvif(),
        maxOutputBytes: maxOutputBytes, timeout: timeout);

Future<File> _fakeEngine({String? body}) async {
  final dir = await Directory.systemTemp.createTemp('curator-avif-test-');
  addTearDown(() => dir.delete(recursive: true));
  await File('${dir.path}/fixture.png')
      .writeAsBytes(img.encodePng(img.Image(width: 8, height: 8)));
  final engine = File('${dir.path}/engine');
  await engine.writeAsString('#!/bin/sh\n'
      'printf "%s\\n" "\$@" > "${dir.path}/args"\n'
      '${body ?? 'for last; do :; done\ncp "${dir.path}/fixture.png" "\$last"'}\n');
  expect((await Process.run('/bin/chmod', ['700', engine.path])).exitCode, 0);
  return engine;
}
