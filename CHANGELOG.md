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
