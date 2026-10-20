/// CRC-32C (Castagnoli) and the Snappy framing checksum mask.
library;

import 'dart:typed_data';

/// Reflected CRC-32C polynomial (`0x1EDC6F41` reflected is `0x82F63B78`).
const int _polynomial = 0x82F63B78;

/// Lookup table for one byte of CRC-32C.
final Uint32List _table = _buildTable();

/// Truncates to an unsigned 32-bit integer on every platform.
///
/// On the VM `& 0xFFFFFFFF` is enough; under dart2js `&` yields a *signed*
/// int32, while `>>>` performs the `ToUint32` conversion. Combining both gives
/// the same non-negative value on the VM, dart2js and dart2wasm.
@pragma('vm:prefer-inline')
int _u32(int value) => (value & 0xFFFFFFFF) >>> 0;

Uint32List _buildTable() {
  final table = Uint32List(256);
  for (var index = 0; index < 256; index++) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) != 0 ? (_polynomial ^ (value >>> 1)) : (value >>> 1);
    }
    table[index] = value;
  }
  return table;
}

/// CRC-32C of `data[start, end)`, as an unsigned 32-bit integer.
int crc32cRange(Uint8List data, int start, int end) {
  final table = _table;
  var value = 0xFFFFFFFF;
  for (var index = start; index < end; index++) {
    value = (table[(value ^ data[index]) & 0xFF] ^ (value >>> 8)) & 0xFFFFFFFF;
  }
  return _u32(value ^ 0xFFFFFFFF);
}

/// CRC-32C of all of [data], as an unsigned 32-bit integer.
int crc32c(Uint8List data) => crc32cRange(data, 0, data.length);

/// Masks [crc] the way the Snappy framing format requires.
///
/// Rotates the checksum left by 15 bits and adds `0xa282ead8`, wrapping at
/// 32 bits (the same scheme as Apache Hadoop).
int maskChecksum(int crc) => _u32((((crc >>> 15) | (crc << 17)) + 0xa282ead8));
