import 'dart:convert';
import 'dart:typed_data';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

import 'support/test_data.dart';

void main() {
  group('header', () {
    test('reads every varint length boundary', () {
      for (final length in [
        0,
        1,
        63,
        64,
        127,
        128,
        16383,
        16384,
        2097150,
        65535,
        65536,
        4294967295,
      ]) {
        expect(
          Snappy.uncompressedLength(varint(length)),
          length,
          reason: 'length $length',
        );
      }
    });

    test('rejects truncated headers', () {
      expect(
        () => Snappy.uncompressedLength(Uint8List(0)),
        throwsFormatException,
      );
      expect(
        () => Snappy.uncompressedLength(Uint8List.fromList([0x80])),
        throwsFormatException,
      );
      expect(
        () => Snappy.uncompressedLength(Uint8List.fromList([0x80, 0x80, 0x80])),
        throwsFormatException,
      );
    });

    test('rejects lengths that do not fit in 32 bits', () {
      expect(
        () => Snappy.uncompressedLength(
          Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0x1F]),
        ),
        throwsFormatException,
      );
      expect(
        () => Snappy.uncompressedLength(
          Uint8List.fromList([0x80, 0x80, 0x80, 0x80, 0x80, 0x01]),
        ),
        throwsFormatException,
      );
    });
  });

  group('decoding vectors', () {
    test('empty stream', () {
      expect(Snappy.decompress(Uint8List.fromList([0x00])), isEmpty);
    });

    test('single short literal', () {
      final stream = block(5, [literalTag(5), 'hello'.codeUnits]);
      expect(utf8.decode(Snappy.decompress(stream)), 'hello');
    });

    test('run-length copy from the format description', () {
      final stream = block(7, [literalTag(3), 'xab'.codeUnits, copy1(4, 2)]);
      expect(utf8.decode(Snappy.decompress(stream)), 'xababab');
    });

    test('1-byte offset copy', () {
      final stream = block(5, [
        literalTag(1),
        [0x61],
        copy1(4, 1),
      ]);
      expect(utf8.decode(Snappy.decompress(stream)), 'aaaaa');
    });

    test('2-byte offset copy', () {
      final stream = block(5, [literalTag(4), 'abcd'.codeUnits, copy2(1, 4)]);
      expect(utf8.decode(Snappy.decompress(stream)), 'abcda');
    });

    test('4-byte offset copy', () {
      final stream = block(9, [literalTag(4), 'abcd'.codeUnits, copy4(5, 4)]);
      expect(utf8.decode(Snappy.decompress(stream)), 'abcdabcda');
    });

    test('copy offsets 1, 2, 3, 4, 7, 8, 15, 16 repeat correctly', () {
      for (final offset in [1, 2, 3, 4, 7, 8, 15, 16]) {
        final literal = List<int>.generate(offset, (i) => 0x41 + i);
        final stream = block(offset + 32, [
          literalTag(offset),
          literal,
          copy2(32, offset),
        ]);
        final decoded = Snappy.decompress(stream);
        expect(decoded.length, offset + 32);
        for (var i = 0; i < 32; i++) {
          expect(decoded[offset + i], literal[i % offset]);
        }
      }
    });

    test('copy-1 boundary offset 2047', () {
      final literal = literalPayload(2047);
      final stream = block(2058, [literalTag(2047), literal, copy1(11, 2047)]);
      final decoded = Snappy.decompress(stream);
      expect(decoded.length, 2058);
      expect(decoded.every((byte) => byte == 0x61), isTrue);
    });

    test('copy-2 at offset 2048', () {
      final stream = block(2052, [
        literalTag(2048),
        literalPayload(2048),
        copy2(4, 2048),
      ]);
      final decoded = Snappy.decompress(stream);
      expect(decoded.length, 2052);
      expect(decoded.every((byte) => byte == 0x61), isTrue);
    });

    test('copy-2 at offset 65535', () {
      final stream = block(65539, [
        literalTag(65535),
        literalPayload(65535),
        copy2(4, 65535),
      ]);
      final decoded = Snappy.decompress(stream);
      expect(decoded.length, 65539);
      expect(decoded.every((byte) => byte == 0x61), isTrue);
    });

    test('4-byte offset beyond 65535', () {
      final stream = block(70004, [
        literalTag(70000),
        literalPayload(70000),
        copy4(4, 70000),
      ]);
      final decoded = Snappy.decompress(stream);
      expect(decoded.length, 70004);
      expect(decoded.sublist(70000).every((byte) => byte == 0x61), isTrue);
    });

    test('literal length boundaries', () {
      for (final length in [
        1,
        15,
        16,
        59,
        60,
        61,
        62,
        63,
        64,
        65,
        255,
        256,
        257,
        1000,
        65536,
      ]) {
        final stream = block(length, [
          literalTag(length),
          literalPayload(length),
        ]);
        final decoded = Snappy.decompress(stream);
        expect(decoded.length, length, reason: 'literal length $length');
        expect(decoded.every((byte) => byte == 0x61), isTrue);
      }
    });

    test('copy-2 length boundaries', () {
      for (final length in [1, 2, 4, 63, 64]) {
        final stream = block(64 + length, [
          literalTag(64),
          literalPayload(64),
          copy2(length, 64),
        ]);
        expect(Snappy.decompress(stream).length, 64 + length);
      }
    });

    test('copy-1 length boundaries', () {
      for (final length in [4, 5, 10, 11]) {
        final stream = block(64 + length, [
          literalTag(64),
          literalPayload(64),
          copy1(length, 64),
        ]);
        expect(Snappy.decompress(stream).length, 64 + length);
      }
    });
  });

  group('exact encodings', () {
    test('empty input becomes a lone zero header', () {
      expect(Snappy.compress(Uint8List(0)), [0x00]);
    });

    test('short literal input is stored as one literal', () {
      expect(Snappy.compress(utf8.encode('hello')), [
        0x05,
        0x10,
        ...'hello'.codeUnits,
      ]);
    });

    test('inputs below the match margin are always a single literal', () {
      final source = randomBytes(10, 7);
      final compressed = Snappy.compress(source);
      expect(compressed, [10, 9 << 2, ...source]);
    });
  });
}
