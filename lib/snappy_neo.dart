/// Support for Google's Snappy compression format.
///
/// Pure Dart, no native dependencies. The block ("raw") format is implemented
/// by [Snappy]; `package:snappy_neo/blit.dart` adds a zero-copy `Bytes` API.
library;

export 'src/codec.dart';
export 'src/snappy.dart';
