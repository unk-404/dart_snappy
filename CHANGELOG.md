## 0.1.0

- Initial release: pure Dart implementation of the Snappy block ("raw") format.
- `Snappy.compress`, `Snappy.decompress`, `Snappy.compressInto`,
  `Snappy.decompressInto`, `Snappy.maxCompressedLength` and
  `Snappy.uncompressedLength`.
- `SnappyCodec` for use with `dart:convert`.
- Zero-copy `Bytes` API via `package:snappy_neo/blit.dart`.
- Output is byte-for-byte identical to the reference Snappy implementations
  (verified against the Rust `snap` crate in CI).
