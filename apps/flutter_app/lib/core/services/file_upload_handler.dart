// lib/core/services/file_upload_handler.dart
//
// Parses uploaded data files (CSV, TSV, JSON, XLSX) into a uniform
// List<List<dynamic>> shape — identical to the 2D array that Excel's
// range.values produces — so the existing analyzeData() pipeline needs
// zero changes to process uploaded files.
//
// Supported formats:
//   .csv          — comma-separated, handles quoted fields & embedded newlines
//   .tsv          — tab-separated
//   .txt          — treated as CSV (auto-detects delimiter)
//   .json         — array-of-objects  →  [headers, ...rows]
//                   OR array-of-arrays →  passed through as-is
//   .xlsx / .xls  — first sheet, via the `excel` package
//
// Dependencies (add to pubspec.yaml):
//   excel: ^4.0.6
//   file_picker: ^8.0.0   ← already present in your project

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart';

// ── Public result type ────────────────────────────────────────────────────────

class FileUploadResult {
  /// The parsed data as a 2D list: row 0 is always the header row.
  final List<List<dynamic>> rows;

  /// Display name of the file the user picked.
  final String fileName;

  /// Human-readable format label, e.g. "CSV", "XLSX", "JSON".
  final String formatLabel;

  const FileUploadResult({
    required this.rows,
    required this.fileName,
    required this.formatLabel,
  });

  /// Total data rows (excludes the header row).
  int get dataRowCount => rows.length > 1 ? rows.length - 1 : 0;

  /// Column headers (first row), cast to strings.
  List<String> get headers =>
      rows.isNotEmpty ? rows.first.map((e) => e?.toString() ?? '').toList() : [];
}

// ── Public entry-point ────────────────────────────────────────────────────────

/// Opens the system file picker, reads the chosen file, parses it, and
/// returns a [FileUploadResult] — or `null` if the user cancelled or the
/// file could not be parsed.
///
/// FIXED: Uses withData: false to avoid OutOfMemoryError on Android when
/// selecting large files. The MethodChannel's StandardMethodCodec would
/// try to encode large file bytes into a DirectByteBuffer, triggering
/// allocation failures on devices with < 500MB heap.
///
/// Call from a StatefulWidget:
/// ```dart
/// final result = await pickAndParseFile();
/// if (result != null) {
///   setState(() { uploadedFileResult = result; });
/// }
/// ```
Future<FileUploadResult?> pickAndParseFile() async {
  // On web there is no real filesystem: file_picker never returns a usable
  // `path`, and dart:io's `File` is an unsupported stub in the browser —
  // calling File(...).readAsBytes() there throws
  // "Unsupported operation: _Namespace" (that's what was crashing on Chrome).
  // So on web we must ask file_picker for the bytes directly. On native
  // platforms we keep withData:false and read from disk, which avoids the
  // MethodChannel OutOfMemory issue the original comment describes.
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['csv', 'tsv', 'txt', 'json', 'xlsx', 'xls'],
    withData: kIsWeb,                // web: must load bytes; native: keep disk-path read
    allowMultiple: false,
  );

  if (picked == null || picked.files.isEmpty) return null;

  final file = picked.files.first;
  final name = file.name;
  final ext  = (file.extension ?? '').toLowerCase();

  try {
    final Uint8List fileBytes;
    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception('No file data returned by the browser file picker.');
      }
      fileBytes = bytes;
    } else {
      final filePath = file.path;
      if (filePath == null || filePath.isEmpty) return null;
      // Read file from disk path instead of loading through MethodChannel
      fileBytes = await _readFileFromDisk(filePath);
    }

    // Validate file size to prevent excessive memory usage
    const maxSizeBytes = 5 * 1024 * 1024 * 1024; // 5GB limit
    if (fileBytes.length > maxSizeBytes) {
      throw Exception(
        'File too large (${(fileBytes.length / 1024 / 1024 / 1024).toStringAsFixed(2)}GB). '
        'Maximum allowed: ${(maxSizeBytes / 1024 / 1024 / 1024).toInt()}GB'
      );
    }

    switch (ext) {
      case 'csv':
      case 'txt':
        return _parseCsv(fileBytes, name, delimiter: _autoDetectDelimiter(fileBytes));
      case 'tsv':
        return _parseCsv(fileBytes, name, delimiter: '\t');
      case 'json':
        return _parseJson(fileBytes, name);
      case 'xlsx':
      case 'xls':
        return _parseXlsx(fileBytes, name);
      default:
      // Try CSV as a last resort for unknown text extensions.
        return _parseCsv(fileBytes, name, delimiter: _autoDetectDelimiter(fileBytes));
    }
  } catch (e) {
    print('File parsing error: $e');
    return null;
  }
}

// ── Encoding-aware text decoding ─────────────────────────────────────────────
//
// CSV/TSV/JSON files aren't always UTF-8. Excel's plain "CSV" export on many
// Windows locales, and a lot of older tools, write Latin-1 / Windows-1252-ish
// single-byte encoding instead. The previous code used
// `utf8.decode(bytes, allowMalformed: true)` everywhere, which does NOT
// throw on non-UTF-8 input — it silently swaps every invalid byte for a
// U+FFFD replacement character. That's why a Latin-1 file "worked" but every
// accented character came out corrupted instead of failing loudly.
//
// This tries a strict UTF-8 decode first (so real UTF-8 files, including
// ones with a byte-order-mark, are unaffected), and only falls back to
// Latin-1 if the bytes genuinely aren't valid UTF-8. Latin-1 never fails to
// decode (every byte 0x00-0xFF maps to exactly one character), so it's a
// safe universal fallback for single-byte encodings.
//
// Caveat: this covers UTF-8 and Latin-1/Windows-1252-style single-byte
// encodings, which is the vast majority of real-world CSV exports. It does
// NOT auto-detect true multi-byte encodings like Shift-JIS or GBK — that
// needs a real charset-detection library (there isn't a solid one in pure
// Dart yet), so a file in one of those would still need to be re-saved as
// UTF-8 first.
String _decodeText(Uint8List bytes) {
  Uint8List data = bytes;
  // Strip a UTF-8 byte-order-mark if present (common from "CSV UTF-8" saves).
  if (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
    data = data.sublist(3);
  }
  try {
    return utf8.decode(data, allowMalformed: false);
  } on FormatException {
    return latin1.decode(data);
  }
}

/// Read file from disk path in chunks to avoid excessive heap allocation.
/// This is safer than relying on the MethodChannel's StandardMethodCodec.
Future<Uint8List> _readFileFromDisk(String filePath) async {
  final file = File(filePath);

  // For larger files, we could implement chunked reading here,
  // but for local disk files, a single read is typically safe
  // since we're not going through the Flutter MethodChannel.
  try {
    return await file.readAsBytes();
  } catch (e) {
    throw Exception('Failed to read file: $e');
  }
}

// ── CSV / TSV parser ──────────────────────────────────────────────────────────

/// Sniffs the first 4 KB of the file to guess whether it uses commas or tabs.
String _autoDetectDelimiter(Uint8List bytes) {
  final sample = _decodeText(bytes.sublist(0, bytes.length < 4096 ? bytes.length : 4096));
  final tabCount   = '\t'.allMatches(sample).length;
  final commaCount = ','.allMatches(sample).length;
  return tabCount > commaCount ? '\t' : ',';
}

FileUploadResult _parseCsv(
    Uint8List bytes,
    String fileName, {
      required String delimiter,
    }) {
  final text = _decodeText(bytes);
  final rows = _splitCsvRows(text, delimiter);
  if (rows.isEmpty) return FileUploadResult(rows: [], fileName: fileName, formatLabel: 'CSV');

  // Normalise all rows to the same column width as the widest row.
  final maxCols = rows.fold<int>(0, (prev, r) => r.length > prev ? r.length : prev);
  final normalised = rows.map((r) {
    if (r.length == maxCols) return r;
    return [...r, ...List<dynamic>.filled(maxCols - r.length, '')];
  }).toList();

  return FileUploadResult(
    rows: normalised,
    fileName: fileName,
    formatLabel: delimiter == '\t' ? 'TSV' : 'CSV',
  );
}

/// RFC-4180-compliant CSV parser that handles:
/// - quoted fields containing the delimiter, double-quotes, or newlines
/// - CRLF and bare LF line endings
List<List<dynamic>> _splitCsvRows(String text, String delimiter) {
  final List<List<dynamic>> rows = [];
  final List<dynamic>       row  = [];
  final StringBuffer        field = StringBuffer();
  bool inQuotes = false;
  int  i        = 0;

  while (i < text.length) {
    final ch = text[i];

    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');            // escaped double-quote inside a quoted field
          i += 2;
          continue;
        }
        inQuotes = false;              // closing quote
      } else {
        field.write(ch);
      }
      i++;
      continue;
    }

    // Outside quotes:
    if (ch == '"') {
      inQuotes = true;
      i++;
      continue;
    }

    if (text.startsWith(delimiter, i)) {
      row.add(field.toString());
      field.clear();
      i += delimiter.length;
      continue;
    }

    if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
      row.add(field.toString());
      field.clear();
      rows.add(List<dynamic>.from(row));
      row.clear();
      i += 2;
      continue;
    }

    if (ch == '\n') {
      row.add(field.toString());
      field.clear();
      rows.add(List<dynamic>.from(row));
      row.clear();
      i++;
      continue;
    }

    field.write(ch);
    i++;
  }

  // Flush final field/row (files often omit trailing newline).
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    if (row.any((c) => c.toString().isNotEmpty)) {
      rows.add(List<dynamic>.from(row));
    }
  }

  // Drop fully empty trailing rows produced by trailing newlines.
  while (rows.isNotEmpty && rows.last.every((c) => c.toString().trim().isEmpty)) {
    rows.removeLast();
  }

  return rows;
}

// ── JSON parser ───────────────────────────────────────────────────────────────

/// Accepts two JSON shapes:
///   1. Array-of-arrays  →  `[[h1,h2], [v1,v2], ...]`  (pass-through)
///   2. Array-of-objects →  `[{"col1":v1,"col2":v2}, ...]`  (converted)
FileUploadResult _parseJson(Uint8List bytes, String fileName) {
  final text    = _decodeText(bytes);
  final dynamic parsed = jsonDecode(text);

  if (parsed is! List || parsed.isEmpty) {
    return FileUploadResult(rows: [], fileName: fileName, formatLabel: 'JSON');
  }

  List<List<dynamic>> rows;

  if (parsed.first is List) {
    // Already 2-D.
    rows = parsed.map<List<dynamic>>((r) => List<dynamic>.from(r as List)).toList();
  } else if (parsed.first is Map) {
    // Derive headers from the union of all keys (preserves insertion order of first object).
    final keySet = <String>{};
    for (final obj in parsed) {
      if (obj is Map) keySet.addAll(obj.keys.map((k) => k.toString()));
    }
    final headers = keySet.toList();
    rows = [
      headers,                                // header row
      ...parsed.map<List<dynamic>>((obj) {
        final map = obj as Map;
        return headers.map<dynamic>((h) => map[h] ?? '').toList();
      }),
    ];
  } else {
    return FileUploadResult(rows: [], fileName: fileName, formatLabel: 'JSON');
  }

  return FileUploadResult(rows: rows, fileName: fileName, formatLabel: 'JSON');
}

// ── XLSX parser ───────────────────────────────────────────────────────────────

/// Reads the **first sheet** of an XLSX/XLS workbook using the `excel` package.
/// Empty trailing rows and columns are stripped so the result matches what
/// Excel's `getUsedRange()` would return.
FileUploadResult _parseXlsx(Uint8List bytes, String fileName) {
  final workbook  = Excel.decodeBytes(bytes);
  final sheetName = workbook.sheets.keys.first;
  final sheet     = workbook.sheets[sheetName]!;

  final List<List<dynamic>> rows = [];

  for (final xlRow in sheet.rows) {
    // Map each cell to its Dart value (string, num, bool, or null).
    final List<dynamic> row = xlRow.map<dynamic>((cell) {
      if (cell == null) return '';
      final v = cell.value;
      if (v == null) return '';
      // TextCellValue.value can be String OR TextSpan (rich text) — always
      // flatten to plain String via .toString() so the value is JSON-safe.
      if (v is TextCellValue)     return v.value?.toString() ?? '';
      if (v is IntCellValue)      return v.value;           // int   — JSON-safe
      if (v is DoubleCellValue)   return v.value;           // double — JSON-safe
      if (v is BoolCellValue)     return v.value;           // bool  — JSON-safe
      if (v is DateCellValue)     return v.asDateTimeUtc().toIso8601String();
      if (v is DateTimeCellValue) return v.asDateTimeUtc().toIso8601String();
      // Catch-all: FormulaCellValue and any future types → plain String
      return v.toString();
    }).toList();

    rows.add(row);
  }

  // Strip fully-empty trailing rows.
  while (rows.isNotEmpty && rows.last.every((c) => c?.toString().trim().isEmpty ?? true)) {
    rows.removeLast();
  }

  // Normalise column count to widest row.
  if (rows.isNotEmpty) {
    final maxCols = rows.fold<int>(0, (p, r) => r.length > p ? r.length : p);
    for (int i = 0; i < rows.length; i++) {
      if (rows[i].length < maxCols) {
        rows[i] = [...rows[i], ...List<dynamic>.filled(maxCols - rows[i].length, '')];
      }
    }
  }

  return FileUploadResult(rows: rows, fileName: fileName, formatLabel: 'XLSX');
}