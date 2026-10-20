import 'dart:convert';
import 'dart:typed_data';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

import 'support/test_data.dart';

void main() {
  group('maxCompressedLength', () {
    test('matches the reference formula', () {
      for (final length in [0, 1, 6, 60, 1000, 65536, 1 << 20]) {
        expect(Snappy.maxCompressedLength(length), 32 + length + length ~/ 6);
      }
    });

    test('is always large enough', () {
      for (final source in [
        randomBytes(1, 1),
        randomBytes(1000, 2),
        randomBytes(70000, 3),
        textBytes(100000),
      ]) {
        expect(
          Snappy.compress(source).length,
          lessThanOrEqualTo(Snappy.maxCompressedLength(source.length)),
        );
      }
    });
  });

  group('SnappyCodec', () {
    test('round-trips through dart:convert', () {
      const codec = SnappyCodec();
      final payload = utf8.encode('snappy in dart' * 100);
      final encoded = codec.encode(payload);
      expect(encoded, isA<Uint8List>());
      expect(utf8.decode(codec.decode(encoded)), 'snappy in dart' * 100);
    });

    test('exposes encoder and decoder', () {
      const codec = SnappyCodec();
      final payload = utf8.encode('codec');
      final encoded = codec.encoder.convert(payload);
      expect(codec.decoder.convert(encoded), payload);
    });
  });

  group('compression levels', () {
    test('rejects levels outside 1..2', () {
      final source = textBytes(100);
      expect(() => Snappy.compress(source, level: 0), throwsRangeError);
      expect(() => Snappy.compress(source, level: 3), throwsRangeError);
      expect(
        () => Snappy.compressInto(source, Uint8List(200), level: 0),
        throwsRangeError,
      );
    });

    test('level 2 is accepted and round-trips', () {
      final source = textBytes(10000);
      expect(Snappy.decompress(Snappy.compress(source, level: 2)), source);
    });

    test('SnappyCodec and SnappyEncoder pass the level through', () {
      final source = textBytes(20000);
      const codec = SnappyCodec(level: 2);
      expect(codec.encode(source), Snappy.compress(source, level: 2));
      expect(
        const SnappyEncoder(level: 2).convert(source),
        Snappy.compress(source, level: 2),
      );
      expect(codec.decode(codec.encode(source)), source);
    });
  });
  group('uncompressedLength', () {
    test('does not decode the body', () {
      // A header claiming 1234 bytes with no body at all.
      expect(Snappy.uncompressedLength(varint(1234)), 1234);
    });

    test('agrees with decompress', () {
      final source = textBytes(5000);
      expect(Snappy.uncompressedLength(Snappy.compress(source)), 5000);
    });
  });
}
