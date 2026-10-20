import 'dart:io';

import 'package:snappy_neo/snappy_neo.dart';

/// Compresses every corpus file with the Dart implementation.
///
/// The output directory is what `snappy-oracle verify` consumes in CI:
///
/// ```sh
/// dart run tool/write_dart_compressed.dart testdata/corpus build/bench/dart-compressed
/// snappy-oracle verify --corpus testdata/corpus --compressed build/bench/dart-compressed
/// ```
void main(List<String> args) {
  final corpus = Directory(args.isNotEmpty ? args[0] : 'testdata/corpus');
  final output = Directory(
    args.length > 1 ? args[1] : 'build/bench/dart-compressed',
  );

  if (!corpus.existsSync()) {
    stderr.writeln('corpus directory not found: ${corpus.path}');
    exitCode = 2;
    return;
  }
  output.createSync(recursive: true);

  final files =
      corpus
          .listSync()
          .whereType<File>()
          .where((file) => !_isMetadata(file))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    stderr.writeln('no corpus files in ${corpus.path}');
    exitCode = 2;
    return;
  }

  for (final file in files) {
    final source = file.readAsBytesSync();
    final compressed = Snappy.compress(source);
    final name = file.uri.pathSegments.last;
    File('${output.path}/$name.snappy').writeAsBytesSync(compressed);
    stdout.writeln(
      '$name: ${source.length} -> ${compressed.length} bytes '
      '(${(compressed.length / source.length).toStringAsFixed(3)})',
    );
  }
}

bool _isMetadata(File file) {
  final name = file.uri.pathSegments.last;
  return name.startsWith('README') || name.startsWith('LICENSE');
}
