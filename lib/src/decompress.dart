/// The Snappy block decompressor.
library;

import 'dart:typed_data';

import 'format.dart';
import 'varint.dart';

/// Reads the uncompressed length from the header of a Snappy block stream.
///
/// The whole stream is not validated; use [decompress] for that.
int uncompressedLengthFrom(Uint8List source) {
  final (value, _) = readVarint(source, 0);
  return value;
}

/// Decodes [source] into a newly allocated [Uint8List].
Uint8List decompressBlock(Uint8List source) {
  final (expected, headerLength) = readVarint(source, 0);
  final buffer = Uint8List(expected + outputSlop);
  decodeBlock(source, headerLength, buffer, expected, outputSlop);
  return Uint8List.sublistView(buffer, 0, expected);
}

/// Decodes [source] into [destination], which must hold at least the declared
/// uncompressed length.
///
/// Returns the number of bytes written (the declared uncompressed length).
int decompressBlockInto(Uint8List source, Uint8List destination) {
  final (expected, headerLength) = readVarint(source, 0);
  if (destination.length < expected) {
    throw ArgumentError.value(
      destination.length,
      'destination.length',
      'must be at least the uncompressed length ($expected)',
    );
  }
  final int overCopy = destination.length - expected;
  decodeBlock(
    source,
    headerLength,
    destination,
    expected,
    overCopy < 8 ? overCopy : 8,
  );
  return expected;
}

/// Decodes the tag stream in [source] starting at [offset] into
/// `destination[0, outputLength)`.
///
/// [overCopy] spare bytes at the end of [destination] may be over-written by
/// the copy fast paths; [destination] must be at least `outputLength +
/// overCopy` long.
int decodeBlock(
  Uint8List source,
  int offset,
  Uint8List destination,
  int outputLength,
  int overCopy,
) {
  final int sourceLength = source.length;
  final int writeLimit = outputLength + overCopy;
  final ByteData destinationData = ByteData.sublistView(destination);
  var ip = offset;
  var op = 0;

  while (ip < sourceLength) {
    final int tag = source[ip++];
    final int tagType = tag & 0x03;

    if (tagType == 0) {
      // Literal.
      final int encoded = tag >> 2;
      var length = encoded + 1;
      if (encoded >= 60) {
        final int lengthBytes = encoded - 59; // 1..4
        if (ip + lengthBytes > sourceLength) {
          throw const FormatException(
            'snappy: truncated literal length in tag',
          );
        }
        var value = 0;
        for (var i = 0; i < lengthBytes; i++) {
          value |= source[ip + i] << (i << 3);
        }
        length = value + 1;
        ip += lengthBytes;
      }
      final int end = op + length;
      if (end > outputLength) {
        throw const FormatException('snappy: literal overruns the output');
      }
      if (ip + length > sourceLength) {
        throw const FormatException('snappy: truncated literal');
      }
      destination.setRange(op, end, source, ip);
      op = end;
      ip += length;
      continue;
    }

    // Copy.
    final int length;
    final int copyOffset;
    if (tagType == 1) {
      length = 4 + ((tag >> 2) & 0x07);
      if (ip >= sourceLength) {
        throw const FormatException('snappy: truncated copy offset');
      }
      copyOffset = ((tag >> 5) << 8) | source[ip];
      ip += 1;
    } else if (tagType == 2) {
      length = 1 + (tag >> 2);
      if (ip + 2 > sourceLength) {
        throw const FormatException('snappy: truncated copy offset');
      }
      copyOffset = source[ip] | (source[ip + 1] << 8);
      ip += 2;
    } else {
      length = 1 + (tag >> 2);
      if (ip + 4 > sourceLength) {
        throw const FormatException('snappy: truncated copy offset');
      }
      copyOffset =
          source[ip] |
          (source[ip + 1] << 8) |
          (source[ip + 2] << 16) |
          (source[ip + 3] << 24);
      ip += 4;
    }
    if (copyOffset == 0 || copyOffset > op) {
      throw const FormatException(
        'snappy: copy references data before the start of the output',
      );
    }
    final int end = op + length;
    if (end > outputLength) {
      throw const FormatException('snappy: copy overruns the output');
    }
    copyFromOutput(
      destination,
      destinationData,
      op,
      copyOffset,
      length,
      writeLimit,
    );
    op = end;
  }

  if (op != outputLength) {
    throw FormatException(
      'snappy: stream declares $outputLength bytes but produced $op',
    );
  }
  return op;
}

/// Copies [length] bytes from [offset] bytes before [op] to [op] in [output].
///
/// This is the LZ77 copy: source and destination may overlap, in which case the
/// pattern repeats (run-length encoding). Copies are performed on the smallest
/// already-written granule that is guaranteed to be complete, so the source
/// never overlaps the bytes being produced by the same store; trailing bytes
/// may be over-written up to [writeLimit] when spare capacity allows.
void copyFromOutput(
  Uint8List output,
  ByteData data,
  int op,
  int offset,
  int length,
  int writeLimit,
) {
  final int source = op - offset;

  if (offset >= 8) {
    var s = source;
    var d = op;
    var remaining = length;
    while (remaining >= 8) {
      data.setUint32(d, data.getUint32(s, Endian.little), Endian.little);
      data.setUint32(
        d + 4,
        data.getUint32(s + 4, Endian.little),
        Endian.little,
      );
      d += 8;
      s += 8;
      remaining -= 8;
    }
    if (remaining == 0) return;
    if (d + 8 <= writeLimit) {
      data.setUint32(d, data.getUint32(s, Endian.little), Endian.little);
      data.setUint32(
        d + 4,
        data.getUint32(s + 4, Endian.little),
        Endian.little,
      );
      return;
    }
    while (remaining > 0) {
      output[d++] = output[s++];
      remaining--;
    }
    return;
  }

  if (offset >= 4) {
    var s = source;
    var d = op;
    var remaining = length;
    while (remaining >= 4) {
      data.setUint32(d, data.getUint32(s, Endian.little), Endian.little);
      d += 4;
      s += 4;
      remaining -= 4;
    }
    if (remaining == 0) return;
    if (d + 4 <= writeLimit) {
      data.setUint32(d, data.getUint32(s, Endian.little), Endian.little);
      return;
    }
    while (remaining > 0) {
      output[d++] = output[s++];
      remaining--;
    }
    return;
  }

  if (offset == 1) {
    output.fillRange(op, op + length, output[source]);
    return;
  }

  // Offsets 2 and 3 cannot be copied in 4-byte granules, because the granule
  // would read bytes it is about to produce. Materialise one whole multiple of
  // 4 bytes of the pattern, then double it with aligned word copies.
  final int period = offset == 2 ? 4 : 12;
  var written = 0;
  final int seedLength = length < period ? length : period;
  while (written < seedLength) {
    output[op + written] = output[source + written];
    written++;
  }
  if (length <= period) return;
  while (written < length) {
    final int chunk = written < length - written ? written : length - written;
    final int d = op + written;
    var i = 0;
    while (i + 4 <= chunk) {
      data.setUint32(
        d + i,
        data.getUint32(op + i, Endian.little),
        Endian.little,
      );
      i += 4;
    }
    while (i < chunk) {
      output[d + i] = output[op + i];
      i++;
    }
    written += chunk;
  }
}
