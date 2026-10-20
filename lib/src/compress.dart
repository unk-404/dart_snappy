/// The Snappy block compressor.
library;

import 'dart:typed_data';

import 'format.dart';
import 'varint.dart';

/// `kMagic` from the reference implementation's level 1 matcher.
const int _hashMagic = 0x1e35a7bd;

/// `kMagic` from the reference implementation's level 2 4-byte matcher.
const int _hashMagic4 = 0x9e3779b1;

/// `kMagic` from the reference implementation's level 2 8-byte matcher
/// (`0x00CF1BBCDCBFA563`).
///
/// Written as a product so no integer literal above 2^53 appears in the
/// source: dart2js rejects those, and the VM evaluates the expression exactly.
final int _hashMagic8 = 0x00CF1BBC * 0x100000000 + 0xDCBFA563;

/// Reusable scratch tables for the match finder.
///
/// The library is synchronous and never calls back into user code while
/// compressing, so a single set of tables per isolate is safe. Each isolate has
/// its own copy of the top-level state.
final Uint16List _hashTable = Uint16List(hashTableSize);

/// Second table, used by the level 2 double-hash matcher.
final Uint16List _hashTable2 = Uint16List(hashTableSize);

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

/// Hash table slot for the 32-bit little-endian word [word] (level 1).
///
/// Mirrors the Rust `snap` crate's hash: it keeps bits 18..31 of `kMagic *
/// word`. (The C++ implementation uses a 15-bit table and different bits, so
/// level 1 output matches `snap`, not C++.)
///
/// On the VM the 64-bit product is exact. Under dart2js the product is a
/// double and `>>` narrows to 32 bits, so the JavaScript build reaches a
/// different (but still well-distributed and deterministic) slot; the emitted
/// stream stays valid and similarly sized, it just picks other matches.
@pragma('vm:prefer-inline')
int _hash(int word) => ((_hashMagic * word) >> 18) & (hashTableSize - 1);

/// Level 2 4-byte slot: high bits of the 32-bit product, masked to [mask].
@pragma('vm:prefer-inline')
int _hash4(int word, int mask) =>
    ((_hashMagic4 * word) & 0xFFFFFFFF) >>> 18 & mask;

/// Level 2 8-byte slot: bits 50..63 of the 64-bit product, masked to [mask].
///
/// The reference implementation stores the 8-byte word little-endian in a
/// `uint64_t` and keeps the top 14 bits of `kMagic8 * word`. The VM's 64-bit
/// integer arithmetic reproduces that exactly; under dart2js `hi << 32`
/// collapses (shift counts are taken modulo 32), so the JavaScript build lands
/// on a different-but-deterministic slot. Streams stay valid either way.
@pragma('vm:prefer-inline')
int _hash8(ByteData data, int offset, int mask) {
  final int lo = data.getUint32(offset, Endian.little);
  final int hi = data.getUint32(offset + 4, Endian.little);
  final int word = (hi << 32) | lo;
  return (_hashMagic8 * word) >>> 50 & mask;
}

/// Snappy's `CalculateTableSize`: next power of two of the block size, clamped
/// to `[256, 32768]`.
int calculateTableSize(int inputSize) {
  if (inputSize > 32768) return 32768;
  if (inputSize < 256) return 256;
  var size = 256;
  while (size < inputSize) {
    size <<= 1;
  }
  return size;
}

void _checkLevel(int level) {
  if (level < 1 || level > 2) {
    throw RangeError.range(level, 1, 2, 'level');
  }
}

/// Compresses [source] into a newly allocated [Uint8List].
Uint8List compressBlock(Uint8List source, {int level = 1}) {
  _checkLevel(level);
  final buffer = Uint8List(maxCompressedLength(source.length) + outputSlop);
  final written = compressBlockInto(source, buffer, level: level);
  return Uint8List.sublistView(buffer, 0, written);
}

/// Compresses [source] into [destination].
///
/// [destination] must be at least `maxCompressedLength(source.length)` bytes
/// long. [level] is 1 (fast, the default) or 2 (denser, slower).
/// Returns the number of bytes written.
int compressBlockInto(
  Uint8List source,
  Uint8List destination, {
  int level = 1,
}) {
  _checkLevel(level);
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
    op = level == 1
        ? _compressBlock(
            source,
            sourceData,
            base,
            end - base,
            destination,
            destinationData,
            op,
          )
        : _compressBlockDoubleHash(
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

/// Compresses one independent block with the level 1 matcher.
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

  final Uint16List table = _hashTable;
  table.fillRange(0, hashTableSize, 0);

  final int limit = end - inputMarginBytes;
  var nextEmit = base;
  var ip = base + 1;
  var data = sourceData.getUint32(ip, Endian.little);

  while (true) {
    // Scan for a 4-byte match; back off (skip) as the scan gets longer.
    var candidate = 0;
    var skip = 32;
    while (true) {
      final int slot = _hash(data);
      final int found = base + table[slot];
      final int step = skip >> 5;
      skip += step;
      final int nextIp = ip + step;
      if (nextIp > limit) {
        if (nextEmit < end) {
          op = _emitLiteral(source, nextEmit, end - nextEmit, destination, op);
        }
        return op;
      }
      table[slot] = ip - base;
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
      table[_hash(sourceData.getUint32(ip - 1, Endian.little))] = ip - base - 1;
      final int slot = _hash(next);
      candidate = base + table[slot];
      table[slot] = ip - base;
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

/// Compresses one independent block with the level 2 double-hash matcher.
///
/// This is a port of the reference implementation's
/// `CompressFragmentDoubleHash`: an 8-byte hash table for long matches, a
/// 4-byte one for short ones, a wider skip, backward extension of matches and
/// extra table updates around each match. It produces the same bytes as the
/// C++ 1.3.1 implementation on the VM.
int _compressBlockDoubleHash(
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

  // The reference splits one table allocation between the two matchers.
  final int half = calculateTableSize(size) >> 1;
  final int mask = half - 1;
  final Uint16List table = _hashTable;
  final Uint16List table2 = _hashTable2;
  table.fillRange(0, half, 0);
  table2.fillRange(0, half, 0);

  final int limit = end - inputMarginBytes;
  var ip = base;

  while (true) {
    final int nextEmit = ip++;
    var data = sourceData.getUint32(ip, Endian.little);
    var skip = 512;
    var candidate = 0;
    var candidateLength = 0;

    while (true) {
      final int slot2 = _hash8(sourceData, ip, mask);
      final int step = skip >> 9;
      skip++;
      final int nextIp = ip + step;
      if (nextIp > limit) {
        ip = nextEmit;
        if (ip < end) {
          op = _emitLiteral(source, ip, end - ip, destination, op);
        }
        return op;
      }
      candidate = base + table2[slot2];
      table2[slot2] = ip - base;
      if (sourceData.getUint32(candidate, Endian.little) == data) {
        candidateLength =
            4 + _matchLength(sourceData, candidate + 4, ip + 4, end);
        break;
      }

      final int slot1 = _hash4(data, mask);
      candidate = base + table[slot1];
      table[slot1] = ip - base;
      if (sourceData.getUint32(candidate, Endian.little) == data) {
        candidateLength =
            4 + _matchLength(sourceData, candidate + 4, ip + 4, end);
        // The 8-byte table may know a longer match one byte later.
        final int slot2b = _hash8(sourceData, ip + 1, mask);
        final int candidate2 = base + table2[slot2b];
        final int candidateLength2 = _matchLength(
          sourceData,
          candidate2,
          ip + 1,
          end,
        );
        if (candidateLength2 > candidateLength) {
          table2[slot2b] = ip - base;
          candidate = candidate2;
          candidateLength = candidateLength2;
          ip++;
        }
        break;
      }

      ip = nextIp;
      data = sourceData.getUint32(ip, Endian.little);
    }

    // Extend the match backwards as far as possible.
    while (ip > nextEmit &&
        candidate > base &&
        sourceData.getUint8(ip - 1) == sourceData.getUint8(candidate - 1)) {
      ip--;
      candidate--;
      candidateLength++;
    }
    table2[_hash8(sourceData, ip + 1, mask)] = ip - base + 1;
    table2[_hash8(sourceData, ip + 2, mask)] = ip - base + 2;
    table[_hash4(sourceData.getUint32(ip + 1, Endian.little), mask)] =
        ip - base + 1;

    if (ip - nextEmit > 0) {
      op = _emitLiteral(source, nextEmit, ip - nextEmit, destination, op);
    }

    while (true) {
      final int matchBase = ip;
      ip += candidateLength;
      op = _emitCopy(
        destinationData,
        op,
        matchBase - candidate,
        candidateLength,
      );
      if (ip >= limit) {
        if (ip < end) {
          op = _emitLiteral(source, ip, end - ip, destination, op);
        }
        return op;
      }
      if (ip - base > 7) {
        table2[_hash8(sourceData, ip - 7, mask)] = ip - base - 7;
        table2[_hash8(sourceData, ip - 4, mask)] = ip - base - 4;
      }
      table2[_hash8(sourceData, ip - 3, mask)] = ip - base - 3;
      table2[_hash8(sourceData, ip - 2, mask)] = ip - base - 2;
      table[_hash4(sourceData.getUint32(ip - 2, Endian.little), mask)] =
          ip - base - 2;
      table[_hash4(sourceData.getUint32(ip - 1, Endian.little), mask)] =
          ip - base - 1;

      final int slot2 = _hash8(sourceData, ip, mask);
      candidate = base + table2[slot2];
      table2[slot2] = ip - base;
      if (sourceData.getUint32(ip, Endian.little) ==
          sourceData.getUint32(candidate, Endian.little)) {
        candidateLength =
            4 + _matchLength(sourceData, candidate + 4, ip + 4, end);
        continue;
      }
      final int slot1 = _hash4(sourceData.getUint32(ip, Endian.little), mask);
      candidate = base + table[slot1];
      table[slot1] = ip - base;
      if (sourceData.getUint32(ip, Endian.little) ==
          sourceData.getUint32(candidate, Endian.little)) {
        candidateLength =
            4 + _matchLength(sourceData, candidate + 4, ip + 4, end);
        continue;
      }
      break;
    }
  }
}

/// Number of bytes that match between `data[a, ...)` and `data[b, ...)`, never
/// reaching [limit] for the `b` side.
@pragma('vm:prefer-inline')
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
@pragma('vm:prefer-inline')
int _lowestSetBit(int value) {
  final Uint8List lookup = _lowestBit;
  var shift = 0;
  var v = value;
  while (true) {
    final int byte = v & 0xFF;
    if (byte != 0) return shift + lookup[byte];
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
@pragma('vm:prefer-inline')
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
@pragma('vm:prefer-inline')
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
