// lib/core/services/file_upload_handler.dart
// FIXED: Stream files instead of loading entire file into memory

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import '../security/privacy_mode.dart';

const String backendUrl = 'https://data-analysis-oajs.onrender.com';
const int chunkSizeBytes = 1024 * 1024; // 1MB chunks for streaming

class FileUploadHandler {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 60),
    ),
  );

  /// Upload a file via streaming to avoid OutOfMemory errors
  /// 
  /// Instead of loading the entire file into memory (which triggers file_picker's
  /// MethodChannel serialization and hits DirectByteBuffer allocation limits on
  /// Android), this streams the file in chunks to the backend.
  Future<Map<String, dynamic>> uploadLargeFile(
    String filePath, {
    required Function(int, int) onProgress,
  }) async {
    if (secureLocalOnly) {
      return {"success": false, "error": "Remote file upload is disabled in secure local mode."};
    }
    try {
      final file = File(filePath);
      
      // Validate file size upfront (prevent massive uploads)
      final fileSizeBytes = await file.length();
      const maxSizeBytes = 500 * 1024 * 1024; // 500MB limit
      if (fileSizeBytes > maxSizeBytes) {
        throw Exception(
          'File too large (${(fileSizeBytes / 1024 / 1024).toStringAsFixed(2)}MB). '
          'Maximum allowed: ${(maxSizeBytes / 1024 / 1024).toInt()}MB'
        );
      }

      // Prepare multipart form data with streaming
      final formData = FormData();
      formData.files.add(
        MapEntry(
          'file',
          await MultipartFile.fromFile(
            filePath,
            filename: file.path.split('/').last,
          ),
        ),
      );

      // Upload with progress callback
      final response = await _dio.post(
        '$backendUrl/upload',
        data: formData,
        onSendProgress: (int sent, int total) {
          onProgress(sent, total);
        },
        options: Options(
          method: 'POST',
          headers: {'Content-Type': 'multipart/form-data'},
        ),
      );

      if (response.statusCode == 200) {
        return response.data as Map<String, dynamic>;
      } else {
        throw Exception('Upload failed: ${response.statusCode}');
      }
    } on DioException catch (e) {
      throw Exception('Upload error: ${e.message}');
    }
  }

  /// Parse CSV data in chunks without loading entire file into memory
  /// 
  /// Useful for data preview without parsing the entire matrix upfront.
  /// Use this for showing the first N rows while backend processes full dataset.
  Future<List<List<String>>> previewCsvChunk(
    String filePath, {
    int maxRows = 1000,
  }) async {
    try {
      final file = File(filePath);
      final lines = <List<String>>[];
      
      final input = file.openRead();
      final stream = input
          .transform(const Utf8Decoder())
          .transform(const LineSplitter());
      
      int rowCount = 0;
      await for (final line in stream) {
        if (rowCount >= maxRows) break;
        lines.add(line.split(',').map((s) => s.trim()).toList());
        rowCount++;
      }
      
      return lines;
    } catch (e) {
      throw Exception('CSV preview failed: $e');
    }
  }

  /// Select file with safety checks (DO NOT load into memory via withData)
  /// 
  /// Key: setting withData=false prevents file_picker from encoding the
  /// entire file through MethodChannel's StandardMethodCodec, which would
  /// trigger a DirectByteBuffer allocation and likely OutOfMemoryError on
  /// Android with large files.
  Future<PlatformFile?> selectFile({
    required List<String> extensions,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
        withData: false, // CRITICAL: Don't load file into MethodChannel
        lockParentWindow: true,
      );
      
      return result?.files.singleOrNull;
    } catch (e) {
      throw Exception('File selection failed: $e');
    }
  }
}
