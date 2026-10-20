import 'dart:convert';
import 'dart:typed_data';

import 'package:snappy_neo/snappy_neo.dart';
import 'package:test/test.dart';

import 'support/test_data.dart';

/// One parsed chunk of a framed stream.
class Chunk {
  Chunk(this.type, this.payload);
  final int type;
  final Uint8List payload;
}

List<Chunk> parseChunks(Uint8List framed) {
  final chunks = <Chunk>[];
  var ip = 0;
  while (ip < framed.length) {
    expect(ip + 4, lessThanOrEqualTo(framed.length), reason: 'chunk header');
    final type = framed[ip];
    final length =
        framed[ip + 1] | (framed[ip + 2] << 8) | (framed[ip + 3] << 16);
    ip += 4;
    expect(ip + length, lessThanOrEqualTo(framed.length), reason: 'chunk body');
    chunks.add(Chunk(type, Uint8List.sublistView(framed, ip, ip + length)));
    ip += length;
  }
  return chunks;
}

void expectFramedEquals(Uint8List actual, Uint8List expected, String label) {
  expect(actual.length, expected.length, reason: '$label: length');
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      fail('$label: byte $i is ${actual[i]}, expected ${expected[i]}');
    }
  }
}

void main() {
  group('crc32c', () {
    test('matches the RFC 3720 check value', () {
      expect(SnappyFraming.crc32c('123456789'.codeUnits), 0xE3069283);
    });

    test('slicing-by-8 matches the bitwise definition', () {
      // Straightforward reflected-CRC reference, one bit at a time.
      int reference(List<int> data) {
        var crc = 0xFFFFFFFF;
        for (final byte in data) {
          crc ^= byte;
          for (var bit = 0; bit < 8; bit++) {
            crc = (crc & 1) != 0 ? (0x82F63B78 ^ (crc >>> 1)) : (crc >>> 1);
          }
        }
        return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
      }

      final rng = XorShift32(99);
      for (final length in [
        0,
        1,
        2,
        3,
        7,
        8,
        9,
        15,
        16,
        17,
        31,
        32,
        1000,
        65536,
      ]) {
        final data = Uint8List(length);
        for (var i = 0; i < length; i++) {
          data[i] = rng.nextByte();
        }
        expect(
          SnappyFraming.crc32c(data),
          reference(data),
          reason: 'length $length',
        );
      }
    });
    test('known short values', () {
      expect(SnappyFraming.crc32c(Uint8List(0)), 0x00000000);
      expect(SnappyFraming.crc32c(Uint8List.fromList([0x00])), 0x527D5351);
      expect(SnappyFraming.crc32c('hello'.codeUnits), 0x9A71BB4C);
    });

    test('masking follows the Hadoop scheme', () {
      expect(SnappyFraming.maskChecksum(0x00000000), 0xA282EAD8);
      expect(SnappyFraming.maskChecksum(0xE3069283), 0xC78AB0E5);
      expect(SnappyFraming.maskChecksum(0x9A71BB4C), 0x191C1FBB);
    });

    test('stays an unsigned 32-bit value', () {
      for (final crc in [0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]) {
        expect(
          SnappyFraming.maskChecksum(crc),
          inInclusiveRange(0, 0xFFFFFFFF),
        );
      }
    });
  });

  group('stream layout', () {
    test('stream identifier is the documented ten bytes', () {
      expect(SnappyFraming.streamIdentifier, [
        0xff,
        0x06,
        0x00,
        0x00,
        0x73,
        0x4e,
        0x61,
        0x50,
        0x70,
        0x59,
      ]);
      expect(SnappyFraming.maxChunkSize, 65536);
    });

    test('empty input becomes just the identifier', () {
      final framed = SnappyFraming.compress(Uint8List(0));
      expect(framed, SnappyFraming.streamIdentifier);
      expect(SnappyFraming.decompress(framed), isEmpty);
    });

    test('a tiny literal is stored uncompressed with a known checksum', () {
      final framed = SnappyFraming.compress(
        Uint8List.fromList('hello'.codeUnits),
      );
      expect(framed, [
        ...SnappyFraming.streamIdentifier,
        0x01, // uncompressed data
        0x09, 0x00, 0x00, // chunk length: 4-byte checksum + 5 data bytes
        0xbb, 0x1f, 0x1c, 0x19, // masked CRC-32C of "hello"
        ...'hello'.codeUnits,
      ]);
      expect(SnappyFraming.decompress(framed), 'hello'.codeUnits);
    });

    test('compressible chunks are compressed, noise is stored raw', () {
      final text = SnappyFraming.compress(textBytes(150000));
      final textTypes = parseChunks(text).map((chunk) => chunk.type).toList();
      expect(textTypes.first, 0xff);
      expect(textTypes.skip(1), everyElement(0x00));
      expect(textTypes.length, 1 + (150000 + 65535) ~/ 65536);

      final noise = SnappyFraming.compress(randomBytes(150000, 7));
      final noiseTypes = parseChunks(noise).map((chunk) => chunk.type).toList();
      expect(noiseTypes.first, 0xff);
      expect(noiseTypes.skip(1), everyElement(0x01));
    });

    test('no chunk carries more than 64 KiB of uncompressed data', () {
      final framed = SnappyFraming.compress(textBytes(300000));
      for (final chunk in parseChunks(framed).skip(1)) {
        if (chunk.type == 0x01) {
          expect(chunk.payload.length - 4, lessThanOrEqualTo(65536));
        } else {
          final block = Uint8List.sublistView(chunk.payload, 4);
          expect(Snappy.uncompressedLength(block), lessThanOrEqualTo(65536));
        }
      }
    });
  });

  group('roundtrip', () {
    for (final size in [0, 1, 2, 100, 65535, 65536, 65537, 131072, 200000]) {
      test('text/$size', () {
        final source = textBytes(size);
        final framed = SnappyFraming.compress(source);
        expect(SnappyFraming.decompress(framed), source);
      });
      test('random/$size', () {
        final source = randomBytes(size, size + 3);
        final framed = SnappyFraming.compress(source);
        expect(SnappyFraming.decompress(framed), source);
      });
    }

    test('mixed shapes', () {
      for (final source in [
        zeroBytes(200000),
        ascendingBytes(70000),
        mixedBytes(180000, 11),
        jsonLikeBytes(3000),
      ]) {
        expect(
          SnappyFraming.decompress(SnappyFraming.compress(source)),
          source,
        );
      }
    });

    test('handles typed views with non-zero offsets', () {
      final backing = Uint8List(4096);
      final source = textBytes(2000);
      backing.setRange(1000, 3000, source);
      final view = Uint8List.sublistView(backing, 1000, 3000);
      final framed = SnappyFraming.compress(view);
      expect(SnappyFraming.decompress(framed), source);
    });
  });

  group('decoding tolerances', () {
    test('skippable chunks are ignored', () {
      final data = SnappyFraming.compress(textBytes(1000));
      final withSkippable = Uint8List.fromList([
        ...SnappyFraming.streamIdentifier,
        0x80,
        0x03,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03,
        ...Uint8List.sublistView(data, 10),
        0xfd,
        0x00,
        0x00,
        0x00,
      ]);
      expect(SnappyFraming.decompress(withSkippable), textBytes(1000));
    });

    test('padding chunks are ignored without inspection', () {
      final framed = Uint8List.fromList([
        ...SnappyFraming.streamIdentifier,
        0xfe,
        0x04,
        0x00,
        0x00,
        0xde,
        0xad,
        0xbe,
        0xef,
      ]);
      expect(SnappyFraming.decompress(framed), isEmpty);
    });

    test('empty data chunks are accepted', () {
      // Uncompressed chunk with no payload: length 4, checksum of empty data.
      final raw = Uint8List.fromList([
        ...SnappyFraming.streamIdentifier,
        0x01,
        0x04,
        0x00,
        0x00,
        0xd8,
        0xea,
        0x82,
        0xa2,
      ]);
      expect(SnappyFraming.decompress(raw), isEmpty);

      // Compressed chunk whose block declares zero bytes.
      final compressed = Uint8List.fromList([
        ...SnappyFraming.streamIdentifier,
        0x00,
        0x05,
        0x00,
        0x00,
        0xd8,
        0xea,
        0x82,
        0xa2,
        0x00,
      ]);
      expect(SnappyFraming.decompress(compressed), isEmpty);
    });
    test('a repeated stream identifier is ignored', () {
      final first = SnappyFraming.compress(textBytes(70000));
      final second = SnappyFraming.compress(textBytes(70000));
      final concatenated = Uint8List.fromList([...first, ...second]);
      expect(SnappyFraming.decompress(concatenated), [
        ...textBytes(70000),
        ...textBytes(70000),
      ]);
    });
  });

  group('malformed streams', () {
    final id = SnappyFraming.streamIdentifier;

    test('empty input', () {
      expect(
        () => SnappyFraming.decompress(Uint8List(0)),
        throwsFormatException,
      );
    });

    test('shorter than a chunk header', () {
      expect(
        () => SnappyFraming.decompress(Uint8List.fromList([0xff, 0x06, 0x00])),
        throwsFormatException,
      );
    });

    test('must start with the stream identifier', () {
      final framed = SnappyFraming.compress(textBytes(100));
      final withoutIdentifier = Uint8List.sublistView(framed, 10);
      expect(
        () => SnappyFraming.decompress(withoutIdentifier),
        throwsFormatException,
      );
    });

    test('wrong identifier length', () {
      expect(
        () => SnappyFraming.decompress(
          Uint8List.fromList([
            0xff,
            0x05,
            0x00,
            0x00,
            0x73,
            0x4e,
            0x61,
            0x50,
            0x70,
          ]),
        ),
        throwsFormatException,
      );
    });

    test('wrong identifier payload', () {
      final broken = Uint8List.fromList(SnappyFraming.streamIdentifier);
      broken[4] ^= 0x01;
      expect(() => SnappyFraming.decompress(broken), throwsFormatException);
    });

    test('chunk overruns the stream', () {
      expect(
        () => SnappyFraming.decompress(
          Uint8List.fromList([...id, 0x01, 0x10, 0x00, 0x00, 0x00]),
        ),
        throwsFormatException,
      );
    });

    test('uncompressed chunk shorter than its checksum', () {
      expect(
        () => SnappyFraming.decompress(
          Uint8List.fromList([...id, 0x01, 0x03, 0x00, 0x00, 1, 2, 3]),
        ),
        throwsFormatException,
      );
    });

    test('compressed chunk shorter than its checksum and block', () {
      expect(
        () => SnappyFraming.decompress(
          Uint8List.fromList([...id, 0x00, 0x04, 0x00, 0x00, 1, 2, 3, 4]),
        ),
        throwsFormatException,
      );
    });

    test('compressed chunk may not expand beyond 64 KiB', () {
      expect(
        () => SnappyFraming.decompress(
          Uint8List.fromList([
            ...id,
            0x00, 0x07, 0x00, 0x00, //
            0x00, 0x00, 0x00, 0x00, // checksum
            0x81, 0x80, 0x04, // varint 65537
          ]),
        ),
        throwsFormatException,
      );
    });

    test('uncompressed chunk may not carry more than 64 KiB', () {
      final payload = Uint8List(4 + 65537);
      final framed = Uint8List.fromList([
        ...id,
        0x01,
        (payload.length) & 0xFF,
        (payload.length >> 8) & 0xFF,
        (payload.length >> 16) & 0xFF,
        ...payload,
      ]);
      expect(() => SnappyFraming.decompress(framed), throwsFormatException);
    });

    test('checksum mismatch in a compressed chunk', () {
      final framed = SnappyFraming.compress(textBytes(1000));
      final broken = Uint8List.fromList(framed);
      broken[14] ^= 0x01; // first byte of the checksum
      expect(() => SnappyFraming.decompress(broken), throwsFormatException);
    });

    test('checksum mismatch in an uncompressed chunk', () {
      final framed = SnappyFraming.compress(
        Uint8List.fromList('hello'.codeUnits),
      );
      final broken = Uint8List.fromList(framed);
      expect(broken[10], 0x01);
      broken[14] ^= 0x01; // checksum byte
      expect(() => SnappyFraming.decompress(broken), throwsFormatException);
    });

    test('corrupted block data is rejected', () {
      final framed = SnappyFraming.compress(textBytes(5000));
      final broken = Uint8List.fromList(framed);
      // Byte 18 is inside the first compressed chunk's block payload, after the
      // four-byte checksum, so the block decoder and the CRC must both reject.
      broken[18] ^= 0xFF;
      expect(() => SnappyFraming.decompress(broken), throwsFormatException);
    });

    test('checksum verification can be skipped explicitly', () {
      final framed = SnappyFraming.compress(textBytes(4000));
      final broken = Uint8List.fromList(framed);
      broken[14] ^= 0x01; // first checksum byte of the first data chunk
      expect(() => SnappyFraming.decompress(broken), throwsFormatException);
      expect(
        SnappyFraming.decompress(broken, verifyChecksums: false),
        textBytes(4000),
      );
      // The streaming decoder honours the same flag.
      final out = BytesBuilder();
      final sink = const SnappyFramingDecoder(verifyChecksums: false)
          .startChunkedConversion(ByteConversionSink.withCallback(out.add));
      sink.add(broken);
      sink.close();
      expect(out.toBytes(), textBytes(4000));
    });
    test('reserved unskippable chunk types fail', () {
      for (final type in [0x02, 0x40, 0x7f]) {
        expect(
          () => SnappyFraming.decompress(
            Uint8List.fromList([...id, type, 0x00, 0x00, 0x00]),
          ),
          throwsFormatException,
          reason: 'type 0x${type.toRadixString(16)}',
        );
      }
    });

    test('a trailing partial chunk fails', () {
      final framed = SnappyFraming.compress(textBytes(1000));
      final truncated = Uint8List.fromList([
        ...framed.sublist(0, framed.length - 3),
        0x01,
        0x10,
      ]);
      expect(() => SnappyFraming.decompress(truncated), throwsFormatException);
    });
  });

  group('streaming encoder', () {
    Uint8List encodeInSlices(Uint8List source, int slice) {
      final out = BytesBuilder();
      final sink = const SnappyFramingEncoder().startChunkedConversion(
        ByteConversionSink.withCallback(out.add),
      );
      for (var start = 0; start < source.length; start += slice) {
        final end = start + slice < source.length
            ? start + slice
            : source.length;
        sink.add(Uint8List.sublistView(source, start, end));
      }
      sink.close();
      return out.toBytes();
    }

    test('matches the whole-buffer encoder for any input slicing', () {
      final source = textBytes(200000);
      final expected = SnappyFraming.compress(source);
      for (final slice in [1, 7, 1024, 65536, 65537, 300000]) {
        expectFramedEquals(
          encodeInSlices(source, slice),
          expected,
          'slice $slice',
        );
      }
    });

    test('emits the identifier for empty input', () {
      final out = BytesBuilder();
      final sink = const SnappyFramingEncoder().startChunkedConversion(
        ByteConversionSink.withCallback(out.add),
      );
      sink.close();
      expect(out.toBytes(), SnappyFraming.streamIdentifier);
    });

    test('add after close is a state error', () {
      final sink = const SnappyFramingEncoder().startChunkedConversion(
        ByteConversionSink.withCallback((_) {}),
      );
      sink.close();
      expect(() => sink.add([1, 2, 3]), throwsStateError);
    });

    test('isLast on addSlice closes the sink', () {
      final out = BytesBuilder();
      final sink = const SnappyFramingEncoder().startChunkedConversion(
        ByteConversionSink.withCallback(out.add),
      );
      sink.addSlice(Uint8List.fromList('hello'.codeUnits), 0, 5, true);
      expect(SnappyFraming.decompress(out.toBytes()), 'hello'.codeUnits);
      expect(() => sink.add([0]), throwsStateError);
    });

    test('works through Stream.transform', () async {
      final source = textBytes(130000);
      final pieces = <List<int>>[
        for (var start = 0; start < source.length; start += 4096)
          Uint8List.sublistView(
            source,
            start,
            start + 4096 < source.length ? start + 4096 : source.length,
          ),
      ];
      final framed = await Stream<List<int>>.fromIterable(pieces)
          .transform(const SnappyFramingEncoder())
          .expand((chunk) => chunk)
          .toList();
      expect(SnappyFraming.decompress(Uint8List.fromList(framed)), source);
    });
  });

  group('streaming decoder', () {
    Uint8List decodeInSlices(Uint8List framed, int slice) {
      final out = BytesBuilder();
      final sink = const SnappyFramingDecoder().startChunkedConversion(
        ByteConversionSink.withCallback(out.add),
      );
      for (var start = 0; start < framed.length; start += slice) {
        final end = start + slice < framed.length
            ? start + slice
            : framed.length;
        sink.add(Uint8List.sublistView(framed, start, end));
      }
      sink.close();
      return out.toBytes();
    }

    test('decodes for any input slicing', () {
      final source = mixedBytes(160000, 3);
      final framed = SnappyFraming.compress(source);
      for (final slice in [1, 3, 64, 4096, 65540]) {
        expectFramedEquals(
          decodeInSlices(framed, slice),
          source,
          'slice $slice',
        );
      }
    });

    test('roundtrip through both streaming sides', () {
      final source = jsonLikeBytes(5000);
      final encoded = BytesBuilder();
      final encoder = const SnappyFramingEncoder().startChunkedConversion(
        ByteConversionSink.withCallback(encoded.add),
      );
      encoder.add(source);
      encoder.close();

      final decoded = BytesBuilder();
      final decoder = const SnappyFramingDecoder().startChunkedConversion(
        ByteConversionSink.withCallback(decoded.add),
      );
      decoder.add(encoded.toBytes());
      decoder.close();
      expect(decoded.toBytes(), source);
    });

    test('close with a partial chunk fails', () {
      final framed = SnappyFraming.compress(textBytes(200));
      final sink = const SnappyFramingDecoder().startChunkedConversion(
        ByteConversionSink.withCallback((_) {}),
      );
      sink.add(Uint8List.sublistView(framed, 0, framed.length - 2));
      expect(sink.close, throwsFormatException);
    });

    test('close without a stream identifier fails', () {
      final sink = const SnappyFramingDecoder().startChunkedConversion(
        ByteConversionSink.withCallback((_) {}),
      );
      expect(sink.close, throwsFormatException);
    });

    test('add after close is a state error', () {
      final sink = const SnappyFramingDecoder().startChunkedConversion(
        ByteConversionSink.withCallback((_) {}),
      );
      sink.add(SnappyFraming.compress(Uint8List(0)));
      sink.close();
      expect(() => sink.add([0]), throwsStateError);
    });
  });

  group('compression level', () {
    test('level 2 frames are denser and round-trip', () {
      final source = textBytes(150000);
      final l1 = SnappyFraming.compress(source);
      final l2 = SnappyFraming.compress(source, level: 2);
      expect(l2.length, lessThanOrEqualTo(l1.length));
      expect(SnappyFraming.decompress(l2), source);
    });

    test('the streaming encoder honours the level', () {
      final source = textBytes(140000);
      final out = BytesBuilder();
      final sink = const SnappyFramingEncoder(level: 2)
          .startChunkedConversion(ByteConversionSink.withCallback(out.add));
      for (var start = 0; start < source.length; start += 3000) {
        final end = start + 3000 < source.length ? start + 3000 : source.length;
        sink.add(Uint8List.sublistView(source, start, end));
      }
      sink.close();
      expect(out.toBytes(), SnappyFraming.compress(source, level: 2));
      expect(SnappyFraming.decompress(out.toBytes()), source);
    });

    test('invalid level is rejected', () {
      expect(
        () => SnappyFraming.compress(textBytes(10), level: 9),
        throwsRangeError,
      );
    });

    test('the codec passes the level through', () {
      final source = textBytes(30000);
      const codec = SnappyFramingCodec(level: 2);
      expect(codec.encode(source), SnappyFraming.compress(source, level: 2));
      expect(codec.decode(codec.encode(source)), source);
    });

    test('the codec can skip checksum verification', () {
      final source = textBytes(8000);
      final framed = SnappyFraming.compress(source);
      final broken = Uint8List.fromList(framed)..[14] ^= 0x01;
      const codec = SnappyFramingCodec(verifyChecksums: false);
      expect(codec.decode(broken), source);
      expect(
        () => const SnappyFramingCodec().decode(broken),
        throwsFormatException,
      );
    });
  });
  group('codec', () {
    test('roundtrips through dart:convert', () {
      const codec = SnappyFramingCodec();
      final payload = textBytes(70000);
      final framed = codec.encode(payload);
      expect(framed, isA<Uint8List>());
      expect(codec.decode(framed), payload);
      expect(codec.encoder.convert(payload), framed);
      expect(codec.decoder.convert(framed), payload);
    });
  });
}
