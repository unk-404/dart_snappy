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
  ///
  /// [level] is 1 (fastest, the default) or 2 (denser and slower); it only
  /// affects encoding.
  const SnappyCodec({this.level = 1});

  /// Compression level used by [encoder].
  final int level;

  @override
  Converter<List<int>, List<int>> get encoder => SnappyEncoder(level: level);

  @override
  Converter<List<int>, List<int>> get decoder => const SnappyDecoder();
}

/// Compresses a whole byte list with the Snappy block format.
class SnappyEncoder extends Converter<List<int>, List<int>> {
  /// Creates a Snappy encoder.
  ///
  /// [level] is 1 (fastest, the default) or 2 (denser and slower).
  const SnappyEncoder({this.level = 1});

  /// Compression level passed to [Snappy.compress].
  final int level;

  @override
  Uint8List convert(List<int> input) => Snappy.compress(input, level: level);
}

/// Decompresses a whole Snappy block stream.
class SnappyDecoder extends Converter<List<int>, List<int>> {
  /// Creates a Snappy decoder.
  const SnappyDecoder();

  @override
  Uint8List convert(List<int> input) => Snappy.decompress(input);
}
