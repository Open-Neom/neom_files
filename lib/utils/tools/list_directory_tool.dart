import 'dart:io';

import '../../domain/use_cases/neom_tool.dart';
import 'file_read_tool.dart';

/// Lists the contents of a directory with metadata.
///
/// Provides a structured view of files and folders with size,
/// type indicators, and optional recursive traversal. Desktop only.
class NeomListDirectoryTool implements NeomTool {
  /// Optional platform check callback.
  final bool Function()? canExecute;

  const NeomListDirectoryTool({this.canExecute});

  @override
  String get name => 'list_directory';

  @override
  String get description =>
      'List the contents of a directory. '
      'Shows files and subdirectories with size information. '
      'Use recursive=true to see the full project structure. '
      'Use this tool when the user asks what is in a folder, '
      'wants to see a project structure, or needs to find something.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Directory path. Example: "~/Documents", ".", "/tmp".',
      },
      'recursive': {
        'type': 'boolean',
        'description': 'If true, lists subdirectories recursively (max 3 levels). '
            'Default: false.',
      },
      'show_hidden': {
        'type': 'boolean',
        'description': 'If true, includes hidden files (starting with dot). '
            'Default: false.',
      },
    },
    'required': ['path'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    if (canExecute != null && !canExecute!()) {
      return 'Error: directory listing not available on this platform.';
    }

    final rawPath = args['path'] as String? ?? '.';
    final recursive = args['recursive'] as bool? ?? false;
    final showHidden = args['show_hidden'] as bool? ?? false;

    try {
      final expandedPath = NeomFileReadTool.expandHome(rawPath);
      final dir = Directory(expandedPath);

      if (!await dir.exists()) {
        return 'Error: directory not found: $rawPath';
      }

      final buffer = StringBuffer();
      buffer.writeln('Contents of: $rawPath');
      buffer.writeln();

      var count = 0;
      const maxEntries = 100;

      if (recursive) {
        count = await _listRecursive(dir, buffer, 0, 3, showHidden, 0, maxEntries);
      } else {
        final entries = <_DirEntry>[];

        await for (final entity in dir.list(followLinks: false)) {
          if (count >= maxEntries) break;

          final name = entity.path.split(Platform.pathSeparator).last;
          if (!showHidden && name.startsWith('.')) continue;

          final stat = await entity.stat();
          entries.add(_DirEntry(
            name: name,
            isDir: entity is Directory,
            size: stat.size,
          ));
          count++;
        }

        // Sort: directories first, then alphabetical
        entries.sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

        for (final e in entries) {
          final icon = e.isDir ? 'd' : '-';
          final size = e.isDir ? '' : ' (${NeomFileReadTool.formatSize(e.size)})';
          buffer.writeln('  $icon ${e.name}$size');
        }

        buffer.writeln();
        buffer.writeln('Total: $count items');
      }

      if (count >= maxEntries) {
        buffer.writeln('(limited to $maxEntries entries)');
      }

      return buffer.toString();
    } catch (e) {
      return 'Error listing directory: $e';
    }
  }

  Future<int> _listRecursive(
    Directory dir,
    StringBuffer buffer,
    int depth,
    int maxDepth,
    bool showHidden,
    int count,
    int maxEntries,
  ) async {
    if (depth > maxDepth || count >= maxEntries) return count;

    final indent = '  ' * (depth + 1);
    final entries = <FileSystemEntity>[];

    try {
      await for (final entity in dir.list(followLinks: false)) {
        entries.add(entity);
      }
    } catch (_) {
      buffer.writeln('$indent(no access)');
      return count;
    }

    entries.sort((a, b) {
      final aIsDir = a is Directory;
      final bIsDir = b is Directory;
      if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });

    for (final entity in entries) {
      if (count >= maxEntries) break;

      final name = entity.path.split(Platform.pathSeparator).last;
      if (!showHidden && name.startsWith('.')) continue;

      if (entity is Directory) {
        if (_isSkippableDir(name)) {
          buffer.writeln('$indent  $name/ (skipped)');
          count++;
          continue;
        }

        buffer.writeln('$indent  $name/');
        count++;
        count = await _listRecursive(
          entity, buffer, depth + 1, maxDepth, showHidden, count, maxEntries,
        );
      } else {
        final stat = await entity.stat();
        buffer.writeln('$indent  $name (${NeomFileReadTool.formatSize(stat.size)})');
        count++;
      }
    }

    return count;
  }

  static bool _isSkippableDir(String name) {
    const skip = {
      'node_modules', '.dart_tool', 'build', '.git',
      '.idea', '.vscode', '__pycache__', '.gradle',
      'Pods', '.symlinks', 'ephemeral',
    };
    return skip.contains(name);
  }
}

class _DirEntry {
  final String name;
  final bool isDir;
  final int size;

  const _DirEntry({
    required this.name,
    required this.isDir,
    required this.size,
  });
}
