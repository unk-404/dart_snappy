import 'dart:convert';
import 'dart:typed_data';

import 'package:snappy_neo/snappy_neo.dart';

void main() {
  final source = Uint8List.fromList(utf8.encode('snappy ' * 100));

  // Block format: the most compact representation.
  final compressed = Snappy.compress(source);
  final restored = Snappy.decompress(compressed);
  print(
    'block:     ${source.length} -> ${compressed.length} -> '
    '${restored.length} bytes, roundtrip ${_same(restored, source)}',
  );

  // Framing format: chunked, checksummed, decodable incrementally.
  final framed = SnappyFraming.compress(source);
  final unpacked = SnappyFraming.decompress(framed);
  print(
    'framed:    ${source.length} -> ${framed.length} -> '
    '${unpacked.length} bytes, roundtrip ${_same(unpacked, source)}',
  );

  // Streaming: feed arbitrary slices, receive framed chunks.
  final output = BytesBuilder();
  final sink = const SnappyFramingEncoder().startChunkedConversion(
    ByteConversionSink.withCallback(output.add),
  );
  for (var start = 0; start < source.length; start += 100) {
    final end = start + 100 < source.length ? start + 100 : source.length;
    sink.add(Uint8List.sublistView(source, start, end));
  }
  sink.close();
  final streamed = output.toBytes();
  print(
    'streaming: ${streamed.length} bytes, same as framed: '
    '${_same(streamed, framed)}',
  );
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
