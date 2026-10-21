/// Zero-copy Snappy operations over blit's `UnsafeBytes` external memory.
///
/// `UnsafeBytes` (blit 0.2.1) is memory outside the Dart heap: a `malloc`
/// allocation on native platforms and a WebAssembly arena on the web. Codec
/// output can be produced there without a garbage-collected allocation, which
/// matters for large or literal-heavy payloads, and the buffers can be handed
/// to native I/O (`AsyncFile.readAtUnsafe` / `writeAtUnsafe`) without a copy.
///
/// ```dart
/// import 'package:blit/unsafe.dart';
/// import 'package:snappy_neo/unsafe.dart';
///
/// final source = UnsafeBytes.alloc(payload.length);
/// source.view(payload.length).setRange(0, payload.length, payload);
///
/// final compressed = source.snappyCompress(payload.length);
/// final restored = compressed.memory.snappyDecompress(compressed.length);
/// print(restored.bytes); // Uint8List view over external memory
///
/// source.free();
/// compressed.free();
/// restored.free();
/// ```
///
/// The views are owned by the `UnsafeBytes` handles: call [SnappyMemory.free]
/// when done and do not use a view after that. On the web the arena is shared
/// and may move, so do not retain views across further allocations.
library;

import 'dart:typed_data';

import 'package:blit/unsafe.dart';

import 'src/framing.dart';
import 'src/snappy.dart';

/// Codec output that owns external memory.
///
/// [bytes] is a zero-copy view over [length] valid bytes inside [memory].
final class SnappyMemory {
  SnappyMemory._(this.memory, this.length, this.capacity)
    : bytes = memory.view(length);

  /// The owning allocation; pass it to [free] or to native I/O.
  final UnsafeBytes memory;

  /// Zero-copy view over the valid bytes.
  final Uint8List bytes;

  /// Number of valid bytes in [bytes].
  final int length;

  /// Bytes actually allocated (at least [length]).
  final int capacity;

  /// Releases the external allocation. Views into [bytes] become invalid.
  void free() => memory.free();

  @override
  String toString() => 'SnappyMemory(length: $length, capacity: $capacity)';
}

/// Snappy operations on blit's external-memory `UnsafeBytes` handles.
///
/// Every method takes the byte length explicitly because an `UnsafeBytes`
/// handle stores only an address.
extension SnappyUnsafeBytesExtension on UnsafeBytes {
  /// The uncompressed length declared by the block stream in this memory.
  int snappyUncompressedLength(int length) =>
      Snappy.uncompressedLength(view(length));

  /// Compresses [length] bytes of this memory into [destination].
  ///
  /// [destinationLength] is the capacity of [destination]; it must be at least
  /// `Snappy.maxCompressedLength(length)`. Returns the bytes written.
  int snappyCompressInto(
    int length,
    UnsafeBytes destination,
    int destinationLength, {
    int level = 1,
  }) => Snappy.compressInto(
    view(length),
    destination.view(destinationLength),
    level: level,
  );

  /// Decompresses the block stream of [length] bytes into [destination].
  ///
  /// Returns the bytes written.
  int snappyDecompressInto(
    int length,
    UnsafeBytes destination,
    int destinationLength,
  ) => Snappy.decompressInto(view(length), destination.view(destinationLength));

  /// Compresses [length] bytes of this memory into a new external allocation.
  SnappyMemory snappyCompress(int length, {int level = 1}) {
    final int capacity = Snappy.maxCompressedLength(length);
    final UnsafeBytes buffer = UnsafeBytes.alloc(capacity < 1 ? 1 : capacity);
    final int written = Snappy.compressInto(
      view(length),
      buffer.view(capacity),
      level: level,
    );
    return SnappyMemory._(buffer, written, capacity);
  }

  /// Decompresses the block stream of [length] bytes into new external memory.
  SnappyMemory snappyDecompress(int length) {
    final Uint8List input = view(length);
    final int total = Snappy.uncompressedLength(input);
    final int capacity = total < 1 ? 1 : total;
    final UnsafeBytes buffer = UnsafeBytes.alloc(capacity);
    final int written = Snappy.decompressInto(input, buffer.view(total));
    return SnappyMemory._(buffer, written, capacity);
  }

  /// Frames [length] bytes of this memory into [destination].
  ///
  /// [destinationLength] must be at least `SnappyFraming.maxCompressedLength`.
  int snappyFrameCompressInto(
    int length,
    UnsafeBytes destination,
    int destinationLength, {
    int level = 1,
  }) => SnappyFraming.compressInto(
    view(length),
    destination.view(destinationLength),
    level: level,
  );

  /// Decompresses the framed stream of [length] bytes into [destination].
  int snappyFrameDecompressInto(
    int length,
    UnsafeBytes destination,
    int destinationLength, {
    bool verifyChecksums = true,
  }) => SnappyFraming.decompressInto(
    view(length),
    destination.view(destinationLength),
    verifyChecksums: verifyChecksums,
  );

  /// Frames [length] bytes of this memory into a new external allocation.
  SnappyMemory snappyFrameCompress(int length, {int level = 1}) {
    final int capacity = SnappyFraming.maxCompressedLength(length);
    final UnsafeBytes buffer = UnsafeBytes.alloc(capacity < 1 ? 1 : capacity);
    final int written = SnappyFraming.compressInto(
      view(length),
      buffer.view(capacity),
      level: level,
    );
    return SnappyMemory._(buffer, written, capacity);
  }

  /// Decompresses the framed stream of [length] bytes into new external memory.
  SnappyMemory snappyFrameDecompress(
    int length, {
    bool verifyChecksums = true,
  }) {
    final Uint8List input = view(length);
    final int total = SnappyFraming.uncompressedLength(input);
    final int capacity = total < 1 ? 1 : total;
    final UnsafeBytes buffer = UnsafeBytes.alloc(capacity);
    final int written = SnappyFraming.decompressInto(
      input,
      buffer.view(total),
      verifyChecksums: verifyChecksums,
    );
    return SnappyMemory._(buffer, written, capacity);
  }
}
