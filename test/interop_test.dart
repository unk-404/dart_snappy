@TestOn('vm')
library;

import 'dart:io';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

/// Bidirectional cross-check against the Rust `snap` reference implementation.
///
/// Enabled by pointing `SNAPPY_ORACLE` at the `snappy-oracle` binary built from
/// `bench/rust` (CI does this); the rest of the suite runs without Rust.
void main() {
  final oracle = Platform.environment['SNAPPY_ORACLE'];
  final skip = oracle == null || oracle.isEmpty
      ? 'SNAPPY_ORACLE is not set (see bench/rust)'
      : null;

  final corpus = Directory('testdata/corpus');
  final workspace = Directory('build/interop');
  final reference = Directory('${workspace.path}/reference');
  final dart = Directory('${workspace.path}/dart');
  final dartLevel2 = Directory('${workspace.path}/dart-level2');

  List<File> corpusFiles() =>
      corpus
          .listSync()
          .whereType<File>()
          .where(
            (file) =>
                !file.uri.pathSegments.last.startsWith('README') &&
                !file.uri.pathSegments.last.startsWith('LICENSE'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  String nameOf(File file) => file.uri.pathSegments.last;

  setUpAll(() {
    if (skip != null) return;
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
    reference.createSync(recursive: true);
    dart.createSync(recursive: true);
    dartLevel2.createSync(recursive: true);

    // Reference streams, one per corpus file.
    final generated = Process.runSync(oracle!, [
      'gen',
      '--corpus',
      corpus.path,
      '--out',
      reference.path,
    ]);
    if (generated.exitCode != 0) {
      fail(
        'snappy-oracle gen failed:\n${generated.stdout}\n${generated.stderr}',
      );
    }

    // Dart streams, one per corpus file (level 1 and level 2).
    for (final file in corpusFiles()) {
      final source = file.readAsBytesSync();
      File('${dart.path}/${nameOf(file)}.snappy')
          .writeAsBytesSync(Snappy.compress(source));
      File('${dartLevel2.path}/${nameOf(file)}.snappy')
          .writeAsBytesSync(Snappy.compress(source, level: 2));
    }
  });

  tearDownAll(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('Dart decodes every reference stream', () {
    for (final file in corpusFiles()) {
      final name = nameOf(file);
      final compressed = File('${reference.path}/$name.snappy');
      expect(compressed.existsSync(), isTrue, reason: name);
      final bytes = compressed.readAsBytesSync();
      final expected = file.readAsBytesSync();
      expect(Snappy.uncompressedLength(bytes), expected.length, reason: name);
      expect(Snappy.decompress(bytes), expected, reason: name);
    }
  }, skip: skip);

  test('the reference decodes every Dart stream', () {
    final verified = Process.runSync(oracle!, [
      'verify',
      '--corpus',
      corpus.path,
      '--compressed',
      dart.path,
    ]);
    expect(
      verified.exitCode,
      0,
      reason:
          'snappy-oracle verify failed:\n'
          '${verified.stdout}\n${verified.stderr}',
    );
  }, skip: skip);

  test('the reference decodes every level 2 Dart stream', () {
    final verified = Process.runSync(oracle!, [
      'verify',
      '--corpus',
      corpus.path,
      '--compressed',
      dartLevel2.path,
    ]);
    expect(
      verified.exitCode,
      0,
      reason:
          'snappy-oracle verify (level 2) failed:\n'
          '${verified.stdout}\n${verified.stderr}',
    );
  }, skip: skip);

  test('Dart output is byte-identical to the reference implementation', () {
    for (final file in corpusFiles()) {
      final name = nameOf(file);
      expect(
        File('${dart.path}/$name.snappy').readAsBytesSync(),
        File('${reference.path}/$name.snappy').readAsBytesSync(),
        reason: name,
      );
    }
  }, skip: skip);
}
