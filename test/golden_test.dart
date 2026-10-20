@TestOn('vm')
library;

import 'dart:io';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

/// Reference streams produced by the Rust `snap` crate
/// (`snappy-oracle gen --corpus testdata/corpus --out testdata/golden`).
///
/// Committed so the interoperability check runs on machines without a Rust
/// toolchain; `test/interop_test.dart` covers freshly generated streams.
///
/// The sample data is development-only (it is excluded from the published
/// archive), so this file skips itself when the fixtures are absent.
void main() {
  final directory = Directory('testdata/golden');
  final fixtures = directory.existsSync()
      ? directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.snappy'))
            .toList()
      : <File>[];

  test('golden fixtures exist', () {
    expect(fixtures, isNotEmpty, reason: 'run the oracle gen step');
  }, skip: fixtures.isEmpty ? 'testdata/golden is not checked out' : null);

  for (final fixture in fixtures) {
    final name = fixture.uri.pathSegments.last.replaceAll('.snappy', '');
    final source = File('testdata/corpus/$name');
    test('decodes the reference stream for $name', () {
      expect(source.existsSync(), isTrue);
      final compressed = fixture.readAsBytesSync();
      final expected = source.readAsBytesSync();
      expect(Snappy.uncompressedLength(compressed), expected.length);
      expect(Snappy.decompress(compressed), expected);
    });
  }
}
