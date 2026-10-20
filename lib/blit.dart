/// Zero-copy `blit` integration for [Snappy].
///
/// Import this library instead of `package:snappy_neo/snappy_neo.dart` when
/// you already work with `Bytes` and want to avoid buffer copies:
///
/// ```dart
/// import 'package:blit/bytes.dart';
/// import 'package:snappy_neo/blit.dart';
///
/// final compressed = Bytes.fromUint8List(payload).snappyCompress();
/// final restored = compressed.snappyDecompress();
/// ```
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'src/snappy.dart';

/// Snappy operations on blit's zero-copy [Bytes] views.
extension SnappyBytesExtension on Bytes {
  /// Compresses this view into a new [Bytes].
  ///
  /// Slicing is zero-copy on both sides: the result is a `Bytes` view over the
  /// encoder's output buffer, exactly as long as the compressed stream.
  Bytes snappyCompress() => Bytes.fromUint8List(Snappy.compress(asUint8List()));

  /// Decompresses this view into a new [Uint8List].
  Uint8List snappyDecompress() => Snappy.decompress(asUint8List());

  /// The uncompressed length declared by this block stream's header.
  int get snappyUncompressedLength => Snappy.uncompressedLength(asUint8List());
}
