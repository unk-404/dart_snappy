/// Zero-copy `blit` integration for [Snappy] and [SnappyFraming].
///
/// Import this library instead of `package:snappy_neo/snappy_neo.dart` when
/// you already work with `Bytes`/`BytesMut` and want to avoid buffer copies:
///
/// ```dart
/// import 'package:blit/blit_buffer.dart';
/// import 'package:snappy_neo/blit.dart';
///
/// final compressed = Bytes.fromUint8List(payload).snappyCompress();
/// final restored = compressed.snappyDecompress();
///
/// final framed = Bytes.fromUint8List(payload).snappyFrameCompress();
/// final unpacked = framed.snappyFrameDecompress();
/// ```
library;

import 'dart:typed_data';

import 'package:blit/blit_buffer.dart';

import 'src/framing.dart';
import 'src/snappy.dart';

/// Snappy operations on blit's zero-copy [Bytes] views.
extension SnappyBytesExtension on Bytes {
  /// Compresses this view into a new [Bytes] using the block format.
  ///
  /// Slicing is zero-copy on both sides: the result is a `Bytes` view over the
  /// encoder's output buffer, exactly as long as the compressed stream. [level]
  /// is 1 (fastest, the default) or 2 (denser and slower).
  Bytes snappyCompress({int level = 1}) =>
      Bytes.fromUint8List(Snappy.compress(asUint8List(), level: level));

  /// Decompresses this block-format view into a new [Uint8List].
  Uint8List snappyDecompress() => Snappy.decompress(asUint8List());

  /// The uncompressed length declared by this block stream's header.
  int get snappyUncompressedLength => Snappy.uncompressedLength(asUint8List());

  /// Frames this view into a new [Bytes] using the Snappy framing format.
  ///
  /// [level] is 1 (fastest, the default) or 2 (denser and slower).
  Bytes snappyFrameCompress({int level = 1}) =>
      Bytes.fromUint8List(SnappyFraming.compress(asUint8List(), level: level));

  /// Decompresses this framed view into a new [Uint8List].
  ///
  /// [verifyChecksums] may be disabled when another layer guarantees integrity.
  Uint8List snappyFrameDecompress({bool verifyChecksums = true}) =>
      SnappyFraming.decompress(asUint8List(), verifyChecksums: verifyChecksums);
}

/// Appends Snappy streams to a blit [BytesMut] without intermediate copies.
///
/// Both methods reserve the worst-case output size and compress straight into
/// the buffer's spare capacity, so building a larger message out of several
/// compressed parts never allocates a temporary result.
extension SnappyBytesMutExtension on BytesMut {
  /// Appends the block-format compression of [source].
  void snappyCompressFrom(Bytes source, {int level = 1}) {
    final Uint8List input = source.asUint8List();
    final Uint8List spare = spareView(Snappy.maxCompressedLength(input.length));
    final int written = Snappy.compressInto(input, spare, level: level);
    advance(written);
  }

  /// Appends the framing-format compression of [source].
  void snappyFrameCompressFrom(Bytes source, {int level = 1}) {
    final Uint8List input = source.asUint8List();
    final Uint8List spare = spareView(
      SnappyFraming.maxCompressedLength(input.length),
    );
    final int written = SnappyFraming.compressInto(input, spare, level: level);
    advance(written);
  }
}
