import 'dart:typed_data';

import 'package:blit/unsafe.dart';
import 'package:snappy_neo/snappy_neo.dart';
import 'package:snappy_neo/unsafe.dart';
import 'package:test/test.dart';

import 'support/test_data.dart';

UnsafeBytes _copyIn(Uint8List bytes) {
  final memory = UnsafeBytes.alloc(bytes.isEmpty ? 1 : bytes.length);
  memory.view(bytes.length).setRange(0, bytes.length, bytes);
  return memory;
}

void main() {
  group('UnsafeBytes block codec', () {
    test('round-trips through external memory', () {
      final source = textBytes(5000);
      final input = _copyIn(source);
      final compressed = input.snappyCompress(source.length);
      final restored = compressed.memory.snappyDecompress(compressed.length);
      try {
        expect(compressed.bytes, Snappy.compress(source));
        expect(
          compressed.memory.snappyUncompressedLength(compressed.length),
          source.length,
        );
        expect(restored.bytes, source);
        expect(restored.length, source.length);
      } finally {
        restored.free();
        compressed.free();
        input.free();
      }
    });

    test('into methods respect the explicit lengths', () {
      final source = textBytes(3000);
      final input = _copyIn(source);
      final capacity = Snappy.maxCompressedLength(source.length);
      final out = UnsafeBytes.alloc(capacity);
      final decoded = UnsafeBytes.alloc(source.length);
      try {
        final written = input.snappyCompressInto(
          source.length,
          out,
          capacity,
          level: 2,
        );
        expect(out.view(written), Snappy.compress(source, level: 2));
        expect(
          out.snappyDecompressInto(written, decoded, source.length),
          source.length,
        );
        expect(decoded.view(source.length), source);
      } finally {
        decoded.free();
        out.free();
        input.free();
      }
    });

    test('rejects a destination that is too small', () {
      final source = textBytes(1000);
      final input = _copyIn(source);
      final tiny = UnsafeBytes.alloc(8);
      try {
        expect(
          () => input.snappyCompressInto(source.length, tiny, 8),
          throwsArgumentError,
        );
      } finally {
        tiny.free();
        input.free();
      }
    });

    test('handles empty input', () {
      final input = UnsafeBytes.alloc(1);
      final compressed = input.snappyCompress(0);
      final restored = compressed.memory.snappyDecompress(compressed.length);
      try {
        expect(restored.length, 0);
        expect(compressed.bytes, Snappy.compress(Uint8List(0)));
      } finally {
        restored.free();
        compressed.free();
        input.free();
      }
    });
  });

  group('UnsafeBytes framing codec', () {
    test('round-trips a multi-chunk stream', () {
      final source = textBytes(150000);
      final input = _copyIn(source);
      final framed = input.snappyFrameCompress(source.length);
      final unpacked = framed.memory.snappyFrameDecompress(framed.length);
      try {
        expect(framed.bytes, SnappyFraming.compress(source));
        expect(unpacked.bytes, source);
        expect(unpacked.length, source.length);
      } finally {
        unpacked.free();
        framed.free();
        input.free();
      }
    });

    test('into methods and checksum skipping', () {
      final source = textBytes(70000);
      final input = _copyIn(source);
      final capacity = SnappyFraming.maxCompressedLength(source.length);
      final out = UnsafeBytes.alloc(capacity);
      final decoded = UnsafeBytes.alloc(source.length);
      try {
        final written = input.snappyFrameCompressInto(
          source.length,
          out,
          capacity,
        );
        final framed = Uint8List.fromList(out.view(written));
        expect(framed, SnappyFraming.compress(source));
        framed[14] ^= 0x01;
        final broken = _copyIn(framed);
        try {
          expect(
            () => broken.snappyFrameDecompressInto(
              framed.length,
              decoded,
              source.length,
            ),
            throwsFormatException,
          );
          expect(
            broken.snappyFrameDecompressInto(
              framed.length,
              decoded,
              source.length,
              verifyChecksums: false,
            ),
            source.length,
          );
          expect(decoded.view(source.length), source);
        } finally {
          broken.free();
        }
      } finally {
        decoded.free();
        out.free();
        input.free();
      }
    });
  });
}
