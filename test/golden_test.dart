import 'dart:io';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

/// Reference streams produced by the Rust `snap` crate
/// (`snappy-oracle gen --corpus testdata/corpus --out testdata/golden`).
///
/// Committed so the interoperability check runs on machines without a Rust
/// toolchain; `test/interop_test.dart` covers freshly generated streams.
void main() {
  final directory = Directory('testdata/golden');

  test('golden fixtures exist', () {
    expect(directory.existsSync(), isTrue, reason: 'run the oracle gen step');
    expect(
      directory.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.snappy'),
      ),
      isNotEmpty,
    );
  });

  for (final fixture
      in directory.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.snappy'),
      )) {
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
