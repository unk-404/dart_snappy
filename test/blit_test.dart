import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:snappy_neo/blit.dart';
import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

import 'support/test_data.dart';

void main() {
  group('blit Bytes API', () {
    test('round-trips a Bytes view', () {
      final source = textBytes(2000);
      final compressed = Bytes.fromUint8List(source).snappyCompress();
      expect(compressed.length, lessThan(source.length));
      expect(compressed.snappyUncompressedLength, source.length);
      expect(compressed.snappyDecompress(), source);
    });

    test('works on a sliced view without copying the payload', () {
      final backing = Uint8List(4096);
      final payload = textBytes(1000);
      backing.setRange(1000, 2000, payload);
      final view = Bytes.view(backing, 1000, 1000);

      final compressed = view.snappyCompress();
      expect(compressed.snappyDecompress(), payload);
    });

    test('recompressing decoded bytes is byte-for-byte stable', () {
      final source = textBytes(500);
      final compressed = Bytes.fromUint8List(source).snappyCompress();
      final restored = compressed.snappyDecompress();
      final again = Bytes.fromUint8List(restored).snappyCompress();
      expect(again.asUint8List(), compressed.asUint8List());
    });

    test('passes the compression level through', () {
      final source = textBytes(20000);
      final l2 = Bytes.fromUint8List(source).snappyCompress(level: 2);
      expect(l2.asUint8List(), Snappy.compress(source, level: 2));
      expect(l2.snappyDecompress(), source);
      final framed = Bytes.fromUint8List(source).snappyFrameCompress(level: 2);
      expect(framed.asUint8List(), SnappyFraming.compress(source, level: 2));
      expect(framed.snappyFrameDecompress(), source);
    });
    test('round-trips a framed stream', () {
      final source = textBytes(90000);
      final framed = Bytes.fromUint8List(source).snappyFrameCompress();
      expect(framed.length, greaterThan(10));
      expect(framed.snappyFrameDecompress(), source);
    });

    test('framed views respect the slice offsets', () {
      final backing = Uint8List(8192);
      final payload = textBytes(3000);
      backing.setRange(1000, 4000, payload);
      final view = Bytes.view(backing, 1000, 3000);
      expect(view.snappyFrameCompress().snappyFrameDecompress(), payload);
    });
  });
}
