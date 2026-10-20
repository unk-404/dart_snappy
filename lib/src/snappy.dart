/// Google's Snappy compression, block ("raw") format, in pure Dart.
///
/// The block format is the one used by most storage formats (Parquet, RPC
/// payloads, key-value stores): a varint header with the uncompressed length
/// followed by literals and back-references. It has no framing, checksum or
/// metadata of its own; add those at the container level.
///
/// ```dart
/// final compressed = Snappy.compress(bytes);
/// final restored = Snappy.decompress(compressed);
/// ```
library;

import 'dart:typed_data';

import 'compress.dart' as impl;
import 'decompress.dart' as impl;
import 'format.dart' as fmt;

/// A pure Dart implementation of the Snappy block format.
///
/// All methods are synchronous and allocate no native resources. Instances are
/// not needed; the class only exists as a namespace.
abstract final class Snappy {
  /// Upper bound on the compressed size of [sourceBytes] input bytes.
  ///
  /// A buffer of this size is always large enough for [compressInto].
  static int maxCompressedLength(int sourceBytes) =>
      fmt.maxCompressedLength(sourceBytes);

  /// Reads the uncompressed length declared at the start of [source].
  ///
  /// This only parses the header, so it is cheap; it does not validate the
  /// rest of the stream. Throws a [FormatException] if the header is truncated
  /// or the length does not fit in 32 bits.
  static int uncompressedLength(List<int> source) =>
      impl.uncompressedLengthFrom(_asBytes(source));

  /// Compresses [source] and returns a new [Uint8List].
  ///
  /// The returned buffer may share memory with a larger allocation, so copy it
  /// with [Uint8List.fromList] if an exactly sized buffer is required.
  static Uint8List compress(List<int> source) =>
      impl.compressBlock(_asBytes(source));

  /// Compresses [source] into [destination] and returns the byte count.
  ///
  /// [destination] must be at least [maxCompressedLength] of `source.length`
  /// bytes; [ArgumentError] is thrown otherwise. The encoder's fast paths may
  /// write up to 15 bytes past the returned length (still inside
  /// [destination]); only the first `returnValue` bytes are meaningful.
  static int compressInto(List<int> source, Uint8List destination) =>
      impl.compressBlockInto(_asBytes(source), destination);

  /// Decompresses the Snappy block stream [source] into a new [Uint8List].
  ///
  /// The returned buffer may share memory with a larger allocation.
  static Uint8List decompress(List<int> source) =>
      impl.decompressBlock(_asBytes(source));

  /// Decompresses [source] into [destination] and returns the byte count.
  ///
  /// [destination] must be large enough for the declared uncompressed length;
  /// [ArgumentError] is thrown otherwise. Exactly the declared number of bytes
  /// is written: bytes after that point in [destination] are left untouched.
  static int decompressInto(List<int> source, Uint8List destination) =>
      impl.decompressBlockInto(_asBytes(source), destination);
}

/// Returns [source] as a [Uint8List], copying only when it is not one already.
///
/// Values outside `0..255` are truncated, matching [Uint8List.fromList].
Uint8List _asBytes(List<int> source) =>
    source is Uint8List ? source : Uint8List.fromList(source);
