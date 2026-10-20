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
  /// chunk is stored compressed only when that is smaller than storing it raw.
  static Uint8List compress(List<int> source) =>
      compressFramed(_asBytes(source));

  /// Decodes a framed stream into a new [Uint8List].
  ///
  /// Throws a [FormatException] for a missing or corrupt stream identifier,
  /// truncated chunks, unskippable unknown chunk types and checksum mismatches.
  static Uint8List decompress(List<int> source) =>
      decompressFramed(_asBytes(source));
}

/// Encodes [source] as a complete framed stream.
Uint8List compressFramed(Uint8List source) {
  final collector = _BytesCollector();
  final sink = _FramingEncoderSink(collector);
  sink.add(source);
  sink.close();
  return collector.take();
}

/// Decodes a complete framed stream.
Uint8List decompressFramed(Uint8List source) {
  final collector = _BytesCollector();
  final sink = _FramingDecoderSink(collector);
  sink.add(source);
  sink.close();
  return collector.take();
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
  const SnappyFramingEncoder();

  @override
  Uint8List convert(List<int> input) => SnappyFraming.compress(input);

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _FramingEncoderSink(sink);
}

/// Streaming decoder for the Snappy framing format.
///
/// Accepts arbitrary slices of a framed stream and emits decoded bytes as soon
/// as a whole chunk is available. [`close`] verifies that the stream did not
/// end in the middle of a chunk and that a stream identifier was present.
class SnappyFramingDecoder extends Converter<List<int>, List<int>> {
  /// Creates a framing decoder.
  const SnappyFramingDecoder();

  @override
  Uint8List convert(List<int> input) => SnappyFraming.decompress(input);

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _FramingDecoderSink(sink);
}

/// A `dart:convert` [Codec] for the Snappy framing format.
class SnappyFramingCodec extends Codec<List<int>, List<int>> {
  /// Creates a framing codec.
  const SnappyFramingCodec();

  @override
  Converter<List<int>, List<int>> get encoder => const SnappyFramingEncoder();

  @override
  Converter<List<int>, List<int>> get decoder => const SnappyFramingDecoder();
}

// ---------------------------------------------------------------------------
// encoder
// ---------------------------------------------------------------------------

final class _FramingEncoderSink implements ByteConversionSink {
  _FramingEncoderSink(this._out);

  final Sink<List<int>> _out;
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
    _pending.append(bytes, start, end);
    while (_pending.length >= _maxChunkSize) {
      _emitChunk(_pending.buffer, 0, _maxChunkSize);
      _pending.removeFirst(_maxChunkSize);
    }
    if (isLast) close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _sendIdentifier();
    if (_pending.length > 0) {
      _emitChunk(_pending.buffer, 0, _pending.length);
      _pending.removeFirst(_pending.length);
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
    final int compressedLength = compressor.compressBlockInto(slice, _scratch);
    // Same policy as the reference implementation: only pay for compression
    // when it saves at least an eighth of the payload.
    final int threshold = length - length ~/ 8;
    final _GrowableBytes chunk;
    if (compressedLength < threshold) {
      chunk = _GrowableBytes(8 + compressedLength)
        ..addByte(_chunkCompressed)
        ..addUint24(4 + compressedLength)
        ..addUint32(checksum)
        ..addBytes(_scratch, 0, compressedLength);
    } else {
      chunk = _GrowableBytes(8 + length)
        ..addByte(_chunkUncompressed)
        ..addUint24(4 + length)
        ..addUint32(checksum)
        ..addBytes(source, start, end);
    }
    _out.add(chunk.take());
  }
}

// ---------------------------------------------------------------------------
// decoder
// ---------------------------------------------------------------------------

final class _FramingDecoderSink implements ByteConversionSink {
  _FramingDecoderSink(this._out);

  final Sink<List<int>> _out;
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
    final int type = buffer[0];
    final int length = buffer[1] | (buffer[2] << 8) | (buffer[3] << 16);
    final int end = 4 + length;
    if (_pending.length < end) return false;
    _handleChunk(type, buffer, 4, end);
    _pending.removeFirst(end);
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
        _verifyChecksum(_scratch, 0, expected, checksum);
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
        _verifyChecksum(data, start + 4, dataLength, checksum);
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

/// Growable byte buffer with the writes the framing format needs.
final class _GrowableBytes {
  _GrowableBytes(int capacity)
    : _buffer = Uint8List(capacity < 16 ? 16 : capacity);

  Uint8List _buffer;
  int _length = 0;

  void addByte(int value) {
    _ensure(1);
    _buffer[_length++] = value & 0xFF;
  }

  void addUint24(int value) {
    _ensure(3);
    _buffer[_length++] = value & 0xFF;
    _buffer[_length++] = (value >>> 8) & 0xFF;
    _buffer[_length++] = (value >>> 16) & 0xFF;
  }

  void addUint32(int value) {
    _ensure(4);
    _buffer[_length++] = value & 0xFF;
    _buffer[_length++] = (value >>> 8) & 0xFF;
    _buffer[_length++] = (value >>> 16) & 0xFF;
    _buffer[_length++] = (value >>> 24) & 0xFF;
  }

  void addBytes(Uint8List source, int start, int end) {
    final int count = end - start;
    if (count <= 0) return;
    _ensure(count);
    _buffer.setRange(_length, _length + count, source, start);
    _length += count;
  }

  Uint8List take() => Uint8List.sublistView(_buffer, 0, _length);

  void _ensure(int extra) {
    final int needed = _length + extra;
    if (needed <= _buffer.length) return;
    var capacity = _buffer.length * 2;
    if (capacity < needed) capacity = needed;
    final next = Uint8List(capacity);
    next.setRange(0, _length, _buffer);
    _buffer = next;
  }
}

/// FIFO byte buffer used to assemble chunks from arbitrary input slices.
final class _ChunkBuffer {
  _ChunkBuffer(int capacity) : _buffer = Uint8List(capacity < 4 ? 4 : capacity);

  Uint8List _buffer;
  int _length = 0;

  int get length => _length;
  Uint8List get buffer => _buffer;

  void append(Uint8List source, int start, int end) {
    final int count = end - start;
    if (count <= 0) return;
    _ensure(count);
    _buffer.setRange(_length, _length + count, source, start);
    _length += count;
  }

  void removeFirst(int count) {
    if (count >= _length) {
      _length = 0;
      return;
    }
    _buffer.setRange(0, _length - count, _buffer, count);
    _length -= count;
  }

  void _ensure(int extra) {
    final int needed = _length + extra;
    if (needed <= _buffer.length) return;
    var capacity = _buffer.length * 2;
    if (capacity < needed) capacity = needed;
    final next = Uint8List(capacity);
    next.setRange(0, _length, _buffer);
    _buffer = next;
  }
}

/// Collects the output of a chunked conversion into one buffer.
final class _BytesCollector implements Sink<List<int>> {
  final _GrowableBytes _bytes = _GrowableBytes(1024);

  @override
  void add(List<int> data) {
    final Uint8List bytes = data is Uint8List ? data : Uint8List.fromList(data);
    _bytes.addBytes(bytes, 0, bytes.length);
  }

  @override
  void close() {}

  Uint8List take() => _bytes.take();
}

Uint8List _asBytes(List<int> source) =>
    source is Uint8List ? source : Uint8List.fromList(source);
