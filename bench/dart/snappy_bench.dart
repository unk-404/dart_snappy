/// Benchmarks for the pure Dart Snappy block format.
///
/// Run through the `benchmark_test` CLI from the repository root:
///
/// ```sh
/// dart run benchmark_test --output jsonl -c jit bench/dart/snappy_bench.dart
/// dart run benchmark_test --output jsonl -c aot bench/dart/snappy_bench.dart
/// ```
///
/// The corpus is read exactly once, in `setUpAll`, before any sampling starts:
/// benchmark bodies only call [Snappy.compress] / [Snappy.decompress]. Every
/// result is stored in [_sink], a top-level variable, so the VM cannot prove the
/// work is dead and eliminate it.
///
/// Each `group(...)`/`benchmark(...)` pair becomes a `benchmark_test` result
/// named `"<direction> <basename>"` (for example `"compress html"`), which
/// `tool/bench_report.dart` turns into the canonical `compress/html` row.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

/// Corpus files, in the fixed order used by the report and the Rust oracle.
const _corpusFiles = <String>[
  'alice29.txt',
  'asyoulik.txt',
  'fireworks.jpeg',
  'geo.protodata',
  'html',
  'kppkn.gtb',
  'paper-100k.pdf',
];

/// Corpus location relative to the repository root (the CLI working directory).
const _corpusDir = 'testdata/corpus';

/// Time each benchmark is measured for.
const _minDuration = Duration(seconds: 2);

/// Time each benchmark is warmed up for before measurement starts.
///
/// The default (`Duration.zero`, one sample) leaves the JIT cold for
/// millisecond-scale bodies; a short fixed window lets the VM tier up first.
const _warmupMinDuration = Duration(milliseconds: 200);

/// Last benchmark result, kept so the timed work is observable to the VM.
Object? _sink;

void main() {
  late final Map<String, Uint8List> corpus;
  late final Map<String, Uint8List> compressed;
  late final Map<String, Uint8List> framed;
  late final Map<String, Uint8List> encodeScratch;
  late final Map<String, Uint8List> decodeScratch;
  const encoder = SnappyEncoder();
  const decoder = SnappyDecoder();

  setUpAll(() {
    corpus = _readCorpus();
    compressed = {
      for (final entry in corpus.entries)
        entry.key: Snappy.compress(entry.value),
    };
    framed = {
      for (final entry in corpus.entries)
        entry.key: SnappyFraming.compress(entry.value),
    };
    // Caller-owned buffers, reused across iterations: this is the fast path a
    // server would use and the like-for-like comparison with the Rust oracle,
    // which also reuses its buffers.
    encodeScratch = {
      for (final entry in corpus.entries)
        entry.key: Uint8List(Snappy.maxCompressedLength(entry.value.length)),
    };
    decodeScratch = {
      for (final entry in corpus.entries)
        entry.key: Uint8List(entry.value.length),
    };
    // Cheap one-time sanity check: the decompress benchmarks must restore the
    // exact corpus bytes the compress benchmarks started from.
    for (final name in _corpusFiles) {
      final restored = Snappy.decompress(compressed[name]!);
      if (!_sameBytes(restored, corpus[name]!)) {
        throw StateError('Snappy roundtrip mismatch for $name');
      }
      final unpacked = SnappyFraming.decompress(framed[name]!);
      if (!_sameBytes(unpacked, corpus[name]!)) {
        throw StateError('SnappyFraming roundtrip mismatch for $name');
      }
    }
  });

  tearDownAll(() {
    if (_sink == null) {
      throw StateError('No benchmark body ran: corpus was never compressed.');
    }
  });

  group('compress', () {
    for (final name in _corpusFiles) {
      benchmark(
        name,
        () {
          _sink = encoder.encodeInto(corpus[name]!, encodeScratch[name]!);
        },
        minDuration: _minDuration,
        warmupMinDuration: _warmupMinDuration,
      );
    }
  });

  group('decompress', () {
    for (final name in _corpusFiles) {
      benchmark(
        name,
        () {
          _sink = decoder.decodeInto(compressed[name]!, decodeScratch[name]!);
        },
        minDuration: _minDuration,
        warmupMinDuration: _warmupMinDuration,
      );
    }
  });

  group('frame-compress', () {
    for (final name in _corpusFiles) {
      benchmark(
        name,
        () {
          _sink = SnappyFraming.compress(corpus[name]!);
        },
        minDuration: _minDuration,
        warmupMinDuration: _warmupMinDuration,
      );
    }
  });

  group('frame-decompress', () {
    for (final name in _corpusFiles) {
      benchmark(
        name,
        () {
          _sink = SnappyFraming.decompress(framed[name]!);
        },
        minDuration: _minDuration,
        warmupMinDuration: _warmupMinDuration,
      );
    }
  });
}

/// Reads every corpus file into memory once.
///
/// Uses relative paths on purpose: the benchmark is always launched from the
/// repository root, on the VM and in the AOT-compiled executable alike.
Map<String, Uint8List> _readCorpus() {
  final directory = Directory(_corpusDir);
  if (!directory.existsSync()) {
    throw StateError(
      'Corpus directory "${directory.path}" not found. '
      'Run the benchmark from the repository root.',
    );
  }
  final corpus = <String, Uint8List>{};
  for (final name in _corpusFiles) {
    final file = File('${directory.path}/$name');
    if (!file.existsSync()) {
      throw StateError('Missing corpus file: ${file.path}');
    }
    corpus[name] = file.readAsBytesSync();
  }
  return corpus;
}

/// Byte-for-byte comparison; `package:collection` is not a dependency.
bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
