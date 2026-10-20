/// Little-endian base-128 integers used by the Snappy block header.
library;

import 'dart:typed_data';

import 'format.dart';

/// Appends [value] as a varint to [destination] at [offset].
///
/// Returns the offset just past the last written byte. The caller must have
/// reserved at least 5 bytes at [offset].
int writeVarint(Uint8List destination, int offset, int value) {
  var v = value;
  var o = offset;
  while (v >= 0x80) {
    destination[o++] = (v & 0x7F) | 0x80;
    v >>>= 7;
  }
  destination[o++] = v;
  return o;
}

/// Reads the varint at [offset] in [source].
///
/// Returns the decoded value and the offset just past the varint. Throws a
/// [FormatException] for truncated or out-of-range encodings.
(int, int) readVarint(Uint8List source, int offset) {
  var value = 0;
  var shift = 0;
  var o = offset;
  while (true) {
    if (o >= source.length) {
      throw const FormatException('snappy: truncated uncompressed length');
    }
    final int byte = source[o++];
    // Multiplication instead of `<<`: Dart web integers are doubles and the
    // bitwise shift would wrap at 32 bits, losing the top length bits.
    value += (byte & 0x7F) * (1 << shift);
    if (byte < 0x80) {
      if (value > maxUncompressedLength) {
        throw const FormatException(
          'snappy: uncompressed length does not fit in 32 bits',
        );
      }
      return (value, o);
    }
    shift += 7;
    if (shift > 28) {
      throw const FormatException(
        'snappy: uncompressed length is not a valid varint',
      );
    }
  }
}
