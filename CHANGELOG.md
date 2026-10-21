## 0.2.1

- Requires `blit` 0.2.0. The integration imports the focused core-buffer entry
  `package:blit/blit_buffer.dart` (0.2.0 turned `package:blit/blit.dart` into
  the file-IO API).
- New `BytesMut` helpers `snappyCompressFrom` and `snappyFrameCompressFrom`:
  they reserve the worst case and compress straight into the buffer's spare
  capacity, so composing a larger message out of compressed parts never
  allocates a temporary result.
- New `SnappyFraming.maxCompressedLength` and `SnappyFraming.compressInto`: the
  whole framed stream is written straight into the caller's buffer instead of a
  growable intermediate one. Measured on the corpus: +1.8-21.5% (paper-100k
  +21.5%, fireworks +11.4%, html +4.4%) with byte-identical output. The
  streaming encoder now assembles chunks through `BytesMut.spareView`.
- The block-format hot loops stay on `Uint8List` + `ByteData`: blit's byte
  types are views over the same typed data and only add indirection there, so
  blit owns buffer management while the codec owns the byte-level loops.
- `dart:convert`, the block/framing APIs and the wire formats are unchanged.

## 0.2.0

- **Breaking:** `SnappyEncoder` and `SnappyDecoder` are no longer
  `dart:convert` converters. They are now stateful, allocation-free block
  codecs: `encode`, `encodeInto`, `decode`, `decodeInto`,
  `uncompressedLength`. The `dart:convert` integration lives on
  `SnappyCodec`, whose converters are private implementation details.
- Decode fast path rewritten: LZ77 copies now use `Uint8List.setRange` (a
  memmove intrinsic) instead of 4/8-byte word stores. Non-overlapping copies
  are a single memmove; run-length copies (offset < length) seed the pattern
  and then double it, so every individual move is non-overlapping as well.
  Measured in-process (interleaved A/B): geo +42%, html +29-37%, paper +30%,
  alice +13-31%, kppkn +1-7%.
- `decodeInto` avoids the output allocation entirely, which is the dominant
  cost for literal-heavy input (paper-100k +60%, fireworks +166%).
- Benchmarks now measure the allocation-free path (`encodeInto` /
  `decodeInto` with caller-owned buffers) on both the Dart and the Rust
  reference sides, so the chart compares codec throughput rather than
  allocation behaviour.
- Framing: chunk decoding reuses the same direct-into-buffer decoder.
- Documented performance versus native Snappy: decode reaches 64-127% of a
  C++ 1.3.1 build on text and copy-heavy data (33-69% on literal-heavy data),
  encode reaches 15-42%. A pure Dart encoder cannot match native code
  instruction-for-instruction; see the README for the measured ceilings.

## 0.1.2

- Compression level 2: `level: 2` on `Snappy.compress`, `Snappy.compressInto`,
  `SnappyCodec` / `SnappyEncoder`, `SnappyFraming.compress`,
  `SnappyFramingEncoder` and the `blit` extensions. It uses the reference
  implementation's double-hash matcher, is 7-17% denser than level 1 on
  text-like data, and on the Dart VM produces byte-identical output to C++
  Snappy 1.3.1 level 2 (checked against committed reference streams).
- Framing performance: CRC-32C now uses a slicing-by-8 table (about 3x faster
  than the byte-at-a-time loop); the streaming encoder emits full chunks
  straight from the caller's slice instead of shifting a growing buffer
  (linear instead of quadratic on large inputs); the chunk buffer consumes by
  index instead of memmoving; and the whole-buffer decoder validates the
  layout in one pass, allocates the exact output size and decodes each chunk
  directly into it, with no scratch buffers or double copies.
- `verifyChecksums:` on `SnappyFraming.decompress` and
  `SnappyFramingDecoder` skips the per-chunk CRC when integrity is guaranteed
  by a higher layer; the CRC pass is the dominant cost of framed decode.
- The benchmark chart now covers the framing format as well (28 rows), and
  `tool/bench_report.dart` requires all four directions when converting.

## 0.1.1

- The Snappy framing format: `SnappyFraming.compress` / `SnappyFraming.decompress`
  for whole buffers and streaming `SnappyFramingEncoder` / `SnappyFramingDecoder`
  (`ByteConversionSink`, usable with `Stream.transform`).
- Full chunk support: compressed (`0x00`) and uncompressed (`0x01`) data,
  padding (`0xfe`), reserved skippable chunks (`0x80`-`0xfd`), repeated stream
  identifiers and concatenated streams; reserved unskippable chunks
  (`0x02`-`0x7f`) and checksum mismatches are rejected.
- Masked CRC-32C verification per chunk, with `SnappyFraming.crc32c` and
  `SnappyFraming.maskChecksum` exposed for custom chunk producers.
- `SnappyFramingCodec` for `dart:convert` and `snappyFrameCompress` /
  `snappyFrameDecompress` on blit `Bytes`.
- Framed output is byte-for-byte identical to the Rust `snap` reference encoder,
  and framed streams are cross-checked in both directions in CI.

## 0.1.0

- Initial release: pure Dart implementation of the Snappy block ("raw") format.
- `Snappy.compress`, `Snappy.decompress`, `Snappy.compressInto`,
  `Snappy.decompressInto`, `Snappy.maxCompressedLength` and
  `Snappy.uncompressedLength`.
- `SnappyCodec` for use with `dart:convert`.
- Zero-copy `Bytes` API via `package:snappy_neo/blit.dart`.
- Output on the Dart VM and AOT is byte-for-byte identical to the reference
  Snappy implementations (verified against the Rust `snap` crate in CI). The
  JavaScript build uses a JS-safe hash and may choose different, equally valid,
  matches.
