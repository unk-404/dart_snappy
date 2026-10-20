@TestOn('vm')
library;

import 'dart:io';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

/// Reference streams produced by the Rust `snap` crate:
///
/// ```sh
/// snappy-oracle gen       --corpus testdata/corpus --out testdata/golden
/// snappy-oracle gen-frame --corpus testdata/corpus --out testdata/golden-framed
/// ```
///
/// Committed so the interoperability check runs on machines without a Rust
/// toolchain; `test/interop_test.dart` and `test/framing_interop_test.dart`
/// cover freshly generated streams.
///
/// The sample data is development-only (it is excluded from the published
/// archive), so this file skips itself when the fixtures are absent.
void main() {
  final blockFixtures = _fixtures('testdata/golden', '.snappy');
  final level2Fixtures = _fixtures('testdata/golden-level2', '.snappy');
  final framingFixtures = _fixtures('testdata/golden-framed', '.sz');

  test('golden fixtures exist', () {
    expect(blockFixtures, isNotEmpty, reason: 'run the oracle gen step');
    expect(
      level2Fixtures,
      isNotEmpty,
      reason: 'run the C++ level 2 reference step',
    );
    expect(
      framingFixtures,
      isNotEmpty,
      reason: 'run the oracle gen-frame step',
    );
  }, skip: blockFixtures.isEmpty ? 'testdata/golden is not checked out' : null);

  for (final fixture in blockFixtures) {
    final name = fixture.uri.pathSegments.last.replaceAll('.snappy', '');
    final source = File('testdata/corpus/$name');
    test('decodes the reference block stream for $name', () {
      expect(source.existsSync(), isTrue);
      final compressed = fixture.readAsBytesSync();
      final expected = source.readAsBytesSync();
      expect(Snappy.uncompressedLength(compressed), expected.length);
      expect(Snappy.decompress(compressed), expected);
    });
  }

  for (final fixture in level2Fixtures) {
    final name = fixture.uri.pathSegments.last.replaceAll('.snappy', '');
    final source = File('testdata/corpus/$name');
    test('level 2 matches the C++ reference stream for $name', () {
      expect(source.existsSync(), isTrue);
      final golden = fixture.readAsBytesSync();
      final expected = source.readAsBytesSync();
      expect(Snappy.compress(expected, level: 2), golden);
      expect(Snappy.decompress(golden), expected);
      expect(
        golden.length,
        lessThan(File('testdata/golden/$name.snappy').lengthSync()),
        reason: 'level 2 should be denser than level 1',
      );
    });
  }

  for (final fixture in framingFixtures) {
    final name = fixture.uri.pathSegments.last.replaceAll('.sz', '');
    final source = File('testdata/corpus/$name');
    test('decodes the reference framed stream for $name', () {
      expect(source.existsSync(), isTrue);
      final framed = fixture.readAsBytesSync();
      final expected = source.readAsBytesSync();
      expect(SnappyFraming.decompress(framed), expected);
    });
  }
}

List<File> _fixtures(String path, String extension) {
  final directory = Directory(path);
  if (!directory.existsSync()) return <File>[];
  return directory
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith(extension))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}
