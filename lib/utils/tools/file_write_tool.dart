import 'dart:io';

import '../../domain/use_cases/neom_tool.dart';
import 'file_read_tool.dart';

/// Writes or edits files on the local filesystem.
///
/// Features merged from SAIA + Neomage:
///   - Edit mode with uniqueness verification (SAIA / Claude Code pattern)
///   - replace_all flag for batch edits (SAIA)
///   - Atomic writes: write to temp, verify, rename (Neomage)
///   - Protected path validation (Neomage)
///   - Permission checking (Neomage)
///   - Automatic .bak backup (both)
///
/// Two modes:
///   - **create**: Write a new file (fails if exists, unless overwrite=true)
///   - **edit**: Replace specific text (safe, targeted edits with uniqueness check)
class NeomFileWriteTool implements NeomTool {
  /// Optional platform check callback.
  final bool Function()? canExecute;

  const NeomFileWriteTool({this.canExecute});

  @override
  String get name => 'write_file';

  @override
  String get description =>
      'Write or edit a file on the filesystem. '
      'Mode "create": creates a new file with the given content. '
      'Mode "edit": replaces old_text with new_text in an existing file. '
      'IMPORTANT: old_text must be UNIQUE in the file — if there are multiple '
      'matches, the edit will FAIL. Include enough context (3-5 lines) '
      'to make old_text unique. Use replace_all=true only to replace '
      'ALL occurrences (e.g., renaming a variable). '
      'Always creates automatic backup (.bak).';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Absolute or relative path to the file.',
      },
      'mode': {
        'type': 'string',
        'description': '"create" for new file, "edit" to modify existing. '
            'Default: "create".',
      },
      'content': {
        'type': 'string',
        'description': 'Full file content (create mode). Ignored in edit mode.',
      },
      'old_text': {
        'type': 'string',
        'description': 'Exact text to replace (edit mode). '
            'MUST be unique in the file. Include surrounding context lines '
            'if the text appears more than once.',
      },
      'new_text': {
        'type': 'string',
        'description': 'New text that replaces old_text (edit mode).',
      },
      'overwrite': {
        'type': 'boolean',
        'description': 'If true, overwrites existing file in create mode. '
            'Default: false.',
      },
      'replace_all': {
        'type': 'boolean',
        'description': 'If true, replaces ALL occurrences of old_text. '
            'Default: false. Use only for renaming variables or repeated strings.',
      },
    },
    'required': ['path'],
  };

  /// Paths that should never be written to.
  static const _protectedPrefixes = [
    '/etc', '/usr', '/bin', '/sbin', '/System', '/Library/System',
    '/var/root', '/private/etc',
  ];

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    if (canExecute != null && !canExecute!()) {
      return 'Error: file writing not available on this platform.';
    }

    final rawPath = args['path'] as String? ?? '';
    if (rawPath.isEmpty) return 'Error: empty file path.';

    final expandedPath = NeomFileReadTool.expandHome(rawPath);

    // Protected path check
    for (final prefix in _protectedPrefixes) {
      if (expandedPath.startsWith(prefix)) {
        return 'Error: cannot write to protected system path: $rawPath';
      }
    }

    final mode = args['mode'] as String? ?? 'create';

    return switch (mode) {
      'edit' => _executeEdit(rawPath, expandedPath, args),
      _ => _executeCreate(rawPath, expandedPath, args),
    };
  }

  Future<String> _executeCreate(
    String rawPath,
    String expandedPath,
    Map<String, dynamic> args,
  ) async {
    final content = args['content'] as String? ?? '';
    final overwrite = args['overwrite'] as bool? ?? false;

    if (content.isEmpty) {
      return 'Error: empty content. Provide file content.';
    }

    // Max content size: 100MB
    if (content.length > 100 * 1024 * 1024) {
      return 'Error: content too large (${NeomFileReadTool.formatSize(content.length)}). '
          'Limit: 100MB.';
    }

    try {
      final file = File(expandedPath);

      if (await file.exists() && !overwrite) {
        return 'Error: file already exists. Use mode="edit" to modify, '
            'or overwrite=true to replace completely.';
      }

      // Backup existing file
      if (await file.exists()) {
        await _createBackup(file);
      }

      // Ensure parent directory exists
      await file.parent.create(recursive: true);

      // Atomic write: temp file → verify → rename
      final tempFile = File('${expandedPath}.neom_tmp');
      try {
        await tempFile.writeAsString(content, flush: true);

        // Verify write
        final verification = await tempFile.readAsString();
        if (verification.length != content.length) {
          await tempFile.delete();
          return 'Error: write verification failed (size mismatch).';
        }

        // Rename to final path
        await tempFile.rename(expandedPath);
      } catch (e) {
        // Cleanup temp file on failure
        if (await tempFile.exists()) await tempFile.delete();
        rethrow;
      }

      final lines = content.split('\n').length;
      return 'File created: $rawPath ($lines lines, '
          '${NeomFileReadTool.formatSize(content.length)})';
    } catch (e) {
      return 'Error creating file: $e';
    }
  }

  Future<String> _executeEdit(
    String rawPath,
    String expandedPath,
    Map<String, dynamic> args,
  ) async {
    final oldText = args['old_text'] as String? ?? '';
    final newText = args['new_text'] as String? ?? '';
    final replaceAll = args['replace_all'] as bool? ?? false;

    if (oldText.isEmpty) {
      return 'Error: empty old_text. Provide the exact text to replace.';
    }

    if (oldText == newText) {
      return 'Error: old_text and new_text are identical. Nothing to change.';
    }

    try {
      final file = File(expandedPath);

      if (!await file.exists()) {
        return 'Error: file not found: $rawPath';
      }

      final originalContent = await file.readAsString();

      // ── Verify old_text exists ──
      if (!originalContent.contains(oldText)) {
        return _buildNotFoundError(originalContent, oldText);
      }

      // ── Uniqueness verification (Claude Code pattern) ──
      final occurrences = oldText.allMatches(originalContent).length;

      if (occurrences > 1 && !replaceAll) {
        return _buildMultipleMatchError(originalContent, oldText, occurrences);
      }

      // ── Create backup before editing ──
      await _createBackup(file);

      // ── Apply edit ──
      final String newContent;
      if (replaceAll) {
        newContent = originalContent.replaceAll(oldText, newText);
      } else {
        newContent = originalContent.replaceFirst(oldText, newText);
      }

      // Atomic write
      final tempFile = File('${expandedPath}.neom_tmp');
      try {
        await tempFile.writeAsString(newContent, flush: true);
        await tempFile.rename(expandedPath);
      } catch (e) {
        if (await tempFile.exists()) await tempFile.delete();
        // Attempt backup restoration
        final backup = File('${expandedPath}.bak');
        if (await backup.exists()) {
          await backup.copy(expandedPath);
        }
        rethrow;
      }

      // ── Build summary ──
      final oldLines = oldText.split('\n').length;
      final newLines = newText.split('\n').length;
      final diff = newLines - oldLines;

      final summary = StringBuffer('File edited: $rawPath\n');
      summary.writeln('Replaced: $oldLines lines → $newLines lines');
      if (diff != 0) {
        summary.writeln('${diff > 0 ? "+$diff" : "$diff"} lines');
      }
      if (replaceAll && occurrences > 1) {
        summary.writeln('Replaced all $occurrences occurrences.');
      }
      summary.writeln('Backup: .bak');
      return summary.toString();
    } catch (e) {
      return 'Error editing file: $e';
    }
  }

  /// Build a helpful error when old_text is not found.
  String _buildNotFoundError(String content, String oldText) {
    final firstLine = oldText.split('\n').first.trim();
    final lines = content.split('\n');

    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains(firstLine)) {
        final lineNum = i + 1;
        final snippet = lines[i].trim();
        return 'Error: old_text not found in file.\n'
            'Partial match found at line $lineNum:\n'
            '  "$snippet"\n'
            'Check spaces, indentation, and exact formatting. '
            'Use read_file first to see current content.';
      }
    }

    return 'Error: old_text not found in file. '
        'Verify the text is exact. '
        'Use read_file first to see current content.';
  }

  /// Build a detailed error when multiple matches are found.
  String _buildMultipleMatchError(String content, String oldText, int count) {
    final lines = content.split('\n');
    final firstLine = oldText.split('\n').first;
    final matchLines = <int>[];

    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains(firstLine)) {
        matchLines.add(i + 1);
        if (matchLines.length >= 5) break;
      }
    }

    final buffer = StringBuffer();
    buffer.writeln('Error: old_text has $count matches in the file.');
    buffer.writeln('Must be UNIQUE for precise editing.');
    buffer.writeln('Matches found at lines: ${matchLines.join(", ")}'
        '${count > 5 ? "..." : ""}');
    buffer.writeln();
    buffer.writeln('Options:');
    buffer.writeln('  1. Include more context lines in old_text to make it unique');
    buffer.writeln('  2. Use replace_all=true to replace ALL occurrences');
    buffer.writeln('  3. Use read_file to see context around each match');

    return buffer.toString();
  }

  Future<void> _createBackup(File file) async {
    try {
      final backupPath = '${file.path}.bak';
      await file.copy(backupPath);
    } catch (_) {
      // Non-critical — continue without backup
    }
  }
}
