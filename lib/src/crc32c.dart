/// CRC-32C (Castagnoli) and the Snappy framing checksum mask.
library;

import 'dart:typed_data';

/// Reflected CRC-32C polynomial (`0x1EDC6F41` reflected is `0x82F63B78`).
const int _polynomial = 0x82F63B78;

/// Slicing-by-8 tables: `_tables[k][byte]` advances the CRC by one byte
/// followed by `k` zero bytes.
final List<Uint32List> _tables = _buildTables();

/// Truncates to an unsigned 32-bit integer on every platform.
///
/// On the VM `& 0xFFFFFFFF` is enough; under dart2js `&` yields a *signed*
/// int32, while `>>>` performs the `ToUint32` conversion. Combining both gives
/// the same non-negative value on the VM, dart2js and dart2wasm.
@pragma('vm:prefer-inline')
int _u32(int value) => (value & 0xFFFFFFFF) >>> 0;

List<Uint32List> _buildTables() {
  final first = Uint32List(256);
  for (var index = 0; index < 256; index++) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) != 0 ? (_polynomial ^ (value >>> 1)) : (value >>> 1);
    }
    first[index] = value;
  }
  final tables = <Uint32List>[first];
  for (var step = 1; step < 8; step++) {
    final previous = tables[step - 1];
    final next = Uint32List(256);
    for (var index = 0; index < 256; index++) {
      final value = previous[index];
      next[index] = (first[value & 0xFF] ^ (value >>> 8)) & 0xFFFFFFFF;
    }
    tables.add(next);
  }
  return tables;
}

/// CRC-32C of `data[start, end)`, as an unsigned 32-bit integer.
int crc32cRange(Uint8List data, int start, int end) {
  final tables = _tables;
  final t0 = tables[0];
  final t1 = tables[1];
  final t2 = tables[2];
  final t3 = tables[3];
  final t4 = tables[4];
  final t5 = tables[5];
  final t6 = tables[6];
  final t7 = tables[7];
  final words = ByteData.sublistView(data);
  var crc = 0xFFFFFFFF;
  var index = start;

  while (index + 8 <= end) {
    final low = words.getUint32(index, Endian.little);
    final high = words.getUint32(index + 4, Endian.little);
    crc = (crc ^ low) & 0xFFFFFFFF;
    crc =
        (t7[crc & 0xFF] ^
            t6[(crc >>> 8) & 0xFF] ^
            t5[(crc >>> 16) & 0xFF] ^
            t4[(crc >>> 24) & 0xFF] ^
            t3[high & 0xFF] ^
            t2[(high >>> 8) & 0xFF] ^
            t1[(high >>> 16) & 0xFF] ^
            t0[(high >>> 24) & 0xFF]) &
        0xFFFFFFFF;
    index += 8;
  }

  while (index < end) {
    crc = (t0[(crc ^ data[index]) & 0xFF] ^ (crc >>> 8)) & 0xFFFFFFFF;
    index++;
  }
  return _u32(crc ^ 0xFFFFFFFF);
}

/// CRC-32C of all of [data], as an unsigned 32-bit integer.
int crc32c(Uint8List data) => crc32cRange(data, 0, data.length);

/// Masks [crc] the way the Snappy framing format requires.
///
/// Rotates the checksum left by 15 bits and adds `0xa282ead8`, wrapping at
/// 32 bits (the same scheme as Apache Hadoop).
int maskChecksum(int crc) => _u32((((crc >>> 15) | (crc << 17)) + 0xa282ead8));
