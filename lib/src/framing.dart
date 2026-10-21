/// The Snappy framing format: chunked streams with masked CRC-32C checksums.
///
/// A framed stream starts with the ten-byte stream identifier
/// (`ff 06 00 00 73 4e 61 50 70 59`) followed by data chunks. Every chunk is a
/// one-byte type, a three-byte little-endian length and the payload. Compressed
/// (`0x00`) and uncompressed (`0x01`) chunks carry the masked CRC-32C of the
/// *uncompressed* bytes; the uncompressed data of one chunk never exceeds
/// [SnappyFraming.maxChunkSize] bytes.
///
/// Both whole-buffer ([SnappyFraming.compress], [SnappyFraming.decompress]) and
/// streaming ([SnappyFramingEncoder], [SnappyFramingDecoder]) entry points are
/// provided.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:blit/blit_buffer.dart';

import 'compress.dart' as compressor;
import 'crc32c.dart' as crc;
import 'decompress.dart' as decompressor;
import 'format.dart';
import 'varint.dart';

const int _maxChunkSize = 65536;

const int _chunkCompressed = 0x00;
const int _chunkUncompressed = 0x01;
const int _chunkPadding = 0xfe;
const int _chunkStreamIdentifier = 0xff;

/// The six bytes a stream identifier chunk carries: `"sNaPpY"`.
const List<int> _identifierPayload = <int>[
  0x73, // 's'
  0x4e, // 'N'
  0x61, // 'a'
  0x50, // 'P'
  0x70, // 'p'
  0x59, // 'Y'
];

/// The ten bytes every framed stream starts with: chunk type `0xff`, a
/// three-byte little-endian length of six, then `"sNaPpY"`.
const List<int> _streamIdentifier = <int>[
  0xff,
  0x06,
  0x00,
  0x00,
  ..._identifierPayload,
];

/// The Snappy framing format.
///
/// ```dart
/// final framed = SnappyFraming.compress(bytes);
/// final restored = SnappyFraming.decompress(framed);
/// ```
///
/// Use this instead of the block format when the stream must be decodable
/// incrementally by another process or when per-chunk integrity checks are
/// wanted. The block format ([Snappy]) is more compact and is what storage
/// formats such as Parquet embed.
abstract final class SnappyFraming {
  /// Largest amount of uncompressed data one chunk may carry (64 KiB).
  static const int maxChunkSize = _maxChunkSize;

  /// The ten bytes a framed stream starts with: type `0xff`, length six,
  /// `"sNaPpY"`.
  static const List<int> streamIdentifier = _streamIdentifier;

  /// CRC-32C (Castagnoli) of [data], as an unsigned 32-bit integer.
  ///
  /// Exposed for producers of custom chunks; [compress] and [decompress] apply
  /// it automatically.
  static int crc32c(List<int> data) => crc.crc32c(_asBytes(data));

  /// Applies the framing checksum mask to a raw CRC-32C value.
  static int maskChecksum(int checksum) => crc.maskChecksum(checksum);

  /// Frames [source] into a new [Uint8List].
  ///
  /// The result starts with the stream identifier and contains as many chunks
  /// as needed, each carrying at most [maxChunkSize] uncompressed bytes. A
  /// chunk is stored compressed only when that saves at least an eighth of the
  /// payload. [level] is 1 (fastest, the default) or 2 (denser and slower).
  static Uint8List compress(List<int> source, {int level = 1}) =>
      compressFramed(_asBytes(source), level: level);

  /// Upper bound for the size of a framed stream of [length] input bytes.
  ///
  /// Each chunk costs an eight-byte header plus at most its own payload, and
  /// the stream starts with the ten-byte identifier.
  static int maxCompressedLength(int length) {
    final int chunks = (length + _maxChunkSize - 1) ~/ _maxChunkSize;
    return _streamIdentifier.length + length + 12 * chunks;
  }

  /// Frames [source] into [destination] and returns the byte count.
  ///
  /// [destination] must hold at least [maxCompressedLength] bytes.
  static int compressInto(
    Uint8List source,
    Uint8List destination, {
    int level = 1,
  }) => compressFramedInto(source, destination, level: level);

  /// Decodes a framed stream into a new [Uint8List].
  ///
  /// Throws a [FormatException] for a missing or corrupt stream identifier,
  /// truncated chunks, unskippable unknown chunk types and checksum mismatches.
  static Uint8List decompress(
    List<int> source, {
    bool verifyChecksums = true,
  }) => decompressFramed(_asBytes(source), verifyChecksums: verifyChecksums);

  /// The total uncompressed length a framed stream declares.
  ///
  /// Validates the chunk layout without decoding any payload.
  static int uncompressedLength(List<int> source) =>
      framedUncompressedLength(_asBytes(source));

  /// Decodes a framed stream into [destination] and returns the byte count.
  ///
  /// [destination] must hold at least [uncompressedLength] bytes.
  static int decompressInto(
    List<int> source,
    Uint8List destination, {
    bool verifyChecksums = true,
  }) => decompressFramedInto(
    _asBytes(source),
    destination,
    verifyChecksums: verifyChecksums,
  );
}

/// Encodes [source] as a complete framed stream.
Uint8List compressFramed(Uint8List source, {int level = 1}) {
  final out = Uint8List(SnappyFraming.maxCompressedLength(source.length));
  final written = compressFramedInto(source, out, level: level);
  return Uint8List.sublistView(out, 0, written);
}

/// Encodes [source] into [destination] and returns the byte count.
///
/// The whole stream is written straight into the caller's buffer: no growable
/// intermediate buffer and no growth copies.
int compressFramedInto(
  Uint8List source,
  Uint8List destination, {
  int level = 1,
}) {
  final int required = SnappyFraming.maxCompressedLength(source.length);
  if (destination.length < required) {
    throw ArgumentError.value(
      destination.length,
      'destination',
      'must be at least $required bytes for ${source.length} input bytes',
    );
  }
  final Uint8List scratch = Uint8List(
    maxCompressedLength(_maxChunkSize) + outputSlop,
  );
  destination.setRange(0, _streamIdentifier.length, _streamIdentifier);
  var op = _streamIdentifier.length;
  for (var start = 0; start < source.length; start += _maxChunkSize) {
    final int end = start + _maxChunkSize <= source.length
        ? start + _maxChunkSize
        : source.length;
    final int length = end - start;
    final int checksum = crc.maskChecksum(crc.crc32cRange(source, start, end));
    final Uint8List slice = Uint8List.sublistView(source, start, end);
    final int compressedLength = compressor.compressBlockInto(
      slice,
      scratch,
      level: level,
    );
    final int chunkLength;
    if (compressedLength < length - length ~/ 8) {
      destination[op] = _chunkCompressed;
      chunkLength = 4 + compressedLength;
    } else {
      destination[op] = _chunkUncompressed;
      chunkLength = 4 + length;
    }
    destination[op + 1] = chunkLength & 0xFF;
    destination[op + 2] = (chunkLength >>> 8) & 0xFF;
    destination[op + 3] = (chunkLength >>> 16) & 0xFF;
    destination[op + 4] = checksum & 0xFF;
    destination[op + 5] = (checksum >>> 8) & 0xFF;
    destination[op + 6] = (checksum >>> 16) & 0xFF;
    destination[op + 7] = (checksum >>> 24) & 0xFF;
    final int payload = chunkLength - 4;
    if (destination[op] == _chunkCompressed) {
      destination.setRange(op + 8, op + 8 + payload, scratch);
    } else {
      destination.setRange(op + 8, op + 8 + payload, source, start);
    }
    op += 8 + payload;
  }
  return op;
}

/// One parsed chunk: type, payload range, declared uncompressed length and
/// stored masked checksum.
typedef _ChunkRef = (
  int type,
  int payloadStart,
  int payloadEnd,
  int expected,
  int checksum,
);

/// Validates the chunk layout of [source] and returns the total uncompressed
/// length together with one reference per data chunk.
(int, List<_ChunkRef>) _parseChunks(Uint8List source) {
  final chunks = <_ChunkRef>[];
  var total = 0;
  var ip = 0;
  var sawIdentifier = false;
  while (ip < source.length) {
    if (ip + 4 > source.length) {
      throw const FormatException('snappy framing: truncated chunk header');
    }
    final int type = source[ip];
    final int length =
        source[ip + 1] | (source[ip + 2] << 8) | (source[ip + 3] << 16);
    final int payloadStart = ip + 4;
    final int payloadEnd = payloadStart + length;
    if (payloadEnd > source.length) {
      throw const FormatException('snappy framing: chunk overruns the stream');
    }
    if (!sawIdentifier && type != _chunkStreamIdentifier) {
      throw const FormatException(
        'snappy framing: stream does not start with the stream identifier',
      );
    }
    switch (type) {
      case _chunkStreamIdentifier:
        if (length != _identifierPayload.length) {
          throw const FormatException(
            'snappy framing: invalid stream identifier length',
          );
        }
        for (var i = 0; i < _identifierPayload.length; i++) {
          if (source[payloadStart + i] != _identifierPayload[i]) {
            throw const FormatException(
              'snappy framing: invalid stream identifier payload',
            );
          }
        }
        sawIdentifier = true;
      case _chunkCompressed:
        if (length < 5) {
          throw const FormatException(
            'snappy framing: compressed chunk is too short',
          );
        }
        final Uint8List block = Uint8List.sublistView(
          source,
          payloadStart + 4,
          payloadEnd,
        );
        final (int expected, _) = readVarint(block, 0);
        if (expected > _maxChunkSize) {
          throw const FormatException(
            'snappy framing: chunk expands beyond the 64 KiB limit',
          );
        }
        chunks.add((
          type,
          payloadStart,
          payloadEnd,
          expected,
          _readUint32(source, payloadStart),
        ));
        total += expected;
      case _chunkUncompressed:
        if (length < 4) {
          throw const FormatException(
            'snappy framing: uncompressed chunk is too short',
          );
        }
        final int dataLength = length - 4;
        if (dataLength > _maxChunkSize) {
          throw const FormatException(
            'snappy framing: chunk is larger than the 64 KiB limit',
          );
        }
        chunks.add((
          type,
          payloadStart,
          payloadEnd,
          dataLength,
          _readUint32(source, payloadStart),
        ));
        total += dataLength;
      case _chunkPadding:
        // Padding carries no meaning; decoders must not inspect the bytes.
        break;
      default:
        if (type <= 0x7f) {
          throw FormatException(
            'snappy framing: unskippable chunk type '
            '0x${type.toRadixString(16).padLeft(2, '0')}',
          );
        }
        // 0x80..0xfd: reserved but skippable.
        break;
    }
    ip = payloadEnd;
  }
  if (!sawIdentifier) {
    throw const FormatException('snappy framing: missing stream identifier');
  }
  return (total, chunks);
}

/// Decodes the parsed [chunks] of [source] into `destination[0, total)`.
///
/// [overCopy] spare bytes after the decoded range may be over-written by the
/// block decoder's fast copy paths.
void _decodeChunks(
  Uint8List source,
  List<_ChunkRef> chunks,
  Uint8List destination, {
  required bool verifyChecksums,
  required int overCopy,
}) {
  var op = 0;
  for (final (type, payloadStart, payloadEnd, expected, checksum) in chunks) {
    if (type == _chunkCompressed) {
      final Uint8List block = Uint8List.sublistView(
        source,
        payloadStart + 4,
        payloadEnd,
      );
      final (_, int blockStart) = readVarint(block, 0);
      decompressor.decodeBlockInto(
        block,
        blockStart,
        destination,
        op,
        expected,
        overCopy,
      );
    } else {
      destination.setRange(op, op + expected, source, payloadStart + 4);
    }
    if (verifyChecksums) {
      _verifyChecksum(destination, op, expected, checksum);
    }
    op += expected;
  }
}

/// The total uncompressed length a framed stream declares.
///
/// Validates the chunk layout (identifiers, lengths and skippable types) without
/// decoding any payload.
int framedUncompressedLength(Uint8List source) => _parseChunks(source).$1;

/// Decodes a complete framed stream into a new [Uint8List].
///
/// The chunk layout is validated and the output sized in a first pass, then
/// every chunk is decoded straight into the final buffer, so a whole-buffer
/// decode performs no intermediate copies.
Uint8List decompressFramed(Uint8List source, {bool verifyChecksums = true}) {
  final (int total, List<_ChunkRef> chunks) = _parseChunks(source);
  final out = Uint8List(total + outputSlop);
  _decodeChunks(
    source,
    chunks,
    out,
    verifyChecksums: verifyChecksums,
    overCopy: outputSlop,
  );
  return Uint8List.sublistView(out, 0, total);
}

/// Decodes a framed stream into [destination] and returns the byte count.
///
/// [destination] must hold at least [framedUncompressedLength] bytes. Only the
/// decoded range is written; bytes after it are left untouched.
int decompressFramedInto(
  Uint8List source,
  Uint8List destination, {
  bool verifyChecksums = true,
}) {
  final (int total, List<_ChunkRef> chunks) = _parseChunks(source);
  if (destination.length < total) {
    throw ArgumentError.value(
      destination.length,
      'destination',
      'must be at least $total bytes for this stream',
    );
  }
  final int spare = destination.length - total;
  _decodeChunks(
    source,
    chunks,
    destination,
    verifyChecksums: verifyChecksums,
    overCopy: spare < outputSlop ? spare : outputSlop,
  );
  return total;
}

/// Streaming encoder for the Snappy framing format.
///
/// Usable as a `Converter` (for example with `Stream.transform`) or directly
/// through [startChunkedConversion]. Input is buffered into 64 KiB chunks; a
/// chunk is emitted as soon as it is complete, so the encoder never holds more
/// than one chunk plus the current input event in memory.
///
/// ```dart
/// final sink = const SnappyFramingEncoder()
///     .startChunkedConversion(ByteConversionSink.withCallback(...));
/// sink.add(part1);
/// sink.add(part2);
/// sink.close();
/// ```
class SnappyFramingEncoder extends Converter<List<int>, List<int>> {
  /// Creates a framing encoder.
  ///
  /// [level] is 1 (fastest, the default) or 2 (denser and slower).
  const SnappyFramingEncoder({this.level = 1});

  /// Compression level used for each chunk.
  final int level;

  @override
  Uint8List convert(List<int> input) =>
      SnappyFraming.compress(input, level: level);

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _FramingEncoderSink(sink, level);
}

/// Streaming decoder for the Snappy framing format.
///
/// Accepts arbitrary slices of a framed stream and emits decoded bytes as soon
/// as a whole chunk is available. Calling `close()` verifies that the stream
/// did not end in the middle of a chunk and that a stream identifier was
/// present.
class SnappyFramingDecoder extends Converter<List<int>, List<int>> {
  /// Creates a framing decoder.
  ///
  /// [verifyChecksums] may be set to false to skip the per-chunk CRC-32C
  /// verification (roughly halves decode time). Only do that for streams whose
  /// integrity is guaranteed by another layer.
  const SnappyFramingDecoder({this.verifyChecksums = true});

  /// Whether each chunk's masked CRC-32C is verified.
  final bool verifyChecksums;

  @override
  Uint8List convert(List<int> input) =>
      SnappyFraming.decompress(input, verifyChecksums: verifyChecksums);

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _FramingDecoderSink(sink, verifyChecksums);
}

/// A `dart:convert` [Codec] for the Snappy framing format.
class SnappyFramingCodec extends Codec<List<int>, List<int>> {
  /// Creates a framing codec.
  ///
  /// [level] is 1 (fastest, the default) or 2 (denser and slower); it only
  /// affects encoding.
  const SnappyFramingCodec({this.level = 1, this.verifyChecksums = true});

  /// Compression level used by [encoder].
  final int level;

  /// Whether [decoder] verifies each chunk's masked CRC-32C.
  final bool verifyChecksums;

  @override
  Converter<List<int>, List<int>> get encoder =>
      SnappyFramingEncoder(level: level);

  @override
  Converter<List<int>, List<int>> get decoder =>
      SnappyFramingDecoder(verifyChecksums: verifyChecksums);
}

// ---------------------------------------------------------------------------
// encoder
// ---------------------------------------------------------------------------

final class _FramingEncoderSink implements ByteConversionSink {
  _FramingEncoderSink(this._out, this._level);

  final Sink<List<int>> _out;
  final int _level;
  final _ChunkBuffer _pending = _ChunkBuffer(_maxChunkSize);
  final Uint8List _scratch = Uint8List(
    maxCompressedLength(_maxChunkSize) + outputSlop,
  );
  bool _identifierSent = false;
  bool _closed = false;

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_closed) {
      throw StateError('SnappyFramingEncoder: sink is already closed');
    }
    _sendIdentifier();
    final Uint8List bytes = chunk is Uint8List
        ? chunk
        : Uint8List.fromList(chunk);
    var cursor = start;

    // Complete a partially buffered chunk first.
    if (_pending.length > 0) {
      final int needed = _maxChunkSize - _pending.length;
      final int take = end - cursor < needed ? end - cursor : needed;
      _pending.append(bytes, cursor, cursor + take);
      cursor += take;
      if (_pending.length == _maxChunkSize) {
        _emitChunk(
          _pending.buffer,
          _pending.start,
          _pending.start + _maxChunkSize,
        );
        _pending.clear();
      }
    }

    // Emit full chunks straight from the caller's buffer: no copy, no shifting.
    while (cursor + _maxChunkSize <= end) {
      _emitChunk(bytes, cursor, cursor + _maxChunkSize);
      cursor += _maxChunkSize;
    }
    if (cursor < end) _pending.append(bytes, cursor, end);
    if (isLast) close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _sendIdentifier();
    if (_pending.length > 0) {
      _emitChunk(
        _pending.buffer,
        _pending.start,
        _pending.start + _pending.length,
      );
      _pending.clear();
    }
    _out.close();
  }

  void _sendIdentifier() {
    if (_identifierSent) return;
    _identifierSent = true;
    _out.add(Uint8List.fromList(_streamIdentifier));
  }

  void _emitChunk(Uint8List source, int start, int end) {
    final int length = end - start;
    final int checksum = crc.maskChecksum(crc.crc32cRange(source, start, end));
    final Uint8List slice = Uint8List.sublistView(source, start, end);
    final int compressedLength = compressor.compressBlockInto(
      slice,
      _scratch,
      level: _level,
    );
    // Same policy as the reference implementation: only pay for compression
    // when it saves at least an eighth of the payload.
    final int threshold = length - length ~/ 8;
    final bool compressed = compressedLength < threshold;
    final int payload = compressed ? compressedLength : length;
    final BytesMut chunk = BytesMut(8 + payload);
    final Uint8List view = chunk.spareView(8 + payload);
    final int chunkLength = 4 + payload;
    view[0] = compressed ? _chunkCompressed : _chunkUncompressed;
    view[1] = chunkLength & 0xFF;
    view[2] = (chunkLength >>> 8) & 0xFF;
    view[3] = (chunkLength >>> 16) & 0xFF;
    view[4] = checksum & 0xFF;
    view[5] = (checksum >>> 8) & 0xFF;
    view[6] = (checksum >>> 16) & 0xFF;
    view[7] = (checksum >>> 24) & 0xFF;
    if (compressed) {
      view.setRange(8, 8 + payload, _scratch);
    } else {
      view.setRange(8, 8 + payload, source, start);
    }
    chunk.advance(8 + payload);
    _out.add(chunk.freeze().asUint8List());
  }
}

// ---------------------------------------------------------------------------
// decoder
// ---------------------------------------------------------------------------

final class _FramingDecoderSink implements ByteConversionSink {
  _FramingDecoderSink(this._out, this._verifyChecksums);

  final Sink<List<int>> _out;
  final bool _verifyChecksums;
  final _ChunkBuffer _pending = _ChunkBuffer(4096);
  final Uint8List _scratch = Uint8List(_maxChunkSize + outputSlop);
  bool _sawIdentifier = false;
  bool _closed = false;

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_closed) {
      throw StateError('SnappyFramingDecoder: sink is already closed');
    }
    final Uint8List bytes = chunk is Uint8List
        ? chunk
        : Uint8List.fromList(chunk);
    _pending.append(bytes, start, end);
    while (_processAvailableChunk()) {}
    if (isLast) close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_pending.length > 0) {
      throw const FormatException('snappy framing: truncated chunk');
    }
    if (!_sawIdentifier) {
      throw const FormatException('snappy framing: missing stream identifier');
    }
    _out.close();
  }

  /// Decodes one chunk if the whole chunk is buffered.
  bool _processAvailableChunk() {
    if (_pending.length < 4) return false;
    final Uint8List buffer = _pending.buffer;
    final int at = _pending.start;
    final int type = buffer[at];
    final int length =
        buffer[at + 1] | (buffer[at + 2] << 8) | (buffer[at + 3] << 16);
    final int end = 4 + length;
    if (_pending.length < end) return false;
    _handleChunk(type, buffer, at + 4, at + end);
    _pending.consume(end);
    return true;
  }

  void _handleChunk(int type, Uint8List data, int start, int end) {
    final int length = end - start;
    if (!_sawIdentifier && type != _chunkStreamIdentifier) {
      throw const FormatException(
        'snappy framing: stream does not start with the stream identifier',
      );
    }
    switch (type) {
      case _chunkStreamIdentifier:
        if (length != _identifierPayload.length) {
          throw const FormatException(
            'snappy framing: invalid stream identifier length',
          );
        }
        for (var i = 0; i < _identifierPayload.length; i++) {
          if (data[start + i] != _identifierPayload[i]) {
            throw const FormatException(
              'snappy framing: invalid stream identifier payload',
            );
          }
        }
        _sawIdentifier = true;
      case _chunkCompressed:
        if (length < 5) {
          throw const FormatException(
            'snappy framing: compressed chunk is too short',
          );
        }
        final int checksum = _readUint32(data, start);
        final Uint8List block = Uint8List.sublistView(data, start + 4, end);
        final (int expected, int blockStart) = readVarint(block, 0);
        if (expected > _maxChunkSize) {
          throw const FormatException(
            'snappy framing: chunk expands beyond the 64 KiB limit',
          );
        }
        decompressor.decodeBlock(
          block,
          blockStart,
          _scratch,
          expected,
          outputSlop,
        );
        if (_verifyChecksums) _verifyChecksum(_scratch, 0, expected, checksum);
        _out.add(
          Uint8List.fromList(Uint8List.sublistView(_scratch, 0, expected)),
        );
      case _chunkUncompressed:
        if (length < 4) {
          throw const FormatException(
            'snappy framing: uncompressed chunk is too short',
          );
        }
        final int dataLength = length - 4;
        if (dataLength > _maxChunkSize) {
          throw const FormatException(
            'snappy framing: chunk is larger than the 64 KiB limit',
          );
        }
        final int checksum = _readUint32(data, start);
        if (_verifyChecksums) {
          _verifyChecksum(data, start + 4, dataLength, checksum);
        }
        _out.add(
          Uint8List.fromList(
            Uint8List.sublistView(data, start + 4, start + 4 + dataLength),
          ),
        );
      case _chunkPadding:
        // Padding carries no meaning; decoders must not inspect the bytes.
        break;
      default:
        if (type <= 0x7f) {
          throw FormatException(
            'snappy framing: unskippable chunk type '
            '0x${type.toRadixString(16).padLeft(2, '0')}',
          );
        }
        // 0x80..0xfd: reserved but skippable.
        break;
    }
  }
}

int _readUint32(Uint8List source, int offset) =>
    source[offset] |
    (source[offset + 1] << 8) |
    (source[offset + 2] << 16) |
    source[offset + 3] * 0x1000000;

void _verifyChecksum(Uint8List data, int start, int length, int stored) {
  final int actual = crc.maskChecksum(
    crc.crc32cRange(data, start, start + length),
  );
  if (actual != stored) {
    throw FormatException(
      'snappy framing: checksum mismatch '
      '(stored 0x${stored.toRadixString(16)}, actual 0x${actual.toRadixString(16)})',
    );
  }
}

// ---------------------------------------------------------------------------
// buffers
// ---------------------------------------------------------------------------

/// FIFO byte buffer used to assemble chunks from arbitrary input slices.
///
/// Consumed bytes advance a start index instead of shifting the buffer, so
/// draining many chunks from a large input slice stays linear.
final class _ChunkBuffer {
  _ChunkBuffer(int capacity) : _buffer = Uint8List(capacity < 4 ? 4 : capacity);

  Uint8List _buffer;
  int _start = 0;
  int _length = 0;

  int get length => _length;
  Uint8List get buffer => _buffer;
  int get start => _start;

  void append(Uint8List source, int from, int to) {
    final int count = to - from;
    if (count <= 0) return;
    final int needed = _length + count;
    if (_start + needed > _buffer.length) {
      if (needed <= _buffer.length) {
        // Compact in place: enough capacity, just not contiguous.
        _buffer.setRange(0, _length, _buffer, _start);
      } else {
        var capacity = _buffer.length * 2;
        if (capacity < needed) capacity = needed;
        final next = Uint8List(capacity);
        next.setRange(0, _length, _buffer, _start);
        _buffer = next;
      }
      _start = 0;
    }
    _buffer.setRange(_start + _length, _start + _length + count, source, from);
    _length += count;
  }

  /// Drops [count] bytes from the front.
  void consume(int count) {
    _length -= count;
    if (_length == 0) {
      _start = 0;
    } else {
      _start += count;
    }
  }

  /// Drops everything.
  void clear() {
    _start = 0;
    _length = 0;
  }
}

Uint8List _asBytes(List<int> source) =>
    source is Uint8List ? source : Uint8List.fromList(source);
