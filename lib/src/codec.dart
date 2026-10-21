/// Allocation-free codec objects and a `dart:convert` codec for the Snappy
/// block format.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'compress.dart' as compressor;
import 'decompress.dart' as decompressor;
import 'snappy.dart';

/// Reusable Snappy block encoder.
///
/// The object only carries the compression level: the match-finder tables are
/// per-isolate scratch space. The point of this class is [encodeInto], which
/// writes into a buffer you own and allocates nothing; it is measurably faster
/// than [encode], which has to allocate and clear an output buffer per call.
///
/// ```dart
/// final encoder = SnappyEncoder();
/// final output = Uint8List(Snappy.maxCompressedLength(bytes.length));
/// final written = encoder.encodeInto(bytes, output);
/// final compressed = Uint8List.sublistView(output, 0, written);
/// ```
final class SnappyEncoder {
  /// Creates an encoder.
  ///
  /// [level] is 1 (fastest, the default) or 2 (denser and slower).
  const SnappyEncoder({this.level = 1});

  /// Compression level used by [encode] and [encodeInto].
  final int level;

  /// Compresses [source] into a new [Uint8List].
  Uint8List encode(Uint8List source) =>
      compressor.compressBlock(source, level: level);

  /// Compresses [source] into [destination] and returns the byte count.
  ///
  /// [destination] must be at least [Snappy.maxCompressedLength] of
  /// `source.length` bytes. The encoder may write up to 15 bytes past the
  /// returned length (still inside [destination]).
  int encodeInto(Uint8List source, Uint8List destination) =>
      compressor.compressBlockInto(source, destination, level: level);
}

/// Reusable Snappy block decoder.
///
/// [decodeInto] writes into a caller-owned buffer and performs no allocation,
/// which is up to 2.5x faster than [decode] on literal-heavy input (the
/// allocation of the output buffer dominates there).
final class SnappyDecoder {
  /// Creates a decoder.
  const SnappyDecoder();

  /// Decompresses [source] into a new [Uint8List].
  Uint8List decode(Uint8List source) => decompressor.decompressBlock(source);

  /// Decompresses [source] into [destination] and returns the byte count.
  ///
  /// [destination] must hold at least the declared uncompressed length; bytes
  /// after the decoded range are left untouched.
  int decodeInto(Uint8List source, Uint8List destination) =>
      decompressor.decompressBlockInto(source, destination);

  /// Reads the uncompressed length declared at the start of [source].
  int uncompressedLength(Uint8List source) =>
      decompressor.uncompressedLengthFrom(source);
}

/// Encodes and decodes Snappy block streams as byte lists.
///
/// This is the `dart:convert` integration; use [SnappyEncoder] /
/// [SnappyDecoder] directly when you control the buffers.
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
  Converter<List<int>, List<int>> get encoder => _SnappyEncoderConverter(level);

  @override
  Converter<List<int>, List<int>> get decoder =>
      const _SnappyDecoderConverter();
}

final class _SnappyEncoderConverter extends Converter<List<int>, List<int>> {
  const _SnappyEncoderConverter(this.level);

  final int level;

  @override
  Uint8List convert(List<int> input) => Snappy.compress(input, level: level);
}

final class _SnappyDecoderConverter extends Converter<List<int>, List<int>> {
  const _SnappyDecoderConverter();

  @override
  Uint8List convert(List<int> input) => Snappy.decompress(input);
}
