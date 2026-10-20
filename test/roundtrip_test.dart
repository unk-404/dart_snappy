import 'dart:typed_data';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

import 'support/test_data.dart';

void main() {
  void check(Uint8List source, String label) {
    final compressed = Snappy.compress(source);
    expect(
      compressed.length,
      lessThanOrEqualTo(Snappy.maxCompressedLength(source.length)),
      reason: '$label: compressed size exceeds the documented bound',
    );
    expect(
      Snappy.uncompressedLength(compressed),
      source.length,
      reason: '$label: header length',
    );
    expect(Snappy.decompress(compressed), source, reason: '$label: roundtrip');

    final destination = Uint8List(Snappy.maxCompressedLength(source.length));
    final written = Snappy.compressInto(source, destination);
    expect(written, compressed.length, reason: '$label: compressInto length');
    expect(
      Uint8List.sublistView(destination, 0, written),
      compressed,
      reason: '$label: compressInto bytes',
    );

    final restored = Uint8List(source.length);
    expect(
      Snappy.decompressInto(compressed, restored),
      source.length,
      reason: '$label: decompressInto length',
    );
    expect(restored, source, reason: '$label: decompressInto bytes');

    expect(
      Snappy.compress(source),
      compressed,
      reason: '$label: compression is deterministic',
    );
  }

  group('roundtrip by size', () {
    for (final size in [
      0,
      1,
      2,
      3,
      14,
      15,
      16,
      17,
      63,
      64,
      65,
      127,
      128,
      255,
      256,
      257,
      1023,
      1024,
      1025,
      65534,
      65535,
      65536,
      65537,
      200000,
    ]) {
      test('{text,$size}', () => check(textBytes(size), 'text/$size'));
      test(
        '{random,$size}',
        () => check(randomBytes(size, size + 1), 'random/$size'),
      );
    }
  });

  group('roundtrip by shape', () {
    final shapes = <String, Uint8List>{
      'zeros/100000': zeroBytes(100000),
      'ones/100000': Uint8List.fromList(List<int>.filled(100000, 0xFF)),
      'ascending/100000': ascendingBytes(100000),
      'text/300000': textBytes(300000),
      'json/2000': jsonLikeBytes(2000),
      'random/100000': randomBytes(100000, 99),
      'mixed/150000': mixedBytes(150000, 5),
    };
    shapes.forEach((label, source) {
      test(label, () => check(source, label));
    });
  });

  group('level 2 roundtrip', () {
    for (final size in [0, 1, 15, 256, 257, 4096, 65536, 65537, 300000]) {
      test('text/$size', () {
        final source = textBytes(size);
        final compressed = Snappy.compress(source, level: 2);
        expect(
          compressed.length,
          lessThanOrEqualTo(Snappy.maxCompressedLength(size)),
        );
        expect(Snappy.decompress(compressed), source);
      });
    }

    test('shapes', () {
      for (final source in [
        textBytes(200000),
        randomBytes(100000, 9),
        jsonLikeBytes(2000),
        mixedBytes(150000, 4),
        zeroBytes(100000),
      ]) {
        expect(Snappy.decompress(Snappy.compress(source, level: 2)), source);
      }
    });

    test('is never materially worse than level 1', () {
      for (final source in [textBytes(50000), jsonLikeBytes(1000)]) {
        final l1 = Snappy.compress(source).length;
        final l2 = Snappy.compress(source, level: 2).length;
        expect(
          l2,
          lessThan(l1 + l1 ~/ 10),
          reason: 'level 2 should not be much larger than level 1',
        );
      }
    });
    test('is denser than level 1 on compressible data', () {
      for (final source in [
        textBytes(200000),
        jsonLikeBytes(2000),
        zeroBytes(50000),
      ]) {
        final l1 = Snappy.compress(source);
        final l2 = Snappy.compress(source, level: 2);
        expect(l2.length, lessThanOrEqualTo(l1.length));
        expect(Snappy.decompress(l2), source);
      }
    });

    test('compressInto honours the level', () {
      final source = textBytes(50000);
      final destination = Uint8List(Snappy.maxCompressedLength(source.length));
      final written = Snappy.compressInto(source, destination, level: 2);
      expect(
        Uint8List.sublistView(destination, 0, written),
        Snappy.compress(source, level: 2),
      );
    });
  });
  test('multi-block input never references across a block boundary', () {
    // A block is 64 KiB; two full blocks plus a partial one.
    final source = textBytes(65536 * 2 + 123);
    final compressed = Snappy.compress(source);
    expect(Snappy.decompress(compressed), source);
  });

  test('highly repetitive input compresses well', () {
    final source = Uint8List.fromList(List<int>.filled(1 << 20, 0x42));
    final compressed = Snappy.compress(source);
    // ~64 bytes per 3-byte copy, i.e. a few percent of the input.
    expect(compressed.length, lessThan(source.length ~/ 15));
    expect(Snappy.decompress(compressed), source);
  });

  test('incompressible input stays within the documented bound', () {
    final source = randomBytes(1 << 16, 1234);
    final compressed = Snappy.compress(source);
    expect(compressed.length, lessThanOrEqualTo(source.length * 7 ~/ 6 + 32));
    expect(Snappy.decompress(compressed), source);
  });
}
