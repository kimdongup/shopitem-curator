import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

enum AvifDecodeFailure { unavailable, invalidImage, oversized, busy }

final class AvifDecodeException implements Exception {
  const AvifDecodeException(this.kind);
  final AvifDecodeFailure kind;
}

abstract interface class AvifImageDecoder {
  Future<Uint8List> decodeToPng(Uint8List bytes,
      {required int maxOutputBytes, required Duration timeout});
  FutureOr<void> close();
}

/// Detect the ISO BMFF file type, including compatible (not only major) brands.
/// Scene7 may return AVIF even when the URL requests JPEG or the MIME is wrong.
bool isAvifImage(Uint8List bytes) {
  if (bytes.length < 16 ||
      bytes[4] != 0x66 ||
      bytes[5] != 0x74 ||
      bytes[6] != 0x79 ||
      bytes[7] != 0x70) {
    return false;
  }
  final size = ByteData.sublistView(bytes).getUint32(0);
  if (size < 16 || size > bytes.length || size % 4 != 0) return false;
  bool brandAt(int offset) =>
      bytes[offset] == 0x61 &&
      bytes[offset + 1] == 0x76 &&
      bytes[offset + 2] == 0x69 &&
      (bytes[offset + 3] == 0x66 || bytes[offset + 3] == 0x73);
  if (brandAt(8)) return true;
  for (var offset = 16; offset < size; offset += 4) {
    if (brandAt(offset)) return true;
  }
  return false;
}

/// Server-only native codec adapter. Core and Flutter both receive ordinary PNG
/// pixels; no Flutter/FFI dependency or cloud image conversion service is needed.
/// libavif limits decoded pixels before allocation, preserves alpha, and decodes
/// only the first frame. Jobs, threads, queue, execution time and output are bounded.
final class AvifDecImageDecoder implements AvifImageDecoder {
  AvifDecImageDecoder(
      {this.executable = 'avifdec',
      this.maxConcurrentJobs = 2,
      this.maxQueuedJobs = 32}) {
    if (executable.trim().isEmpty ||
        maxConcurrentJobs < 1 ||
        maxQueuedJobs < 0) {
      throw ArgumentError('Invalid AVIF decoder configuration.');
    }
  }

  factory AvifDecImageDecoder.fromEnvironment() => AvifDecImageDecoder(
      executable: Platform.environment['CURATOR_AVIFDEC_BIN'] ?? 'avifdec');

  final String executable;
  final int maxConcurrentJobs, maxQueuedJobs;
  final _waiting = Queue<Completer<void>>();
  final Set<Process> _processes = {};
  int _active = 0;
  bool _closed = false;

  Future<void> _acquire(Duration timeout) async {
    if (_closed) throw const AvifDecodeException(AvifDecodeFailure.unavailable);
    if (_active < maxConcurrentJobs) {
      _active++;
      return;
    }
    if (_waiting.length >= maxQueuedJobs) {
      throw const AvifDecodeException(AvifDecodeFailure.busy);
    }
    final pending = Completer<void>();
    _waiting.add(pending);
    try {
      await pending.future.timeout(timeout);
    } on TimeoutException {
      if (!_waiting.remove(pending)) _release();
      rethrow;
    }
  }

  void _release() {
    if (_waiting.isNotEmpty && !_closed) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }

  @override
  Future<Uint8List> decodeToPng(Uint8List bytes,
      {required int maxOutputBytes, required Duration timeout}) async {
    if (maxOutputBytes < 1 || timeout <= Duration.zero) throw ArgumentError();
    if (bytes.length > 8 * 1024 * 1024) {
      throw const AvifDecodeException(AvifDecodeFailure.oversized);
    }
    if (!isAvifImage(bytes)) {
      throw const AvifDecodeException(AvifDecodeFailure.invalidImage);
    }
    // The queue consumes the same budget as decoding, never an extra timeout.
    final budget = timeout < const Duration(seconds: 10)
        ? timeout
        : const Duration(seconds: 10);
    final watch = Stopwatch()..start();
    await _acquire(budget);
    Directory? temporary;
    Process? process;
    try {
      if (_closed) {
        throw const AvifDecodeException(AvifDecodeFailure.unavailable);
      }
      temporary = await Directory.systemTemp.createTemp('curator-avif-');
      final input = File('${temporary.path}/input.avif');
      final output = File('${temporary.path}/output.png');
      await input.writeAsBytes(bytes);
      if (_closed) {
        throw const AvifDecodeException(AvifDecodeFailure.unavailable);
      }
      final remaining = budget - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('AVIF decode timed out.');
      }
      try {
        process = await Process.start(executable, [
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
          input.path,
          output.path,
        ]);
      } on ProcessException {
        throw const AvifDecodeException(AvifDecodeFailure.unavailable);
      }
      _processes.add(process);
      // Drain without accumulating untrusted codec output or exposing metadata.
      final drained = Future.wait(
          [process.stdout.drain<void>(), process.stderr.drain<void>()]);
      if (_closed) process.kill(ProcessSignal.sigkill);
      final code = await process.exitCode.timeout(remaining);
      await drained;
      if (_closed) {
        throw const AvifDecodeException(AvifDecodeFailure.unavailable);
      }
      if (code != 0 || !await output.exists()) {
        throw const AvifDecodeException(AvifDecodeFailure.invalidImage);
      }
      if (await output.length() > maxOutputBytes) {
        throw const AvifDecodeException(AvifDecodeFailure.oversized);
      }
      final png = await output.readAsBytes();
      if (!_validPng(png)) {
        throw const AvifDecodeException(AvifDecodeFailure.invalidImage);
      }
      return png;
    } finally {
      if (process != null) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        _processes.remove(process);
      }
      try {
        if (temporary != null) await temporary.delete(recursive: true);
      } finally {
        _release();
      }
    }
  }

  static bool _validPng(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 33) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(8) != 13 || data.getUint32(12) != 0x49484452) {
      return false;
    }
    final width = data.getUint32(16), height = data.getUint32(20);
    return width > 0 &&
        height > 0 &&
        width <= 8192 &&
        height <= 8192 &&
        width * height <= 16000000 &&
        bytes[24] == 8;
  }

  @override
  void close() {
    _closed = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().completeError(
          const AvifDecodeException(AvifDecodeFailure.unavailable));
    }
    for (final process in _processes) {
      process.kill(ProcessSignal.sigkill);
    }
  }
}
