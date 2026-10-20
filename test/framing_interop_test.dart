@TestOn('vm')
library;

import 'dart:io';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

/// Bidirectional cross-check of the framing format against the Rust `snap`
/// reference implementation.
///
/// Enabled by pointing `SNAPPY_ORACLE` at the `snappy-oracle` binary built from
/// `bench/rust` (CI does this); the rest of the suite runs without Rust.
void main() {
  final oracle = Platform.environment['SNAPPY_ORACLE'];
  final skip = oracle == null || oracle.isEmpty
      ? 'SNAPPY_ORACLE is not set (see bench/rust)'
      : null;

  final corpus = Directory('testdata/corpus');
  final workspace = Directory('build/interop-frames');
  final reference = Directory('${workspace.path}/reference');
  final dart = Directory('${workspace.path}/dart');

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

    final generated = Process.runSync(oracle!, [
      'gen-frame',
      '--corpus',
      corpus.path,
      '--out',
      reference.path,
    ]);
    if (generated.exitCode != 0) {
      fail(
        'snappy-oracle gen-frame failed:\n'
        '${generated.stdout}\n${generated.stderr}',
      );
    }

    for (final file in corpusFiles()) {
      final framed = SnappyFraming.compress(file.readAsBytesSync());
      File('${dart.path}/${nameOf(file)}.sz').writeAsBytesSync(framed);
    }
  });

  tearDownAll(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('Dart decodes every reference frame', () {
    for (final file in corpusFiles()) {
      final name = nameOf(file);
      final framed = File('${reference.path}/$name.sz');
      expect(framed.existsSync(), isTrue, reason: name);
      final expected = file.readAsBytesSync();
      expect(
        SnappyFraming.decompress(framed.readAsBytesSync()),
        expected,
        reason: name,
      );
    }
  }, skip: skip);

  test('the reference decodes every Dart frame', () {
    final verified = Process.runSync(oracle!, [
      'verify-frame',
      '--corpus',
      corpus.path,
      '--compressed',
      dart.path,
    ]);
    expect(
      verified.exitCode,
      0,
      reason:
          'snappy-oracle verify-frame failed:\n'
          '${verified.stdout}\n${verified.stderr}',
    );
  }, skip: skip);

  test('Dart framing is byte-identical to the reference implementation', () {
    for (final file in corpusFiles()) {
      final name = nameOf(file);
      expect(
        File('${dart.path}/$name.sz').readAsBytesSync(),
        File('${reference.path}/$name.sz').readAsBytesSync(),
        reason: name,
      );
    }
  }, skip: skip);
}
