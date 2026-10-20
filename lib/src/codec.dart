/// A `dart:convert` [Codec] for the Snappy block format.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'snappy.dart';

/// Encodes and decodes Snappy block streams as byte lists.
///
/// ```dart
/// final bytes = const SnappyCodec().encode(utf8.encode('hello'));
/// final text = utf8.decode(const SnappyCodec().decode(bytes));
/// ```
class SnappyCodec extends Codec<List<int>, List<int>> {
  /// Creates a Snappy block codec.
  const SnappyCodec();

  @override
  Converter<List<int>, List<int>> get encoder => const SnappyEncoder();

  @override
  Converter<List<int>, List<int>> get decoder => const SnappyDecoder();
}

/// Compresses a whole byte list with the Snappy block format.
class SnappyEncoder extends Converter<List<int>, List<int>> {
  /// Creates a Snappy encoder.
  const SnappyEncoder();

  @override
  Uint8List convert(List<int> input) => Snappy.compress(input);
}

/// Decompresses a whole Snappy block stream.
class SnappyDecoder extends Converter<List<int>, List<int>> {
  /// Creates a Snappy decoder.
  const SnappyDecoder();

  @override
  Uint8List convert(List<int> input) => Snappy.decompress(input);
}
