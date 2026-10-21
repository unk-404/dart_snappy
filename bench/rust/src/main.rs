//! Reference Snappy oracle for the `snappy_neo` Dart package.
//!
//! Subcommands:
//!   * `gen    --corpus DIR --out DIR [--only a,b,c]`
//!       Write reference-compressed `<name>.snappy` files.
//!   * `verify --corpus DIR --compressed DIR`
//!       Decode every `<name>.snappy` produced by the Dart package and compare
//!       it with the corpus file; exit non-zero on mismatch.
//!   * `gen-frame    --corpus DIR --out DIR [--only a,b,c]`
//!       Write reference *framed* `<name>.sz` files (stream identifier +
//!       chunked payload with masked CRC-32C).
//!   * `verify-frame --corpus DIR --compressed DIR`
//!       Decode every `<name>.sz` produced by the Dart package and compare it
//!       with the corpus file.
//!   * `bench  --corpus DIR --out FILE`
//!       Measure compress/decompress throughput and write a
//!       `benchcat/report@1` JSON document.

use std::env;
use std::fs;
use std::hint::black_box;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

const MIB: f64 = 1024.0 * 1024.0;
const BENCH_DURATION: Duration = Duration::from_millis(300);

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let Some(command) = args.first() else {
        eprintln!("usage: snappy-oracle <gen|verify|gen-frame|verify-frame|bench> [options]");
        return ExitCode::FAILURE;
    };
    let result = match command.as_str() {
        "gen" => cmd_gen(&args[1..]),
        "verify" => cmd_verify(&args[1..]),
        "gen-frame" => cmd_gen_frame(&args[1..]),
        "verify-frame" => cmd_verify_frame(&args[1..]),
        "bench" => cmd_bench(&args[1..]),
        other => {
            eprintln!("unknown command: {other}");
            Err(())
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(()) => ExitCode::FAILURE,
    }
}

// ---------------------------------------------------------------------------
// options
// ---------------------------------------------------------------------------

struct Options {
    corpus: Option<PathBuf>,
    out: Option<PathBuf>,
    compressed: Option<PathBuf>,
    only: Vec<String>,
}

fn parse_options(args: &[String]) -> Result<Options, ()> {
    let mut options = Options {
        corpus: None,
        out: None,
        compressed: None,
        only: Vec::new(),
    };
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        let Some(value) = args.get(index + 1).cloned() else {
            eprintln!("missing value for {flag}");
            return Err(());
        };
        match flag {
            "--corpus" => options.corpus = Some(PathBuf::from(value)),
            "--out" => options.out = Some(PathBuf::from(value)),
            "--compressed" => options.compressed = Some(PathBuf::from(value)),
            "--only" => options.only = value.split(',').map(|s| s.trim().to_string()).collect(),
            other => {
                eprintln!("unknown option: {other}");
                return Err(());
            }
        }
        index += 2;
    }
    Ok(options)
}

fn require_corpus(options: &Options) -> Result<&Path, ()> {
    match options.corpus.as_deref() {
        Some(corpus) => Ok(corpus),
        None => {
            eprintln!("--corpus DIR is required");
            Err(())
        }
    }
}

fn require_out(options: &Options) -> Result<&Path, ()> {
    match options.out.as_deref() {
        Some(out) => Ok(out),
        None => {
            eprintln!("--out is required");
            Err(())
        }
    }
}

// ---------------------------------------------------------------------------
// corpus
// ---------------------------------------------------------------------------

fn corpus_files(dir: &Path) -> Vec<PathBuf> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) => {
            eprintln!("cannot read {}: {error}", dir.display());
            return Vec::new();
        }
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .filter(|path| {
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            !name.starts_with("README") && !name.starts_with("LICENSE")
        })
        .collect();
    files.sort();
    files
}

fn file_name(path: &Path) -> &str {
    path.file_name().and_then(|n| n.to_str()).unwrap_or("?")
}

// ---------------------------------------------------------------------------
// gen
// ---------------------------------------------------------------------------

fn cmd_gen(args: &[String]) -> Result<(), ()> {
    let options = parse_options(args)?;
    let corpus = require_corpus(&options)?;
    let out = require_out(&options)?;
    fs::create_dir_all(out).map_err(|error| {
        eprintln!("cannot create {}: {error}", out.display());
    })?;
    let mut encoder = snap::raw::Encoder::new();
    let mut written = 0usize;
    for path in corpus_files(corpus) {
        let name = file_name(&path);
        if !options.only.is_empty() && !options.only.iter().any(|only| only == name) {
            continue;
        }
        let source = fs::read(&path).map_err(|error| {
            eprintln!("cannot read {}: {error}", path.display());
        })?;
        let compressed = encoder.compress_vec(&source).map_err(|error| {
            eprintln!("compress failed for {name}: {error}");
        })?;
        let destination = out.join(format!("{name}.snappy"));
        fs::write(&destination, &compressed).map_err(|error| {
            eprintln!("cannot write {}: {error}", destination.display());
        })?;
        println!(
            "gen {name}: {} -> {} bytes ({:.3})",
            source.len(),
            compressed.len(),
            compressed.len() as f64 / source.len() as f64
        );
        written += 1;
    }
    if written == 0 {
        eprintln!("no corpus files matched");
        return Err(());
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// verify
// ---------------------------------------------------------------------------

fn cmd_verify(args: &[String]) -> Result<(), ()> {
    let options = parse_options(args)?;
    let corpus = require_corpus(&options)?;
    let Some(compressed_dir) = options.compressed.as_deref() else {
        eprintln!("--compressed DIR is required");
        return Err(());
    };
    let mut decoder = snap::raw::Decoder::new();
    let mut checked = 0usize;
    let mut failures = 0usize;
    for path in corpus_files(corpus) {
        let name = file_name(&path);
        let compressed_path = compressed_dir.join(format!("{name}.snappy"));
        let compressed = match fs::read(&compressed_path) {
            Ok(bytes) => bytes,
            Err(error) => {
                eprintln!(
                    "verify {name}: cannot read {}: {error}",
                    compressed_path.display()
                );
                failures += 1;
                continue;
            }
        };
        let expected = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) => {
                eprintln!("verify {name}: cannot read {}: {error}", path.display());
                failures += 1;
                continue;
            }
        };
        match decoder.decompress_vec(&compressed) {
            Ok(decoded) if decoded == expected => {
                println!(
                    "verify {name}: ok, {} -> {} bytes ({:.3})",
                    expected.len(),
                    compressed.len(),
                    compressed.len() as f64 / expected.len() as f64
                );
                checked += 1;
            }
            Ok(decoded) => {
                eprintln!(
                    "verify {name}: MISMATCH ({} bytes decoded, {} expected)",
                    decoded.len(),
                    expected.len()
                );
                failures += 1;
            }
            Err(error) => {
                eprintln!("verify {name}: decode failed: {error}");
                failures += 1;
            }
        }
    }
    if checked == 0 || failures > 0 {
        eprintln!("{failures} failure(s), {checked} file(s) verified");
        return Err(());
    }
    println!("{checked} file(s) verified");
    Ok(())
}

// ---------------------------------------------------------------------------
// framing format
// ---------------------------------------------------------------------------

fn cmd_gen_frame(args: &[String]) -> Result<(), ()> {
    let options = parse_options(args)?;
    let corpus = require_corpus(&options)?;
    let out = require_out(&options)?;
    fs::create_dir_all(out).map_err(|error| {
        eprintln!("cannot create {}: {error}", out.display());
    })?;
    let mut written = 0usize;
    for path in corpus_files(corpus) {
        let name = file_name(&path);
        if !options.only.is_empty() && !options.only.iter().any(|only| only == name) {
            continue;
        }
        let source = fs::read(&path).map_err(|error| {
            eprintln!("cannot read {}: {error}", path.display());
        })?;
        let mut encoder = snap::write::FrameEncoder::new(Vec::new());
        encoder.write_all(&source).map_err(|error| {
            eprintln!("frame encode failed for {name}: {error}");
        })?;
        let framed = encoder.into_inner().map_err(|error| {
            eprintln!("frame encode failed for {name}: {error}");
        })?;
        let destination = out.join(format!("{name}.sz"));
        fs::write(&destination, &framed).map_err(|error| {
            eprintln!("cannot write {}: {error}", destination.display());
        })?;
        println!(
            "gen-frame {name}: {} -> {} bytes ({:.3})",
            source.len(),
            framed.len(),
            framed.len() as f64 / source.len() as f64
        );
        written += 1;
    }
    if written == 0 {
        eprintln!("no corpus files matched");
        return Err(());
    }
    Ok(())
}

fn cmd_verify_frame(args: &[String]) -> Result<(), ()> {
    let options = parse_options(args)?;
    let corpus = require_corpus(&options)?;
    let Some(compressed_dir) = options.compressed.as_deref() else {
        eprintln!("--compressed DIR is required");
        return Err(());
    };
    let mut checked = 0usize;
    let mut failures = 0usize;
    for path in corpus_files(corpus) {
        let name = file_name(&path);
        let framed_path = compressed_dir.join(format!("{name}.sz"));
        let framed = match fs::read(&framed_path) {
            Ok(bytes) => bytes,
            Err(error) => {
                eprintln!("verify-frame {name}: cannot read {}: {error}", framed_path.display());
                failures += 1;
                continue;
            }
        };
        let expected = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) => {
                eprintln!("verify-frame {name}: cannot read {}: {error}", path.display());
                failures += 1;
                continue;
            }
        };
        let mut decoder = snap::read::FrameDecoder::new(&framed[..]);
        let mut decoded = Vec::new();
        match decoder.read_to_end(&mut decoded) {
            Ok(_) if decoded == expected => {
                println!(
                    "verify-frame {name}: ok, {} -> {} bytes ({:.3})",
                    expected.len(),
                    framed.len(),
                    framed.len() as f64 / expected.len() as f64
                );
                checked += 1;
            }
            Ok(_) => {
                eprintln!(
                    "verify-frame {name}: MISMATCH ({} bytes decoded, {} expected)",
                    decoded.len(),
                    expected.len()
                );
                failures += 1;
            }
            Err(error) => {
                eprintln!("verify-frame {name}: decode failed: {error}");
                failures += 1;
            }
        }
    }
    if checked == 0 || failures > 0 {
        eprintln!("{failures} failure(s), {checked} file(s) verified");
        return Err(());
    }
    println!("{checked} file(s) verified");
    Ok(())
}

// ---------------------------------------------------------------------------
// bench
// ---------------------------------------------------------------------------

fn cmd_bench(args: &[String]) -> Result<(), ()> {
    let options = parse_options(args)?;
    let corpus = require_corpus(&options)?;
    let out = require_out(&options)?;
    let mut encoder = snap::raw::Encoder::new();
    let mut decoder = snap::raw::Decoder::new();
    let mut rows: Vec<String> = Vec::new();

    for path in corpus_files(corpus) {
        let name = file_name(&path);
        let source = fs::read(&path).map_err(|error| {
            eprintln!("cannot read {}: {error}", path.display());
        })?;
        let compressed = encoder.compress_vec(&source).map_err(|error| {
            eprintln!("compress failed for {name}: {error}");
        })?;

        // Reused output buffer, matching the Dart benchmark's `encodeInto` /
        // `decodeInto` fast path.
        let mut scratch = vec![0u8; snap::raw::max_compress_len(source.len())];
        for _ in 0..5 {
            black_box(encoder.compress(black_box(&source), &mut scratch).unwrap());
            black_box(decoder.decompress(black_box(&compressed), &mut scratch).unwrap());
        }

        let compress = measure(|| {
            black_box(encoder.compress(black_box(&source), &mut scratch).unwrap());
        });
        let decompress = measure(|| {
            black_box(decoder.decompress(black_box(&compressed), &mut scratch).unwrap());
        });
        let (compress_mib, compress_rme) = rate(compress, source.len());
        let (decompress_mib, decompress_rme) = rate(decompress, source.len());
        println!(
            "{name}: compress {compress_mib:.1} MiB/s (+/-{compress_rme:.1}%), \
             decompress {decompress_mib:.1} MiB/s (+/-{decompress_rme:.1}%)"
        );
        rows.push(row(
            "compress",
            name,
            source.len(),
            compress_mib,
            compress_rme,
        ));
        rows.push(row(
            "decompress",
            name,
            source.len(),
            decompress_mib,
            decompress_rme,
        ));

        // Framing format: whole-buffer encode/decode, allocating like the Dart
        // `SnappyFraming.compress`/`decompress` entry points.
        let mut frame_encoder = snap::write::FrameEncoder::new(Vec::new());
        frame_encoder.write_all(&source).map_err(|error| {
            eprintln!("frame encode failed for {name}: {error}");
        })?;
        let framed = frame_encoder.into_inner().map_err(|error| {
            eprintln!("frame encode failed for {name}: {error}");
        })?;
        for _ in 0..3 {
            let mut encoder = snap::write::FrameEncoder::new(Vec::new());
            encoder.write_all(black_box(&source)).unwrap();
            black_box(encoder.into_inner().unwrap());
            let mut frame_decoder = snap::read::FrameDecoder::new(&framed[..]);
            let mut out = Vec::new();
            frame_decoder.read_to_end(&mut out).unwrap();
            black_box(out);
        }
        let frame_compress = measure(|| {
            let mut encoder = snap::write::FrameEncoder::new(Vec::new());
            encoder.write_all(black_box(&source)).unwrap();
            black_box(encoder.into_inner().unwrap());
        });
        let frame_decompress = measure(|| {
            let mut frame_decoder = snap::read::FrameDecoder::new(&framed[..]);
            let mut out = Vec::new();
            frame_decoder.read_to_end(&mut out).unwrap();
            black_box(out);
        });
        let (frame_compress_mib, frame_compress_rme) = rate(frame_compress, source.len());
        let (frame_decompress_mib, frame_decompress_rme) =
            rate(frame_decompress, source.len());
        println!(
            "{name}: frame compress {frame_compress_mib:.1} MiB/s \
             (+/-{frame_compress_rme:.1}%), frame decompress {frame_decompress_mib:.1} MiB/s \
             (+/-{frame_decompress_rme:.1}%)"
        );
        rows.push(row(
            "frame-compress",
            name,
            source.len(),
            frame_compress_mib,
            frame_compress_rme,
        ));
        rows.push(row(
            "frame-decompress",
            name,
            source.len(),
            frame_decompress_mib,
            frame_decompress_rme,
        ));
    }

    if rows.is_empty() {
        eprintln!("no corpus files found in {}", corpus.display());
        return Err(());
    }

    let meta = format!(
        "  \"meta\": {{\n    \"tool\": \"snap\",\n    \"tool_version\": \"1.1.2\",\n    \"platform\": {{\"os\": \"{}\", \"arch\": \"{}\", \"cores\": {}}}\n  }},",
        env::consts::OS,
        env::consts::ARCH,
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(0)
    );
    let benchmarks = rows
        .iter()
        .map(|row| format!("    {row}"))
        .collect::<Vec<_>>()
        .join(",\n");
    let report = format!(
        "{{\n  \"schema\": \"benchcat/report@1\",\n{meta}\n  \"benchmarks\": [\n{benchmarks}\n  ]\n}}\n"
    );

    if let Some(parent) = out.parent() {
        if !parent.as_os_str().is_empty() {
            let _ = fs::create_dir_all(parent);
        }
    }
    fs::write(out, report).map_err(|error| {
        eprintln!("cannot write {}: {error}", out.display());
    })?;
    println!("wrote {}", out.display());
    Ok(())
}

fn row(operation: &str, name: &str, bytes: usize, value: f64, rme: f64) -> String {
    let group = match operation {
        "compress" => "Compress",
        "decompress" => "Decompress",
        "frame-compress" => "Frame compress",
        _ => "Frame decompress",
    };
    format!(
        "{{\"id\": \"{operation}/{name}\", \"group\": \"{group}\", \"label\": \"{name} · {} KiB\", \"unit\": \"MiB/s\", \"value\": {value:.3}, \"direction\": \"higher\", \"stats\": {{\"rme_pct\": {rme:.2}}}}}",
        bytes / 1024
    )
}

fn measure<F: FnMut()>(mut function: F) -> Vec<f64> {
    let deadline = Instant::now() + BENCH_DURATION;
    let mut samples = Vec::new();
    while Instant::now() < deadline {
        let started = Instant::now();
        function();
        samples.push(started.elapsed().as_secs_f64());
    }
    samples
}

fn rate(samples: Vec<f64>, bytes: usize) -> (f64, f64) {
    if samples.is_empty() {
        return (0.0, 0.0);
    }
    let count = samples.len() as f64;
    let mean_seconds = samples.iter().sum::<f64>() / count;
    let mib_per_second = bytes as f64 / MIB / mean_seconds;
    let variance = samples
        .iter()
        .map(|sample| (sample - mean_seconds) * (sample - mean_seconds))
        .sum::<f64>()
        / count;
    let rme = if samples.len() > 1 {
        1.96 * variance.sqrt() / count.sqrt() / mean_seconds * 100.0
    } else {
        0.0
    };
    (mib_per_second, rme)
}
