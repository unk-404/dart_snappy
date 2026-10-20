import 'dart:convert';
import 'dart:typed_data';

import 'package:snappy_neo/snappy_neo.dart';

void main() {
  final source = Uint8List.fromList(utf8.encode('snappy ' * 100));
  final compressed = Snappy.compress(source);
  final restored = Snappy.decompress(compressed);

  print('uncompressed: ${source.length} bytes');
  print('compressed:   ${compressed.length} bytes');
  print('restored:     ${restored.length} bytes');
  print('roundtrip ok: ${utf8.decode(restored) == utf8.decode(source)}');
}
