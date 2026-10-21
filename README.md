# snappy_neo

[![CI](https://github.com/unk-404/dart_snappy/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/unk-404/dart_snappy/actions/workflows/ci.yml)

A pure Dart implementation of [Google's Snappy](https://github.com/google/snappy)
compression format: fast, allocation-light, and with no native dependencies.

[Snappy]: https://github.com/google/snappy

- **Block format** (the "raw" format used by Parquet, RPC payloads and key-value
  stores): `Snappy.compress`, `Snappy.decompress`, `Snappy.compressInto`,
  `Snappy.decompressInto` and `Snappy.uncompressedLength`.
- **Framing format** (chunked streams with masked CRC-32C): `SnappyFraming` for
  whole buffers, plus streaming `SnappyFramingEncoder` / `SnappyFramingDecoder`
  that accept arbitrary slices of input.
- **`SnappyCodec`** and **`SnappyFramingCodec`** for `dart:convert`.
- **Zero-copy `Bytes` API** backed by [`blit`](https://pub.dev/packages/blit).
- **Portable**: Dart VM, AOT executables and the web (the codec avoids 64-bit
  integer semantics and is covered by `dart test -p chrome`).
- **Interoperable**: on the Dart VM and in AOT builds the output is byte-for-byte
  identical to the reference implementation, and every release is cross-checked
  in CI against the Rust [`snap`](https://crates.io/crates/snap) crate in both
  directions. The JavaScript build uses a JS-safe hash, so it may emit a
  different (still valid, similarly sized) encoding.

## Status

`0.1.1` implements the block format and the [framing format][framing]: stream
identifier, compressed/uncompressed/padding/skippable chunks, masked CRC-32C
verification, 64 KiB chunking and streaming encoders and decoders.

[framing]: https://github.com/google/snappy/blob/main/framing_format.txt

## Usage

```dart
import 'package:snappy_neo/snappy_neo.dart';

final compressed = Snappy.compress(bytes);            // Uint8List
final restored = Snappy.decompress(compressed);       // Uint8List

final denser = Snappy.compress(bytes, level: 2);      // slower, ~7-17% smaller
```

Write into a buffer you own (no allocation inside the call):

```dart
final output = Uint8List(Snappy.maxCompressedLength(bytes.length));
final written = Snappy.compressInto(bytes, output);        // level defaults to 1
```

### Performance-first API (0.2.0)

`SnappyEncoder` and `SnappyDecoder` are reusable, allocation-free codec
objects. `encodeInto` / `decodeInto` write into buffers you own, which is
10-160% faster than the allocating convenience functions:

```dart
const encoder = SnappyEncoder();
const decoder = SnappyDecoder();

final compressed = Uint8List(Snappy.maxCompressedLength(bytes.length));
final written = encoder.encodeInto(bytes, compressed);
final payload = Uint8List(Snappy.uncompressedLength(compressed));
decoder.decodeInto(compressed, payload);   // returns the byte count
```

`SnappyEncoder` and `SnappyDecoder` were `dart:convert` converters before
0.2.0; that integration now lives on `SnappyCodec` only.

`dart:convert` integration:

```dart
import 'dart:convert';
import 'package:snappy_neo/snappy_neo.dart';

const codec = SnappyCodec();
final encoded = codec.encode(utf8.encode('hello'));
final text = utf8.decode(codec.decode(encoded));
```

### Framing format

The framing format is the one to use for files, sockets and anything decoded
incrementally: it splits the input into 64 KiB chunks, stores a masked CRC-32C
per chunk and lets a decoder work without holding the whole stream in memory.

```dart
final framed = SnappyFraming.compress(bytes);
final restored = SnappyFraming.decompress(framed);

// Skip per-chunk CRC verification only when another layer guarantees integrity.
final unchecked = SnappyFraming.decompress(framed, verifyChecksums: false);
```

Streaming, with input arriving in arbitrary slices:

```dart
final sink = const SnappyFramingEncoder().startChunkedConversion(
  ByteConversionSink.withCallback((chunk) => output.add(chunk)),
);
sink.add(part1);
sink.add(part2);
sink.close();
```

`SnappyFramingEncoder` and `SnappyFramingDecoder` are `Converter`s, so they also
work with `Stream.transform`.

### Zero-copy `Bytes`

```dart
import 'package:blit/bytes.dart';
import 'package:snappy_neo/blit.dart';

final payload = Bytes.view(backingStore, offset, length); // no copy
final compressed = payload.snappyCompress();              // Bytes, no copy on read
final restored = compressed.snappyDecompress();

final framed = payload.snappyFrameCompress();             // framing format
final unpacked = framed.snappyFrameDecompress();
```

## API

| Member | Description |
|---|---|
| `Snappy.maxCompressedLength(int)` | Upper bound for an input of that size |
| `Snappy.uncompressedLength(List<int>)` | Parses the stream header only |
| `Snappy.compress(List<int>)` | Compresses into a new `Uint8List` |
| `Snappy.compressInto(List<int>, Uint8List)` | Compresses into your buffer, returns bytes written |
| `Snappy.decompress(List<int>)` | Decompresses into a new `Uint8List` |
| `Snappy.decompressInto(List<int>, Uint8List)` | Decompresses into your buffer, returns bytes written |
| `SnappyEncoder` / `SnappyDecoder` | Reusable codecs with `encodeInto` / `decodeInto` (no allocation) |
| `SnappyCodec` | `dart:convert` integration (its converters are private) |
| `SnappyFraming.compress` / `decompress` | Whole-buffer framing format |
| `SnappyFramingEncoder` / `SnappyFramingDecoder` | Streaming framing conversion |
| `SnappyFramingCodec` | `dart:convert` integration for framed streams |
| `SnappyFraming.crc32c` / `maskChecksum` | Checksum helpers for custom chunks |
| `level:` on the compress entry points | 1 (fastest, default) or 2 (denser) |
| `verifyChecksums:` on framed decode | Skip the per-chunk CRC (default `true`) |

Invalid streams throw `FormatException`; a destination buffer that is too small
throws `ArgumentError`.

## Performance

Measured on one Windows x64 core with the same 100–180 KiB corpus used by the CI
chart (MiB/s, higher is better; the Rust column is the reference `snap` crate
running the same files):

Block format, allocation-free path on both sides (`SnappyEncoder.encodeInto` /
`SnappyDecoder.decodeInto` versus `snap::raw::Encoder::compress` /
`Decoder::decompress` with reused buffers), MiB/s:

| corpus | Dart compress | Rust compress | Dart decompress | Rust decompress |
|---|---:|---:|---:|---:|
| alice29.txt (text) | 134 | 588 | 477 | 1717 |
| asyoulik.txt (text) | 135 | 634 | 478 | 1532 |
| fireworks.jpeg | 3543 | 38734 | 34741 | 45207 |
| geo.protodata | 529 | 2612 | 1486 | 5721 |
| html | 424 | 2205 | 1259 | 4403 |
| kppkn.gtb | 218 | 872 | 586 | 1717 |
| paper-100k.pdf | 1738 | 14844 | 8354 | 24599 |

Framing format (`SnappyFraming`, masked CRC-32C included), MiB/s:

| corpus | Dart compress | Rust compress | Dart decompress | Rust decompress |
|---|---:|---:|---:|---:|
| alice29.txt | 93 | 255 | 202 | 462 |
| asyoulik.txt | 109 | 344 | 194 | 863 |
| fireworks.jpeg | 589 | 4272 | 593 | 3572 |
| geo.protodata | 297 | 1135 | 325 | 1723 |
| html | 195 | 1160 | 318 | 1619 |
| kppkn.gtb | 117 | 531 | 204 | 791 |
| paper-100k.pdf | 385 | 2756 | 518 | 2818 |

Framing costs one CRC-32C pass over the uncompressed data on each side. When a
higher layer already guarantees integrity, `SnappyFraming.decompress(...,
verifyChecksums: false)` (or `SnappyFramingDecoder(verifyChecksums: false)`)
skips the check, which is the dominant cost of framed decode.

Compression level 2 (`Snappy.compress(bytes, level: 2)`) is slower but denser:
it typically saves another 7–17% on text-like data (on the corpus above:
alice29 −9.6%, kppkn −17.3%, html −7.2%, geo −6.9%). On the VM its output is
byte-for-byte identical to C++ Snappy 1.3.1's level 2, which is checked against
committed reference streams in `testdata/golden-level2`.

### Versus native Snappy

Best-of isolated loops on the same machine (Windows x64 for Dart, the same CPU
under WSL for a locally built C++ Snappy 1.3.1), allocation-free path on the
Dart side:

| corpus | Dart compress / C++ | Dart decompress / C++ |
|---|---:|---:|
| alice29.txt (text) | 42% | 127% |
| html | 24% | 64% |
| geo.protodata | 26% | 74% |
| kppkn.gtb | 36% | 102% |
| paper-100k.pdf | 17% | 69% |
| fireworks.jpeg | 15% | 33% |

Decode lands at 64-127% of native on text and copy-heavy data (33-69% on
literal-heavy data, where Dart's memmove is the limit). Encode lands at
15-42%: Snappy's encoder is a per-byte hash-probe loop, and every typed-data
access and 64-bit arithmetic op costs a Dart VM instruction where native code
uses a handful of cycles. There is no SIMD or unaligned 64-bit load primitive
in Dart, so a pure Dart encoder cannot approach native code instruction for
instruction. The decode path benefits from `setRange`, which compiles to a
memmove intrinsic, which is why it gets much closer.

The CI chart below measures the same allocation-free path on both sides.
![Snappy block and framing throughput on the CI runner: Dart JIT, Dart AOT and Rust snap](https://raw.githubusercontent.com/unk-404/dart_snappy/master/assets/benchmarks.svg)

The chart is regenerated by CI after every push to `master` from
[`benchmark_test`](https://pub.dev/packages/benchmark_test) runs (Dart JIT and
AOT) plus the Rust oracle, rendered with
[benchcat](https://github.com/unk-404/benchcat). Numbers come from the ambient
CI runner, so treat them as a trend rather than a specification; a busy
developer machine can move a single run by a factor of two either way.

Reproduce locally:

```sh
dart run benchmark_test --output jsonl -c jit bench/dart/snappy_bench.dart > build/bench/dart-jit.jsonl
dart run tool/bench_report.dart build/bench/dart-jit.jsonl testdata/corpus build/bench/dart-jit.json
```

## Correctness

- Hand-built format vectors for every tag type, literal/offset boundary and
  malformed-stream class, plus roundtrips over deterministic random, text,
  binary and mixed data from 0 bytes to several MiB.
- `test/golden_test.dart` decodes block and framed streams produced by the
  Rust `snap` crate, and checks level 2 against C++ Snappy 1.3.1 reference
  streams byte for byte.
- `test/interop_test.dart` and `test/framing_interop_test.dart` run the
  reference implementation in both directions and assert byte-identical output
  for both formats (requires `SNAPPY_ORACLE`, built from `bench/rust`).
- The framing tests cover every chunk type (compressed, uncompressed, padding,
  skippable, repeated stream identifier), checksum mismatches, truncation, the
  64 KiB chunk limit and streaming input split at arbitrary boundaries.

Sample data in `testdata/corpus` comes from the Snappy project and is covered by
its BSD-3-Clause test-data license (`testdata/corpus/LICENSE`).

## License

BSD-3-Clause. Snappy itself is Apache-2.0; this package is an independent pure
Dart implementation of the format.
