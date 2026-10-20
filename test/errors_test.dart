import 'dart:typed_data';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

import 'support/test_data.dart';

void main() {
  group('malformed streams', () {
    test('copy with offset zero', () {
      final stream = block(5, [
        literalTag(1),
        [0x61],
        copy1(4, 0),
      ]);
      expect(() => Snappy.decompress(stream), throwsFormatException);
    });

    test('copy before the start of the output', () {
      final stream = block(4, [copy1(4, 1)]);
      expect(() => Snappy.decompress(stream), throwsFormatException);
    });

    test('literal overruns the declared output length', () {
      final stream = block(3, [literalTag(5), 'hello'.codeUnits]);
      expect(() => Snappy.decompress(stream), throwsFormatException);
    });

    test('copy overruns the declared output length', () {
      final stream = block(8, [literalTag(4), 'abcd'.codeUnits, copy2(8, 4)]);
      expect(() => Snappy.decompress(stream), throwsFormatException);
    });

    test('truncated literal payload', () {
      final stream = block(5, [
        literalTag(5),
        [0x61],
      ]);
      expect(() => Snappy.decompress(stream), throwsFormatException);
    });

    test('truncated literal length', () {
      final stream = block(300, [
        [(59 + 2) << 2],
        [0xFF],
      ]);
      expect(() => Snappy.decompress(stream), throwsFormatException);
    });

    test('truncated copy offset', () {
      expect(
        () => Snappy.decompress(
          block(5, [
            literalTag(1),
            [0x61],
            [0x02, 0x01],
          ]),
        ),
        throwsFormatException,
      );
      expect(
        () => Snappy.decompress(
          block(5, [
            literalTag(1),
            [0x61],
            [0x03, 0x01, 0x00],
          ]),
        ),
        throwsFormatException,
      );
      expect(
        () => Snappy.decompress(
          block(5, [
            literalTag(1),
            [0x61],
            [0x01],
          ]),
        ),
        throwsFormatException,
      );
    });

    test('declared length longer than the stream', () {
      final stream = block(10, [literalTag(5), 'hello'.codeUnits]);
      expect(() => Snappy.decompress(stream), throwsFormatException);
    });

    test('trailing data after the declared output', () {
      final stream = block(5, [
        literalTag(5),
        'hello'.codeUnits,
        literalTag(1),
        [0x61],
      ]);
      expect(() => Snappy.decompress(stream), throwsFormatException);
    });

    test('literal length that does not fit in the output', () {
      final stream = block(10, [
        [(59 + 4) << 2],
        [0xFF, 0xFF, 0xFF, 0xFF],
      ]);
      expect(() => Snappy.decompress(stream), throwsFormatException);
    });

    test('empty input is not a valid stream', () {
      expect(() => Snappy.decompress(Uint8List(0)), throwsFormatException);
    });

    test('decompressInto rejects a destination that is too small', () {
      final compressed = Snappy.compress(textBytes(1000));
      expect(
        () => Snappy.decompressInto(compressed, Uint8List(999)),
        throwsArgumentError,
      );
    });
  });

  group('argument validation', () {
    test('maxCompressedLength rejects negative input', () {
      expect(() => Snappy.maxCompressedLength(-1), throwsRangeError);
    });

    test('compressInto rejects an undersized destination', () {
      final source = textBytes(1000);
      final tooSmall = Uint8List(Snappy.maxCompressedLength(source.length) - 1);
      expect(() => Snappy.compressInto(source, tooSmall), throwsArgumentError);
    });

    test('decompressInto accepts a larger destination and leaves its tail', () {
      final source = textBytes(1000);
      final compressed = Snappy.compress(source);
      final destination = Uint8List(source.length + 32)
        ..fillRange(0, source.length + 32, 0xAA);
      expect(Snappy.decompressInto(compressed, destination), source.length);
      expect(Uint8List.sublistView(destination, 0, source.length), source);
      for (var i = source.length; i < destination.length; i++) {
        expect(destination[i], 0xAA, reason: 'byte $i was over-written');
      }
    });

    test('List<int> input is accepted', () {
      final source = 'hello'.codeUnits;
      final compressed = Snappy.compress(source);
      expect(Snappy.decompress(compressed), source);
    });
  });

  group('pseudo-fuzz', () {
    test('mutated streams only ever throw FormatException', () {
      final rng = XorShift32(2468);
      final compressed = Snappy.compress(textBytes(4096));
      for (var iteration = 0; iteration < 2000; iteration++) {
        final mutated = Uint8List.fromList(compressed);
        final mutations = 1 + rng.nextUint32() % 4;
        for (var m = 0; m < mutations; m++) {
          final index = rng.nextUint32() % mutated.length;
          mutated[index] = rng.nextByte();
        }
        // Cap the declared length so a corrupted header cannot make a huge
        // allocation in the test process.
        final int declared;
        try {
          declared = Snappy.uncompressedLength(mutated);
        } on FormatException {
          continue;
        }
        if (declared > 1 << 20) continue;
        try {
          Snappy.decompress(mutated);
        } on FormatException {
          // Expected for most mutations.
        }
      }
    });
  });
}
