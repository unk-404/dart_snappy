/// Constants shared by the Snappy block codec.
///
/// Everything in this library is internal: clients use `Snappy` from
/// `package:snappy_neo/snappy_neo.dart`.
library;

/// Size of one independent compression block (64 KiB).
///
/// The encoder never emits a back-reference across a block boundary, so every
/// offset fits in 16 bits and the "copy with 4-byte offset" tag is never
/// produced. The decoder still accepts that tag.
const int blockSize = 65536;

/// Number of trailing input bytes in which the match finder does not start a
/// new scan (it needs 16 readable bytes for its fast paths).
const int inputMarginBytes = 15;

/// Bits in the match finder's hash table.
const int hashTableBits = 14;

/// Number of entries in the match finder's hash table.
const int hashTableSize = 1 << hashTableBits;

/// Spare bytes reserved after the logical output so the emitting code may
/// over-write up to this many bytes on its fast paths.
const int outputSlop = 64;

/// Largest uncompressed length a block-format stream can describe (2^32 - 1).
const int maxUncompressedLength = 0xFFFFFFFF;

/// Hash multiplier from the reference implementation (`kMagic`).
const int _hashMagic = 0x1e35a7bd;

/// Upper bound on the compressed size of [sourceBytes] input bytes.
///
/// The bound is the one used by the reference implementation: worst case is a
/// one-byte literal followed by a five-byte copy (6 input bytes -> 7 output
/// bytes), which is `n + n / 6` on top of the 32-byte header allowance.
int maxCompressedLength(int sourceBytes) {
  if (sourceBytes < 0) {
    throw RangeError.value(sourceBytes, 'sourceBytes');
  }
  return 32 + sourceBytes + sourceBytes ~/ 6;
}

/// Hash table slot for the 32-bit little-endian word [word].
///
/// Mirrors the reference implementation's quick-and-dirty hash: the high bits
/// of `kMagic * word` are a better hash than the low bits, so the result is
/// shifted down and then masked.
int hashSlot(int word) {
  final int product = (_hashMagic * word) & 0xFFFFFFFF;
  return ((product >> (31 - hashTableBits)) >> 1) & (hashTableSize - 1);
}
