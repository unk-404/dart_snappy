/// Deterministic test data and hand-built Snappy stream helpers.
library;

import 'dart:typed_data';

/// xorshift32: identical sequence on the VM and on the web.
class XorShift32 {
  XorShift32(int seed) : _state = (seed == 0 ? 0x9E3779B9 : seed) & 0xFFFFFFFF;

  int _state;

  int nextUint32() {
    var x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x & 0xFFFFFFFF;
    return _state;
  }

  int nextByte() => nextUint32() & 0xFF;
}

Uint8List randomBytes(int length, int seed) {
  final rng = XorShift32(seed);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = rng.nextByte();
  }
  return out;
}

Uint8List zeroBytes(int length) => Uint8List(length);

Uint8List ascendingBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = i & 0xFF;
  }
  return out;
}

const String _paragraph =
    'The quick brown fox jumps over the lazy dog. '
    'Pack my box with five dozen liquor jugs. '
    'How vexingly quick daft zebras jump! ';

/// Repeating natural-language-ish text, the shape real Snappy input has.
Uint8List textBytes(int length) {
  final out = Uint8List(length);
  final pattern = _paragraph.codeUnits;
  for (var i = 0; i < length; i++) {
    out[i] = pattern[i % pattern.length];
  }
  return out;
}

/// JSON-ish records with many repeated keys.
Uint8List jsonLikeBytes(int records) {
  final buffer = StringBuffer();
  for (var i = 0; i < records; i++) {
    buffer.write(
      '{"id":$i,"name":"item-$i","tags":["alpha","beta"],'
      '"active":${i.isEven},"score":${i * 7 % 101}}\n',
    );
  }
  return Uint8List.fromList(buffer.toString().codeUnits);
}

/// Alternating compressible runs and incompressible noise.
Uint8List mixedBytes(int length, int seed) {
  final out = Uint8List(length);
  final rng = XorShift32(seed);
  var i = 0;
  var run = 0;
  while (i < length) {
    final chunk = length - i < 512 ? length - i : 512;
    if (run.isEven) {
      for (var k = 0; k < chunk; k++) {
        out[i + k] = (i + k) & 0x07;
      }
    } else {
      for (var k = 0; k < chunk; k++) {
        out[i + k] = rng.nextByte();
      }
    }
    i += chunk;
    run++;
  }
  return out;
}

/// Encodes [value] as a little-endian varint.
Uint8List varint(int value) {
  final out = <int>[];
  var v = value;
  while (v >= 0x80) {
    out.add((v & 0x7F) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return Uint8List.fromList(out);
}

/// The literal tag for a literal of [length] bytes.
List<int> literalTag(int length) {
  final n = length - 1;
  if (n < 60) return [n << 2];
  final lengthBytes = ((n.bitLength - 1) >> 3) + 1;
  final out = <int>[(59 + lengthBytes) << 2];
  var value = n;
  for (var i = 0; i < lengthBytes; i++) {
    out.add(value & 0xFF);
    value >>= 8;
  }
  return out;
}

/// A "copy with 1-byte offset" tag plus its offset byte.
List<int> copy1(int length, int offset) => [
  1 | ((length - 4) << 2) | ((offset >> 8) << 5),
  offset & 0xFF,
];

/// A "copy with 2-byte offset" tag plus its little-endian offset.
List<int> copy2(int length, int offset) => [
  2 | ((length - 1) << 2),
  offset & 0xFF,
  (offset >> 8) & 0xFF,
];

/// A "copy with 4-byte offset" tag plus its little-endian offset.
List<int> copy4(int length, int offset) => [
  3 | ((length - 1) << 2),
  offset & 0xFF,
  (offset >> 8) & 0xFF,
  (offset >> 16) & 0xFF,
  (offset >> 24) & 0xFF,
];

/// A literal payload of [length] copies of [byte].
List<int> literalPayload(int length, [int byte = 0x61]) =>
    List<int>.filled(length, byte);

/// Builds a complete block stream from [parts] with a [declaredLength] header.
Uint8List block(int declaredLength, List<List<int>> parts) {
  final out = <int>[...varint(declaredLength)];
  for (final part in parts) {
    out.addAll(part);
  }
  return Uint8List.fromList(out);
}
