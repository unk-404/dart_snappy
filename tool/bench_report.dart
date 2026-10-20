/// Converts `benchmark_test --output jsonl` results into the canonical
/// `benchcat/report@1` JSON read by `benchcat.toml`.
///
/// ```sh
/// dart run benchmark_test --output jsonl -c jit bench/dart/snappy_bench.dart \
///     > build/bench/dart-jit.jsonl
/// dart run tool/bench_report.dart \
///     build/bench/dart-jit.jsonl testdata/corpus build/bench/dart-jit.json
/// ```
///
/// Mapping (see `.agents/notes/bench-contract.md`):
///
/// | `benchmark_test` result                 | report row                      |
/// |-----------------------------------------|---------------------------------|
/// | name `compress html`                    | id `compress/html`              |
/// | throughput `ops/sec` × corpus bytes     | value in `MiB/s`                |
/// | `statistics.relativeMarginOfError`      | `stats.rme_pct`                 |
/// | group `compress` / `decompress`         | group `Compress` / `Decompress` |
/// | corpus file size                        | label `html · 100 KiB`          |
///
/// The converter is strict by default: every corpus file must contribute both a
/// compress and a decompress row, so a benchmark that silently disappeared
/// fails CI instead of producing a short chart. `--allow-partial` relaxes that
/// for local `--name` / `--plain-name` filtered runs.
library;

import 'dart:convert';
import 'dart:io';

/// One mebibyte in bytes: `ops/sec × bytes / 2^20` is MiB/s.
const _bytesPerMiB = 1024 * 1024;

/// Files in `testdata/corpus/` that are metadata, not benchmark input.
const _nonCorpusNames = {
  'LICENSE',
  'COPYING',
  'COPYING.notestdata',
  'README.md',
};

const _usage = '''
Usage: dart run tool/bench_report.dart [--allow-partial] <jsonl> <corpus-dir> <out-json>

Converts benchmark_test `--output jsonl` results into a benchcat/report@1
report. Every row must be named "<compress|decompress> <corpus basename>".

By default both directions are required for every corpus file. Pass
--allow-partial to accept a subset (local --name/--plain-name runs).''';

void main(List<String> arguments) {
  var allowPartial = false;
  final positional = <String>[];
  for (final argument in arguments) {
    switch (argument) {
      case '--help' || '-h':
        stdout.writeln(_usage);
        return;
      case '--allow-partial':
        allowPartial = true;
      default:
        if (argument.startsWith('-')) {
          _usageError('unknown option "$argument"');
        }
        positional.add(argument);
    }
  }
  if (positional.length != 3) {
    _usageError('expected 3 arguments, got ${positional.length}');
  }
  final [jsonlPath, corpusPath, outPath] = positional;

  final corpusSizes = _readCorpusSizes(Directory(corpusPath));
  final rows = _readRows(File(jsonlPath), corpusSizes);
  if (!allowPartial) {
    _checkComplete(rows, corpusSizes);
  }
  rows.sort((a, b) {
    final byDirection = a.direction.compareTo(b.direction);
    return byDirection != 0 ? byDirection : a.fileName.compareTo(b.fileName);
  });

  final report = <String, Object?>{
    'schema': 'benchcat/report@1',
    'meta': <String, Object?>{
      'tool': 'snappy_neo',
      'tool_version': _packageVersion(),
      'platform': <String, Object?>{
        'os': _operatingSystemName(),
        'arch': _architectureName(),
        'cores': Platform.numberOfProcessors,
      },
    },
    'benchmarks': [for (final row in rows) row.toJson()],
  };

  final output = File(outPath);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(
    'bench_report: wrote ${rows.length} rows for ${corpusSizes.length} '
    'corpus files to ${output.path}',
  );
}

/// Parses every JSONL record that names a corpus file and direction.
///
/// `benchmark_test` interleaves its test-runner progress with the JSON lines,
/// so anything that does not start with `{` is ignored.
List<_Row> _readRows(File jsonl, Map<String, int> corpusSizes) {
  if (!jsonl.existsSync()) {
    _dataError('jsonl file not found: ${jsonl.path}');
  }
  final rowsById = <String, _Row>{};
  var lineNumber = 0;
  for (final line in _readLines(jsonl)) {
    lineNumber++;
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;

    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (error) {
      _dataError('${jsonl.path}:$lineNumber: invalid JSON: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      _dataError('${jsonl.path}:$lineNumber: expected a JSON object');
    }
    if (decoded['formatVersion'] != 1) {
      _dataError(
        '${jsonl.path}:$lineNumber: unsupported formatVersion '
        '${decoded['formatVersion']} (expected 1)',
      );
    }

    final name = decoded['name'];
    if (name is! String) {
      _dataError('${jsonl.path}:$lineNumber: missing or non-string "name"');
    }
    final space = name.indexOf(' ');
    if (space <= 0 || space == name.length - 1) {
      _dataError(
        '${jsonl.path}:$lineNumber: benchmark name "$name" does not match '
        '"<compress|decompress> <basename>"',
      );
    }
    final direction = name.substring(0, space);
    final fileName = name.substring(space + 1);
    if (direction != 'compress' && direction != 'decompress') {
      _dataError(
        '${jsonl.path}:$lineNumber: unknown direction "$direction" in "$name"',
      );
    }

    final sizeBytes = corpusSizes[fileName];
    if (sizeBytes == null) {
      _dataError(
        '${jsonl.path}:$lineNumber: "$fileName" is not a corpus file in the '
        'given corpus directory',
      );
    }

    final throughput = decoded['throughput'];
    if (throughput is! Map<String, Object?>) {
      _dataError('${jsonl.path}:$lineNumber: missing "throughput" object');
    }
    final opsPerSecond = throughput['value'];
    if (opsPerSecond is! num || !opsPerSecond.isFinite || opsPerSecond <= 0) {
      _dataError(
        '${jsonl.path}:$lineNumber: invalid throughput value $opsPerSecond',
      );
    }
    if (throughput['unit'] != 'ops/sec') {
      _dataError(
        '${jsonl.path}:$lineNumber: unexpected throughput unit '
        '"${throughput['unit']}" (expected "ops/sec")',
      );
    }

    final statistics = decoded['statistics'];
    if (statistics is! Map<String, Object?>) {
      _dataError('${jsonl.path}:$lineNumber: missing "statistics" object');
    }
    final rmePct = statistics['relativeMarginOfError'];
    if (rmePct is! num || !rmePct.isFinite || rmePct < 0) {
      _dataError(
        '${jsonl.path}:$lineNumber: invalid relativeMarginOfError $rmePct',
      );
    }

    final row = _Row(
      direction: direction,
      fileName: fileName,
      group: direction == 'compress' ? 'Compress' : 'Decompress',
      label: '$fileName · ${sizeBytes ~/ 1024} KiB',
      value: _round2(opsPerSecond * sizeBytes / _bytesPerMiB),
      rmePct: _round2(rmePct.toDouble()),
    );
    if (rowsById[row.id] != null) {
      _dataError(
        '${jsonl.path}:$lineNumber: duplicate benchmark id "${row.id}" '
        '(mixed compile types in one file?)',
      );
    }
    rowsById[row.id] = row;
  }
  if (rowsById.isEmpty) {
    _dataError('${jsonl.path}: no benchmark records found');
  }
  return rowsById.values.toList();
}

/// Fails unless every corpus file has a `compress` and a `decompress` row.
void _checkComplete(List<_Row> rows, Map<String, int> corpusSizes) {
  final ids = {for (final row in rows) row.id};
  final missing = <String>[];
  for (final fileName in corpusSizes.keys.toList()..sort()) {
    for (final direction in const ['compress', 'decompress']) {
      final id = '$direction/$fileName';
      if (!ids.contains(id)) missing.add(id);
    }
  }
  if (missing.isNotEmpty) {
    _dataError(
      'incomplete report, ${missing.length} row(s) missing: '
      '${missing.join(', ')}',
    );
  }
}

/// Reads a text file as lines.
///
/// Accepts the UTF-8 written by a shell redirect on Linux/macOS (and by
/// PowerShell 7) and, as a courtesy to Windows PowerShell 5.1, the UTF-16LE
/// with a BOM that its `>` redirection produces.
List<String> _readLines(File file) {
  final bytes = file.readAsBytesSync();
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes, 2, littleEndian: true).split(_lineBreak);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes, 2, littleEndian: false).split(_lineBreak);
  }
  var text = utf8.decode(bytes);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return text.split(_lineBreak);
}

final _lineBreak = RegExp(r'\r?\n');

String _decodeUtf16(List<int> bytes, int start, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  // `fromCharCodes` accepts UTF-16 code units, so surrogate pairs survive.
  return String.fromCharCodes(units);
}

/// Corpus file name -> size in bytes, skipping license/README metadata.
Map<String, int> _readCorpusSizes(Directory directory) {
  if (!directory.existsSync()) {
    _dataError('corpus directory not found: ${directory.path}');
  }
  final sizes = <String, int>{};
  for (final entity in directory.listSync()) {
    if (entity is! File) continue;
    final fileName = entity.uri.pathSegments.last;
    if (_nonCorpusNames.contains(fileName)) continue;
    sizes[fileName] = entity.lengthSync();
  }
  if (sizes.isEmpty) {
    _dataError('no corpus files found in ${directory.path}');
  }
  return sizes;
}

/// Version of this package, read from `pubspec.yaml`.
String _packageVersion() {
  final pubspec = _pubspecFile();
  for (final line in pubspec.readAsLinesSync()) {
    final match = RegExp(r'^version:\s*(\S+)').firstMatch(line);
    if (match != null) return match.group(1)!;
  }
  _dataError('no "version:" line found in ${pubspec.path}');
}

/// `pubspec.yaml` next to the script (`tool/../`) or in the working directory.
File _pubspecFile() {
  final candidates = <Directory>[];
  final script = Platform.script;
  if (script.scheme == 'file') {
    candidates.add(File.fromUri(script).parent.parent);
  }
  candidates.add(Directory.current);
  for (final directory in candidates) {
    final file = File('${directory.path}/pubspec.yaml');
    if (file.existsSync()) return file;
  }
  _dataError(
    'pubspec.yaml not found next to ${Platform.script} or in '
    '${Directory.current.path}',
  );
}

/// `Platform.operatingSystem` in the spelling the report uses.
String _operatingSystemName() {
  if (Platform.isLinux) return 'Linux';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isWindows) return 'Windows';
  return Platform.operatingSystem;
}

/// CPU architecture parsed from `Platform.version` (`... on "windows_x64"`).
String _architectureName() {
  final match = RegExp(r'''\bon\s+['"]([^'"]+)['"]''')
      .firstMatch(Platform.version);
  final identifier = match?.group(1);
  if (identifier == null) return 'unknown';
  final separator = identifier.lastIndexOf('_');
  return separator < 0 ? identifier : identifier.substring(separator + 1);
}

/// Rounds to two decimals: plenty for MiB/s and percentages, and stable JSON.
double _round2(double value) => double.parse(value.toStringAsFixed(2));

Never _usageError(String message) {
  stderr.writeln('bench_report: $message');
  stderr.writeln();
  stderr.writeln(_usage);
  exit(64);
}

Never _dataError(String message) {
  stderr.writeln('bench_report: $message');
  exit(65);
}

/// One canonical report row.
class _Row {
  _Row({
    required this.direction,
    required this.fileName,
    required this.group,
    required this.label,
    required this.value,
    required this.rmePct,
  });

  final String direction;
  final String fileName;
  final String group;
  final String label;
  final double value;
  final double rmePct;

  String get id => '$direction/$fileName';

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'group': group,
    'label': label,
    'unit': 'MiB/s',
    'value': value,
    'direction': 'higher',
    'stats': <String, Object?>{'rme_pct': rmePct},
  };
}
