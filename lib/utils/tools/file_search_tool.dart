import 'dart:io';

import '../../domain/use_cases/neom_tool.dart';
import 'file_read_tool.dart';

/// Searches for files by name or content within a directory tree.
///
/// Two search modes:
///   - **name**: Find files whose names match a glob pattern (fast, no content reading)
///   - **content**: Grep-style search inside files for a text pattern (reads files)
///
/// Supports recursive glob patterns:
///   - `**/*.dart` — all Dart files in any subdirectory
///   - `src/**/*.ts` — TypeScript files under src/
///   - `*.yaml` — YAML files in root only (no recursion)
///   - `test_*` — files starting with "test_"
///
/// Desktop only. Results capped at 50 matches.
class NeomFileSearchTool implements NeomTool {
  /// Optional platform check callback.
  final bool Function()? canExecute;

  const NeomFileSearchTool({this.canExecute});

  @override
  String get name => 'search_files';

  @override
  String get description =>
      'Search for files by name or by content within a directory. '
      'Mode "name": find files whose name matches a glob pattern. '
      'Supports recursive patterns like "**/*.dart", "src/**/*.ts", '
      '"*.yaml", "config*". '
      'Mode "content": search text inside files (grep with context). '
      'Supports regex like "TODO|FIXME", "function\\s+\\w+". '
      'Use this tool when you need to find files or search '
      'text within a project.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description': 'Search pattern. '
            'For name: "**/*.dart", "src/**/*.ts", "*.yaml", "config*". '
            'For content: literal text or regex like "TODO|FIXME".',
      },
      'path': {
        'type': 'string',
        'description': 'Root directory to search. Default: current directory.',
      },
      'mode': {
        'type': 'string',
        'description': '"name" to search by file name, '
            '"content" to search text inside files. '
            'Default: "content".',
      },
      'file_type': {
        'type': 'string',
        'description': 'Filter by extension (content mode only). '
            'Example: "dart", "yaml", "json". No dot.',
      },
    },
    'required': ['pattern'],
  };

  static const int _maxResults = 50;

  /// Directories to always skip during search.
  static const Set<String> _skipDirs = {
    'node_modules', '.dart_tool', 'build', '.git', '.idea',
    '.vscode', '__pycache__', '.gradle', 'Pods', '.symlinks',
    'ephemeral', '.pub-cache', '.pub', 'coverage',
  };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    if (canExecute != null && !canExecute!()) {
      return 'Error: file search not available on this platform.';
    }

    final pattern = args['pattern'] as String? ?? '';
    if (pattern.isEmpty) return 'Error: empty search pattern.';

    final rawPath = args['path'] as String? ?? '.';
    final mode = args['mode'] as String? ?? 'content';
    final fileType = args['file_type'] as String?;

    final searchPath = NeomFileReadTool.expandHome(rawPath);
    final dir = Directory(searchPath);

    if (!await dir.exists()) {
      return 'Error: directory not found: $rawPath';
    }

    return switch (mode) {
      'name' => _searchByName(dir, pattern),
      _ => _searchByContent(dir, pattern, fileType),
    };
  }

  Future<String> _searchByName(Directory dir, String pattern) async {
    try {
      final results = <String>[];
      final glob = _GlobMatcher(pattern);

      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (results.length >= _maxResults) break;
        if (_shouldSkip(entity.path)) continue;

        final relative = entity.path.length > dir.path.length + 1
            ? entity.path.substring(dir.path.length + 1)
            : entity.path.split(Platform.pathSeparator).last;

        if (glob.matches(relative)) {
          final isDir = entity is Directory;
          final stat = entity is File ? await entity.stat() : null;
          final size = stat != null ? NeomFileReadTool.formatSize(stat.size) : '';
          results.add('${isDir ? "d" : "-"} $relative'
              '${size.isNotEmpty ? " ($size)" : ""}');
        }
      }

      if (results.isEmpty) {
        return 'No files matching "$pattern" in ${dir.path}';
      }

      final buffer = StringBuffer();
      buffer.writeln('Files found (${results.length}'
          '${results.length >= _maxResults ? "+" : ""}):');
      for (final r in results) {
        buffer.writeln('  $r');
      }

      return buffer.toString();
    } catch (e) {
      return 'Error searching files: $e';
    }
  }

  Future<String> _searchByContent(
    Directory dir,
    String pattern,
    String? fileType,
  ) async {
    try {
      final results = <_GrepResult>[];
      RegExp regex;
      try {
        regex = RegExp(pattern, caseSensitive: false);
      } catch (_) {
        regex = RegExp(RegExp.escape(pattern), caseSensitive: false);
      }

      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (results.length >= _maxResults) break;
        if (entity is! File) continue;

        final path = entity.path;

        if (_shouldSkip(path)) continue;

        if (fileType != null) {
          final ext = path.split('.').last.toLowerCase();
          if (ext != fileType.toLowerCase()) continue;
        }

        if (_isBinary(path)) continue;

        try {
          final lines = await entity.readAsLines();
          for (var i = 0; i < lines.length && results.length < _maxResults; i++) {
            if (regex.hasMatch(lines[i])) {
              final relative = path.substring(dir.path.length + 1);

              final ctxBefore = i > 0 ? lines[i - 1].trim() : null;
              final ctxAfter = i < lines.length - 1 ? lines[i + 1].trim() : null;

              results.add(_GrepResult(
                file: relative,
                line: i + 1,
                text: lines[i].trim(),
                contextBefore: ctxBefore,
                contextAfter: ctxAfter,
              ));
            }
          }
        } catch (_) {
          // Skip files that can't be read
        }
      }

      if (results.isEmpty) {
        return 'No matches for "$pattern" in any file'
            '${fileType != null ? " .$fileType" : ""}';
      }

      final buffer = StringBuffer();
      buffer.writeln('Results for "$pattern" (${results.length}'
          '${results.length >= _maxResults ? "+" : ""}):');
      buffer.writeln();

      String? lastFile;
      for (final r in results) {
        if (r.file != lastFile) {
          if (lastFile != null) buffer.writeln();
          buffer.writeln('-- ${r.file} --');
          lastFile = r.file;
        }
        if (r.contextBefore != null) {
          buffer.writeln('  ${r.line - 1}: ${_truncate(r.contextBefore!, 120)}');
        }
        buffer.writeln('  ${r.line}: ${_truncate(r.text, 120)}  <');
        if (r.contextAfter != null) {
          buffer.writeln('  ${r.line + 1}: ${_truncate(r.contextAfter!, 120)}');
        }
      }

      return buffer.toString();
    } catch (e) {
      return 'Error searching files: $e';
    }
  }

  static bool _shouldSkip(String path) {
    final segments = path.split(Platform.pathSeparator);
    for (final seg in segments) {
      if (seg.startsWith('.') && seg != '.') return true;
      if (_skipDirs.contains(seg)) return true;
    }
    return false;
  }

  static bool _isBinary(String path) {
    final ext = path.split('.').last.toLowerCase();
    const binary = {
      'png', 'jpg', 'jpeg', 'gif', 'ico', 'webp', 'bmp', 'svg',
      'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a',
      'mp4', 'avi', 'mov', 'mkv', 'webm',
      'zip', 'tar', 'gz', 'rar', '7z', 'bz2',
      'exe', 'dll', 'so', 'dylib', 'bin',
      'pdf', 'doc', 'docx', 'xls', 'xlsx', 'pptx',
      'class', 'jar', 'o', 'a', 'dex',
      'ttf', 'otf', 'woff', 'woff2', 'eot',
      'sf2', 'dill', 'snapshot',
    };
    return binary.contains(ext);
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}...';
}

/// Glob pattern matcher with support for `**` recursive patterns.
class _GlobMatcher {
  final String pattern;
  late final RegExp _regex;
  late final bool _hasPathSeparator;

  _GlobMatcher(this.pattern) {
    _hasPathSeparator = pattern.contains('/') || pattern.contains('**');
    _regex = RegExp('^${_globToRegex(pattern)}\$', caseSensitive: false);
  }

  bool matches(String relativePath) {
    final normalized = relativePath.replaceAll('\\', '/');
    if (_hasPathSeparator) {
      return _regex.hasMatch(normalized);
    } else {
      final name = normalized.split('/').last;
      return _regex.hasMatch(name);
    }
  }

  static String _globToRegex(String glob) {
    final buffer = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          i++;
          if (i + 1 < glob.length && glob[i + 1] == '/') {
            i++;
            buffer.write('(?:.*/)?');
          } else {
            buffer.write('.*');
          }
        } else {
          buffer.write('[^/]*');
        }
      } else if (c == '?') {
        buffer.write('[^/]');
      } else if (c == '.') {
        buffer.write('\\.');
      } else if (c == '{') {
        buffer.write('(?:');
      } else if (c == '}') {
        buffer.write(')');
      } else if (c == ',') {
        buffer.write('|');
      } else {
        buffer.write(RegExp.escape(c));
      }
    }
    return buffer.toString();
  }
}

class _GrepResult {
  final String file;
  final int line;
  final String text;
  final String? contextBefore;
  final String? contextAfter;

  const _GrepResult({
    required this.file,
    required this.line,
    required this.text,
    this.contextBefore,
    this.contextAfter,
  });
}
