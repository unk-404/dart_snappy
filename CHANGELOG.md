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
