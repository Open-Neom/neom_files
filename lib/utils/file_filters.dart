/// Skip-patterns for generated / hidden / cached files and include-path
/// normalization helpers.
///
/// Zero dependencies — usable from any file walker, corpus ingester,
/// or prompt-context builder.
class FileFilters {
  FileFilters._();

  /// Default skip patterns for generated / noise files.
  ///
  /// Match is **substring** against the full path (POSIX slashes). Any
  /// pattern starting with `/.` is treated as a hidden-dir prefix.
  static const List<String> defaultSkipFiles = [
    // Dart / Flutter generated
    '.freezed.dart',
    '.g.dart',
    '.res.dart',
    '.config.dart',
    '.mocks.dart',
    '.gen.dart',
    'generated_plugin_registrant.dart',
    // Build artifacts
    '/build/',
    '/.dart_tool/',
    '/.pub-cache/',
    '/.pub/',
    // JS / Node
    '/node_modules/',
    '.min.js',
    '.bundle.js',
    // Python
    '__pycache__',
    '.pyc',
    '.pyo',
    // IDE
    '/.idea/',
    '/.vscode/',
    '.DS_Store',
    'Thumbs.db',
    // Git / VCS
    '/.git/',
    '/.svn/',
    '/.hg/',
    // Generic hidden
    '/.',
  ];

  /// Returns `true` if [path] should be skipped.
  ///
  /// Pass [extraSkip] to extend the default list, or [overrideSkip] to
  /// replace it entirely.
  static bool shouldSkip(
    String path, {
    List<String>? extraSkip,
    List<String>? overrideSkip,
  }) {
    if (path.isEmpty) return true;
    final normalized = path.replaceAll('\\', '/');
    final patterns = overrideSkip ?? [
      ...defaultSkipFiles,
      if (extraSkip != null) ...extraSkip,
    ];
    for (final p in patterns) {
      if (normalized.contains(p)) return true;
    }
    return false;
  }

  /// Normalizes a list of include paths.
  ///
  /// Rules:
  /// * If a path contains a `.`, assume it's a file — leave as-is.
  /// * Otherwise, treat it as a directory and ensure it ends with `/`.
  /// * Empty paths are dropped.
  /// * Backslashes are converted to forward slashes.
  static List<String> normalizeIncludePaths(List<String> includePaths) {
    final out = <String>[];
    for (final raw in includePaths) {
      if (raw.isEmpty) continue;
      var p = raw.replaceAll('\\', '/').trim();
      if (p.isEmpty) continue;
      final last = p.split('/').last;
      if (last.contains('.')) {
        out.add(p); // file
      } else {
        if (!p.endsWith('/')) p = '$p/';
        out.add(p);
      }
    }
    return out;
  }

  /// Returns `true` if [path] matches any normalized include prefix.
  ///
  /// A file path matches a directory include if it starts with that prefix;
  /// a file path matches a file include if they are equal.
  static bool isIncluded(
    String path,
    List<String> includePaths,
  ) {
    if (includePaths.isEmpty) return true;
    final normalized = path.replaceAll('\\', '/');
    final normalizedIncludes = normalizeIncludePaths(includePaths);
    for (final inc in normalizedIncludes) {
      if (inc.endsWith('/')) {
        if (normalized.startsWith(inc) || normalized.contains('/$inc')) {
          return true;
        }
      } else {
        if (normalized == inc || normalized.endsWith('/$inc')) return true;
      }
    }
    return false;
  }
}
