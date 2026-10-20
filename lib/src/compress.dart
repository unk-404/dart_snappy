/// The Snappy block compressor.
library;

import 'dart:typed_data';

import 'format.dart';
import 'varint.dart';

/// Reusable scratch table for the match finder.
///
/// The library is synchronous and never calls back into user code while
/// compressing, so a single table per isolate is safe. Each isolate has its own
/// copy of the top-level state.
final Uint16List _hashTable = Uint16List(hashTableSize);

/// Byte offsets (the low byte of every difference) for lowest-set-bit lookup.
final Uint8List _lowestBit = _buildLowestBitTable();

Uint8List _buildLowestBitTable() {
  final table = Uint8List(256);
  for (var value = 1; value < 256; value++) {
    var bit = 0;
    while ((value >> bit) & 1 == 0) {
      bit++;
    }
    table[value] = bit;
  }
  return table;
}

/// Compresses [source] into a newly allocated [Uint8List].
Uint8List compressBlock(Uint8List source) {
  final buffer = Uint8List(maxCompressedLength(source.length) + outputSlop);
  final written = compressBlockInto(source, buffer);
  return Uint8List.sublistView(buffer, 0, written);
}

/// Compresses [source] into [destination].
///
/// [destination] must be at least `maxCompressedLength(source.length)` bytes
/// long. Returns the number of bytes written.
int compressBlockInto(Uint8List source, Uint8List destination) {
  final int required = maxCompressedLength(source.length);
  if (destination.length < required) {
    throw ArgumentError.value(
      destination.length,
      'destination.length',
      'must be at least $required (maxCompressedLength(${source.length}))',
    );
  }
  final ByteData sourceData = ByteData.sublistView(source);
  final ByteData destinationData = ByteData.sublistView(destination);
  final int sourceLength = source.length;
  var op = writeVarint(destination, 0, sourceLength);
  for (var base = 0; base < sourceLength; base += blockSize) {
    final int end = base + blockSize < sourceLength
        ? base + blockSize
        : sourceLength;
    op = _compressBlock(
      source,
      sourceData,
      base,
      end - base,
      destination,
      destinationData,
      op,
    );
  }
  return op;
}

/// Compresses one independent block `source[base, base + size)`.
int _compressBlock(
  Uint8List source,
  ByteData sourceData,
  int base,
  int size,
  Uint8List destination,
  ByteData destinationData,
  int op,
) {
  final int end = base + size;
  if (size < inputMarginBytes) {
    if (size > 0) {
      op = _emitLiteral(source, base, size, destination, op);
    }
    return op;
  }

  _hashTable.fillRange(0, hashTableSize, 0);

  final int limit = end - inputMarginBytes;
  var nextEmit = base;
  var ip = base + 1;
  var data = sourceData.getUint32(ip, Endian.little);

  while (true) {
    // Scan for a 4-byte match; back off (skip) as the scan gets longer.
    var candidate = 0;
    var skip = 32;
    while (true) {
      final int slot = hashSlot(data);
      final int found = base + _hashTable[slot];
      final int step = skip >> 5;
      skip += step;
      final int nextIp = ip + step;
      if (nextIp > limit) {
        if (nextEmit < end) {
          op = _emitLiteral(source, nextEmit, end - nextEmit, destination, op);
        }
        return op;
      }
      _hashTable[slot] = ip - base;
      if (sourceData.getUint32(found, Endian.little) == data) {
        candidate = found;
        break;
      }
      ip = nextIp;
      data = sourceData.getUint32(ip, Endian.little);
    }

    op = _emitLiteral(source, nextEmit, ip - nextEmit, destination, op);

    // Emit copies while the bytes right after the last copy keep matching.
    while (true) {
      final int matched =
          4 + _matchLength(sourceData, candidate + 4, ip + 4, end);
      ip += matched;
      op = _emitCopy(destinationData, op, ip - matched - candidate, matched);
      if (ip >= limit) {
        if (ip < end) {
          op = _emitLiteral(source, ip, end - ip, destination, op);
        }
        return op;
      }
      final int next = sourceData.getUint32(ip, Endian.little);
      _hashTable[hashSlot(sourceData.getUint32(ip - 1, Endian.little))] =
          ip - base - 1;
      final int slot = hashSlot(next);
      candidate = base + _hashTable[slot];
      _hashTable[slot] = ip - base;
      if (next != sourceData.getUint32(candidate, Endian.little)) {
        data = next;
        break;
      }
    }
    nextEmit = ip;
    ip++;
    data = sourceData.getUint32(ip, Endian.little);
  }
}

/// Number of bytes that match between `data[a, ...)` and `data[b, ...)`, never
/// reaching [limit] for the `b` side.
int _matchLength(ByteData data, int a, int b, int limit) {
  final int start = b;
  while (b + 4 <= limit) {
    final int difference =
        (data.getUint32(a, Endian.little) ^ data.getUint32(b, Endian.little)) &
        0xFFFFFFFF;
    if (difference != 0) {
      return (b - start) + (_lowestSetBit(difference) >> 3);
    }
    a += 4;
    b += 4;
  }
  while (b < limit && data.getUint8(a) == data.getUint8(b)) {
    a++;
    b++;
  }
  return b - start;
}

/// Index of the lowest set bit of [value], which must be in `1..0xFFFFFFFF`.
int _lowestSetBit(int value) {
  var shift = 0;
  var v = value;
  while (true) {
    final int byte = v & 0xFF;
    if (byte != 0) return shift + _lowestBit[byte];
    v >>= 8;
    shift += 8;
  }
}

/// Emits the literal `source[from, from + length)`.
///
/// The payload is copied with a 16-byte store when both buffers have enough
/// slack; the extra bytes are always overwritten by whatever follows.
int _emitLiteral(
  Uint8List source,
  int from,
  int length,
  Uint8List destination,
  int op,
) {
  final int n = length - 1;
  if (n < 60) {
    destination[op++] = n << 2;
  } else {
    final int lengthBytes = ((n.bitLength - 1) >> 3) + 1;
    destination[op++] = (59 + lengthBytes) << 2;
    var value = n;
    for (var i = 0; i < lengthBytes; i++) {
      destination[op++] = value & 0xFF;
      value >>= 8;
    }
  }
  final int end = op + length;
  if (length <= 16 &&
      from + 16 <= source.length &&
      op + 16 <= destination.length) {
    destination.setRange(op, op + 16, source, from);
  } else {
    destination.setRange(op, end, source, from);
  }
  return end;
}

/// Emits a copy of [length] bytes at [offset] bytes back.
int _emitCopy(ByteData destination, int op, int offset, int length) {
  assert(length >= 4 && offset > 0 && offset < blockSize);
  if (length < 12) {
    return _emitCopyAtMost64(destination, op, offset, length, true);
  }
  var len = length;
  while (len >= 68) {
    op = _emitCopyAtMost64(destination, op, offset, 64, false);
    len -= 64;
  }
  if (len > 64) {
    op = _emitCopyAtMost64(destination, op, offset, 60, false);
    len -= 60;
  }
  return _emitCopyAtMost64(destination, op, offset, len, len < 12);
}

/// Emits one copy tag for `4 <= length <= 64`.
int _emitCopyAtMost64(
  ByteData destination,
  int op,
  int offset,
  int length,
  bool shortCopy,
) {
  if (shortCopy && offset < 2048) {
    destination.setUint8(op, 1 | ((length - 4) << 2) | ((offset >> 8) << 5));
    destination.setUint8(op + 1, offset & 0xFF);
    return op + 2;
  }
  destination.setUint8(op, 2 | ((length - 1) << 2));
  destination.setUint16(op + 1, offset, Endian.little);
  return op + 3;
}
