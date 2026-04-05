import 'dart:io';
import 'dart:typed_data';

import '../../domain/use_cases/neom_tool.dart';

/// Reads file contents from the local filesystem.
///
/// Features merged from SAIA + Neomage:
///   - Binary detection via magic bytes + extension (Neomage)
///   - Encoding fallback: UTF-8 → Latin1 → binary (Neomage)
///   - Symlink resolution (Neomage)
///   - Large file warnings (Neomage)
///   - Line number formatting for code files (SAIA)
///   - Clean range support with from_line/max_lines (SAIA)
///
/// Desktop only — returns error on web/mobile.
class NeomFileReadTool implements NeomTool {
  /// Optional platform check callback. If provided and returns false,
  /// the tool returns an error. Allows host apps to inject their own
  /// platform restrictions without coupling to a specific service.
  final bool Function()? canExecute;

  const NeomFileReadTool({this.canExecute});

  @override
  String get name => 'read_file';

  @override
  String get description =>
      'Read the contents of a file. '
      'Supports text, code, config, markdown, etc. '
      'Use this tool when the user asks to view, review, analyze, '
      'or understand a file. Does not read binary files '
      '(images, compiled PDFs, videos).';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Absolute or relative path to the file. '
            'Example: ~/Documents/config.yaml or /Users/user/project/main.dart',
      },
      'max_lines': {
        'type': 'integer',
        'description': 'Maximum lines to read (default 500). '
            'Use a smaller value for large files.',
      },
      'from_line': {
        'type': 'integer',
        'description': 'Starting line (1-based). For reading a specific range.',
      },
    },
    'required': ['path'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    if (canExecute != null && !canExecute!()) {
      return 'Error: file reading not available on this platform.';
    }

    final rawPath = args['path'] as String? ?? '';
    if (rawPath.isEmpty) return 'Error: empty file path.';

    final maxLines = (args['max_lines'] as num?)?.toInt() ?? 500;
    final fromLine = (args['from_line'] as num?)?.toInt() ?? 1;

    try {
      final expandedPath = expandHome(rawPath);

      // Resolve symlinks
      final resolved = await _resolveSymlink(expandedPath);
      final file = File(resolved);

      if (!await file.exists()) {
        return 'Error: file not found: $rawPath';
      }

      final stat = await file.stat();

      // Reject files > 10MB
      if (stat.size > 10 * 1024 * 1024) {
        return 'Error: file too large (${formatSize(stat.size)}). '
            'Limit: 10MB for text reading.';
      }

      // Check binary via extension
      if (_isBinaryExtension(rawPath)) {
        return 'Error: binary file detected. '
            'read_file only supports text files.';
      }

      // Check binary via magic bytes
      if (stat.size > 0) {
        final isBinary = await _isBinaryByMagicBytes(file);
        if (isBinary) {
          return 'Error: binary file detected (magic bytes). '
              'read_file only supports text files.';
        }
      }

      // Read with encoding fallback: UTF-8 → Latin1
      String content;
      try {
        content = await file.readAsString();
      } catch (_) {
        try {
          final bytes = await file.readAsBytes();
          content = String.fromCharCodes(bytes); // Latin1 fallback
        } catch (e) {
          return 'Error: could not decode file (binary?): $e';
        }
      }

      final allLines = content.split('\n');
      final totalLines = allLines.length;

      // Warn about large files without range
      if (totalLines > 10000 && fromLine == 1 && maxLines >= 500) {
        // Still proceed, but add warning
      }

      final startIdx = (fromLine - 1).clamp(0, totalLines);
      final endIdx = (startIdx + maxLines).clamp(0, totalLines);
      final selectedLines = allLines.sublist(startIdx, endIdx);

      // Build result with metadata
      final buffer = StringBuffer();
      buffer.writeln('File: $rawPath');
      buffer.writeln('Total: $totalLines lines | ${formatSize(stat.size)}');

      if (startIdx > 0 || endIdx < totalLines) {
        buffer.writeln('Showing lines ${startIdx + 1}-$endIdx of $totalLines');
      }

      if (totalLines > 10000 && fromLine == 1) {
        buffer.writeln('⚠ Large file — consider using from_line/max_lines for specific ranges.');
      }

      buffer.writeln('---');

      // Add line numbers for code files
      final isCode = _isCodeFile(rawPath);
      for (var i = 0; i < selectedLines.length; i++) {
        final lineNum = startIdx + i + 1;
        if (isCode) {
          buffer.writeln('${lineNum.toString().padLeft(4)}: ${selectedLines[i]}');
        } else {
          buffer.writeln(selectedLines[i]);
        }
      }

      if (endIdx < totalLines) {
        buffer.writeln('--- (${totalLines - endIdx} more lines) ---');
      }

      return buffer.toString();
    } catch (e) {
      return 'Error reading file: $e';
    }
  }

  /// Resolve symlinks to their real path.
  Future<String> _resolveSymlink(String path) async {
    try {
      final link = Link(path);
      if (await link.exists()) {
        return await link.resolveSymbolicLinks();
      }
    } catch (_) {}
    return path;
  }

  /// Detect binary files by reading the first 512 bytes for known magic bytes.
  Future<bool> _isBinaryByMagicBytes(File file) async {
    try {
      final raf = await file.open(mode: FileMode.read);
      try {
        final bytes = await raf.read(512);
        if (bytes.isEmpty) return false;

        // Check known magic bytes
        if (_matchesMagic(bytes, [0x89, 0x50, 0x4E, 0x47])) return true; // PNG
        if (_matchesMagic(bytes, [0xFF, 0xD8, 0xFF])) return true; // JPEG
        if (_matchesMagic(bytes, [0x47, 0x49, 0x46])) return true; // GIF
        if (_matchesMagic(bytes, [0x25, 0x50, 0x44, 0x46])) return true; // PDF
        if (_matchesMagic(bytes, [0x50, 0x4B, 0x03, 0x04])) return true; // ZIP/DOCX/XLSX
        if (_matchesMagic(bytes, [0x1F, 0x8B])) return true; // GZIP
        if (_matchesMagic(bytes, [0x7F, 0x45, 0x4C, 0x46])) return true; // ELF
        if (_matchesMagic(bytes, [0x4D, 0x5A])) return true; // EXE
        if (_matchesMagic(bytes, [0xCA, 0xFE, 0xBA, 0xBE])) return true; // Java class
        if (_matchesMagic(bytes, [0x00, 0x61, 0x73, 0x6D])) return true; // WASM

        // Check for null bytes (common in binary files)
        final nullCount = bytes.where((b) => b == 0).length;
        if (nullCount > bytes.length * 0.1) return true; // >10% null bytes = binary

        return false;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  bool _matchesMagic(Uint8List bytes, List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  static bool _isBinaryExtension(String path) {
    final ext = path.split('.').last.toLowerCase();
    const binary = {
      'png', 'jpg', 'jpeg', 'gif', 'bmp', 'ico', 'webp', 'svg', 'tiff',
      'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a',
      'mp4', 'avi', 'mov', 'mkv', 'webm',
      'zip', 'tar', 'gz', 'rar', '7z', 'bz2',
      'exe', 'dll', 'so', 'dylib', 'bin',
      'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
      'class', 'jar', 'o', 'a', 'dex',
      'ttf', 'otf', 'woff', 'woff2', 'eot',
      'sf2', 'dill', 'snapshot',
    };
    return binary.contains(ext);
  }

  static bool _isCodeFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    const code = {
      'dart', 'py', 'js', 'ts', 'jsx', 'tsx', 'java', 'kt', 'swift',
      'rs', 'go', 'c', 'cpp', 'h', 'cs', 'rb', 'php', 'sh', 'bash',
      'yaml', 'yml', 'json', 'xml', 'toml', 'ini', 'cfg',
      'sql', 'graphql', 'proto', 'dockerfile',
      'html', 'css', 'scss', 'less',
      'gradle', 'cmake', 'makefile',
    };
    return code.contains(ext);
  }

  /// Expand ~ to the user's home directory.
  static String expandHome(String path) {
    if (path.startsWith('~/')) {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      return '$home${path.substring(1)}';
    }
    return path;
  }

  /// Format bytes into human-readable size.
  static String formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}
