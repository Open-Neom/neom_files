// Project service — detects project types, frameworks, package managers,
// and generates project summaries for system prompt context.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// The primary language/platform of a project.
enum ProjectType {
  dart,
  flutter,
  node,
  python,
  rust,
  go,
  java,
  ruby,
  csharp,
  swift,
  unknown,
}

/// Web or application framework detected in the project.
enum ProjectFramework {
  flutter,
  nextjs,
  react,
  vue,
  angular,
  django,
  rails,
  springBoot,
  fastapi,
  express,
  none,
}

/// Package manager used by the project.
enum PackageManager {
  pub,
  npm,
  yarn,
  pnpm,
  pip,
  cargo,
  goMod,
  maven,
  gradle,
  bundler,
  cocoapods,
}

/// Test framework detected in the project.
enum TestFramework {
  flutterTest,
  jest,
  mocha,
  vitest,
  pytest,
  unittest,
  goTest,
  cargoTest,
  rspec,
  junit,
  xunit,
  xctest,
  unknown,
  none,
}

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

/// Full description of a detected project.
class ProjectInfo {
  final String name;
  final ProjectType type;
  final ProjectFramework framework;
  final PackageManager? packageManager;
  final String rootPath;
  final String? version;
  final String? description;
  final int dependencyCount;
  final int devDependencyCount;
  final List<String> scripts;
  final List<String> entryPoints;
  final String? testCommand;
  final String? buildCommand;
  final String? lintCommand;

  const ProjectInfo({
    required this.name,
    required this.type,
    this.framework = ProjectFramework.none,
    this.packageManager,
    required this.rootPath,
    this.version,
    this.description,
    this.dependencyCount = 0,
    this.devDependencyCount = 0,
    this.scripts = const [],
    this.entryPoints = const [],
    this.testCommand,
    this.buildCommand,
    this.lintCommand,
  });

  @override
  String toString() => 'ProjectInfo($name, type: $type, framework: $framework)';
}

/// Language statistics for a project.
class LanguageStats {
  final int fileCount;
  final int lineCount;
  final double percentage;

  const LanguageStats({
    required this.fileCount,
    required this.lineCount,
    required this.percentage,
  });

  @override
  String toString() =>
      'LanguageStats(files: $fileCount, lines: $lineCount, '
      '${percentage.toStringAsFixed(1)}%)';
}

/// A node in a dependency tree.
class DependencyNode {
  final String name;
  final String? version;
  final List<DependencyNode> children;

  const DependencyNode({
    required this.name,
    this.version,
    this.children = const [],
  });

  @override
  String toString() => 'DependencyNode($name@${version ?? "?"})';
}

/// Project size metrics.
class ProjectSize {
  final int fileCount;
  final int dirCount;
  final int totalBytes;
  final Map<String, int> byExtension;

  const ProjectSize({
    required this.fileCount,
    required this.dirCount,
    required this.totalBytes,
    this.byExtension = const {},
  });

  String get humanReadableSize {
    if (totalBytes < 1024) return '$totalBytes B';
    if (totalBytes < 1024 * 1024) {
      return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (totalBytes < 1024 * 1024 * 1024) {
      return '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(totalBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  String toString() =>
      'ProjectSize(files: $fileCount, dirs: $dirCount, $humanReadableSize)';
}

// ---------------------------------------------------------------------------
// ProjectService
// ---------------------------------------------------------------------------

/// Detects project types, frameworks, and provides project-level operations.
class ProjectService {
  /// Mapping of file extensions to language names.
  static const _extensionToLanguage = <String, String>{
    '.dart': 'Dart',
    '.js': 'JavaScript',
    '.jsx': 'JavaScript (JSX)',
    '.ts': 'TypeScript',
    '.tsx': 'TypeScript (TSX)',
    '.py': 'Python',
    '.rs': 'Rust',
    '.go': 'Go',
    '.java': 'Java',
    '.kt': 'Kotlin',
    '.rb': 'Ruby',
    '.cs': 'C#',
    '.swift': 'Swift',
    '.c': 'C',
    '.cpp': 'C++',
    '.h': 'C/C++ Header',
    '.html': 'HTML',
    '.css': 'CSS',
    '.scss': 'SCSS',
    '.json': 'JSON',
    '.yaml': 'YAML',
    '.yml': 'YAML',
    '.toml': 'TOML',
    '.xml': 'XML',
    '.md': 'Markdown',
    '.sh': 'Shell',
    '.sql': 'SQL',
    '.vue': 'Vue',
    '.svelte': 'Svelte',
  };

  /// Marker files that indicate a project root.
  static const _rootMarkers = [
    'pubspec.yaml',
    'package.json',
    'Cargo.toml',
    'go.mod',
    'pom.xml',
    'build.gradle',
    'build.gradle.kts',
    'Gemfile',
    'requirements.txt',
    'pyproject.toml',
    'setup.py',
    'Package.swift',
    '.git',
    'Makefile',
  ];

  // -------------------------------------------------------------------------
  // Project detection
  // -------------------------------------------------------------------------

  /// Scans the directory at [path] and returns a [ProjectInfo] describing it.
  Future<ProjectInfo> detectProject(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      return ProjectInfo(
        name: _dirName(path),
        type: ProjectType.unknown,
        rootPath: path,
      );
    }

    // Try each detector in priority order.
    final pubspec = File('$path/pubspec.yaml');
    if (await pubspec.exists()) {
      return _detectDartProject(path, pubspec);
    }

    final packageJson = File('$path/package.json');
    if (await packageJson.exists()) {
      return _detectNodeProject(path, packageJson);
    }

    final cargoToml = File('$path/Cargo.toml');
    if (await cargoToml.exists()) {
      return _detectRustProject(path, cargoToml);
    }

    final goMod = File('$path/go.mod');
    if (await goMod.exists()) {
      return _detectGoProject(path, goMod);
    }

    final pomXml = File('$path/pom.xml');
    if (await pomXml.exists()) {
      return _detectJavaProject(path, pomXml, isMaven: true);
    }

    final buildGradle = File('$path/build.gradle');
    final buildGradleKts = File('$path/build.gradle.kts');
    if (await buildGradle.exists() || await buildGradleKts.exists()) {
      return _detectJavaProject(path, buildGradle, isMaven: false);
    }

    final gemfile = File('$path/Gemfile');
    if (await gemfile.exists()) {
      return _detectRubyProject(path, gemfile);
    }

    // Python — multiple markers.
    final pyProject = File('$path/pyproject.toml');
    final requirements = File('$path/requirements.txt');
    final setupPy = File('$path/setup.py');
    if (await pyProject.exists() ||
        await requirements.exists() ||
        await setupPy.exists()) {
      return _detectPythonProject(path);
    }

    final packageSwift = File('$path/Package.swift');
    if (await packageSwift.exists()) {
      return _detectSwiftProject(path);
    }

    return ProjectInfo(
      name: _dirName(path),
      type: ProjectType.unknown,
      rootPath: path,
    );
  }

  // -------------------------------------------------------------------------
  // Project root finder
  // -------------------------------------------------------------------------

  /// Walks up the directory tree from [startPath] until a project root marker
  /// is found.  Returns `null` if the filesystem root is reached.
  Future<String?> findProjectRoot(String startPath) async {
    var current = Directory(startPath);

    while (true) {
      for (final marker in _rootMarkers) {
        final entity =
            FileSystemEntity.isDirectorySync('${current.path}/$marker')
            ? Directory('${current.path}/$marker')
            : File('${current.path}/$marker');
        if (await entity.exists()) {
          return current.path;
        }
      }

      final parent = current.parent;
      if (parent.path == current.path) return null; // filesystem root
      current = parent;
    }
  }

  // -------------------------------------------------------------------------
  // File listing
  // -------------------------------------------------------------------------

  /// Returns all project files, optionally respecting .gitignore.
  Future<List<String>> getProjectFiles(
    String path, {
    bool respectGitignore = true,
  }) async {
    if (respectGitignore) {
      try {
        final result = await Process.run(
          'git',
          ['ls-files', '--cached', '--others', '--exclude-standard'],
          workingDirectory: path,
          stdoutEncoding: utf8,
        );
        if (result.exitCode == 0) {
          final output = (result.stdout as String).trim();
          if (output.isNotEmpty) {
            return LineSplitter.split(output).toList();
          }
        }
      } catch (_) {
        // Fall through to manual listing.
      }
    }

    return _listFilesRecursively(path);
  }

  // -------------------------------------------------------------------------
  // Project size
  // -------------------------------------------------------------------------

  /// Calculates the size of the project at [path].
  Future<ProjectSize> getProjectSize(String path) async {
    int fileCount = 0;
    int dirCount = 0;
    int totalBytes = 0;
    final byExtension = <String, int>{};

    await for (final entity in Directory(
      path,
    ).list(recursive: true, followLinks: false)) {
      if (_shouldIgnore(entity.path)) continue;

      if (entity is File) {
        fileCount++;
        try {
          final size = await entity.length();
          totalBytes += size;
          final ext = _extension(entity.path);
          byExtension[ext] = (byExtension[ext] ?? 0) + size;
        } catch (_) {
          // Permission denied, etc.
        }
      } else if (entity is Directory) {
        dirCount++;
      }
    }

    return ProjectSize(
      fileCount: fileCount,
      dirCount: dirCount,
      totalBytes: totalBytes,
      byExtension: byExtension,
    );
  }

  // -------------------------------------------------------------------------
  // Language stats
  // -------------------------------------------------------------------------

  /// Calculates per-language statistics for the project.
  Future<Map<String, LanguageStats>> getProjectLanguages(String path) async {
    final fileCounts = <String, int>{};
    final lineCounts = <String, int>{};

    final files = await getProjectFiles(path);
    for (final file in files) {
      final ext = _extension(file);
      final language = _extensionToLanguage[ext];
      if (language == null) continue;

      fileCounts[language] = (fileCounts[language] ?? 0) + 1;

      try {
        final fullPath = file.startsWith('/') ? file : '$path/$file';
        final content = await File(fullPath).readAsString();
        final lines = LineSplitter.split(content).length;
        lineCounts[language] = (lineCounts[language] ?? 0) + lines;
      } catch (_) {
        // Binary or unreadable file.
      }
    }

    final totalLines = lineCounts.values.fold<int>(0, (a, b) => a + b);
    final result = <String, LanguageStats>{};

    for (final language in fileCounts.keys) {
      final lines = lineCounts[language] ?? 0;
      result[language] = LanguageStats(
        fileCount: fileCounts[language]!,
        lineCount: lines,
        percentage: totalLines > 0 ? (lines / totalLines) * 100 : 0,
      );
    }

    return result;
  }

  // -------------------------------------------------------------------------
  // Dependency tree
  // -------------------------------------------------------------------------

  /// Builds a dependency tree for the project at [path].
  Future<DependencyNode> getDependencyTree(String path) async {
    final info = await detectProject(path);

    switch (info.type) {
      case ProjectType.dart:
      case ProjectType.flutter:
        return _dartDependencyTree(path);
      case ProjectType.node:
        return _nodeDependencyTree(path);
      default:
        return DependencyNode(name: info.name, version: info.version);
    }
  }

  // -------------------------------------------------------------------------
  // Run project command
  // -------------------------------------------------------------------------

  /// Runs a shell command in the project directory.
  Future<ProcessResult> runProjectCommand(
    String command, {
    String? workDir,
  }) async {
    final parts = command.split(RegExp(r'\s+'));
    if (parts.isEmpty) {
      throw ArgumentError('Empty command');
    }

    return Process.run(
      parts.first,
      parts.sublist(1),
      workingDirectory: workDir,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  // -------------------------------------------------------------------------
  // Scripts
  // -------------------------------------------------------------------------

  /// Returns the scripts/commands defined in the project manifest.
  Future<Map<String, String>> getProjectScripts(String path) async {
    final packageJson = File('$path/package.json');
    if (await packageJson.exists()) {
      try {
        final content = await packageJson.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        final scripts = data['scripts'] as Map<String, dynamic>?;
        if (scripts != null) {
          return scripts.map((k, v) => MapEntry(k, v.toString()));
        }
      } catch (_) {}
    }

    final pubspec = File('$path/pubspec.yaml');
    if (await pubspec.exists()) {
      // Dart/Flutter conventional commands.
      return {
        'test': 'dart test',
        'analyze': 'dart analyze',
        'format': 'dart format .',
        if (await File('$path/lib/main.dart').exists()) 'run': 'flutter run',
      };
    }

    return {};
  }

  // -------------------------------------------------------------------------
  // Test framework detection
  // -------------------------------------------------------------------------

  /// Detects the test framework used in the project.
  Future<TestFramework> detectTestFramework(String path) async {
    if (await File('$path/pubspec.yaml').exists()) {
      return TestFramework.flutterTest;
    }

    if (await File('$path/package.json').exists()) {
      try {
        final content = await File('$path/package.json').readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        final deps = <String>{
          ...(data['devDependencies'] as Map<String, dynamic>? ?? {}).keys,
          ...(data['dependencies'] as Map<String, dynamic>? ?? {}).keys,
        };
        if (deps.contains('vitest')) return TestFramework.vitest;
        if (deps.contains('jest')) return TestFramework.jest;
        if (deps.contains('mocha')) return TestFramework.mocha;
      } catch (_) {}
    }

    if (await File('$path/pytest.ini').exists() ||
        await File('$path/conftest.py').exists() ||
        await File('$path/pyproject.toml').exists()) {
      return TestFramework.pytest;
    }

    if (await File('$path/Cargo.toml').exists()) {
      return TestFramework.cargoTest;
    }

    if (await File('$path/go.mod').exists()) {
      return TestFramework.goTest;
    }

    if (await File('$path/Gemfile').exists()) {
      return TestFramework.rspec;
    }

    return TestFramework.none;
  }

  // -------------------------------------------------------------------------
  // Project summary
  // -------------------------------------------------------------------------

  /// Generates a human-readable project summary suitable for system prompts.
  Future<String> generateProjectSummary(String path) async {
    final info = await detectProject(path);
    final buf = StringBuffer();

    buf.writeln('Project: ${info.name}');
    buf.writeln('Type: ${info.type.name}');
    if (info.framework != ProjectFramework.none) {
      buf.writeln('Framework: ${info.framework.name}');
    }
    if (info.packageManager != null) {
      buf.writeln('Package Manager: ${info.packageManager!.name}');
    }
    if (info.version != null) {
      buf.writeln('Version: ${info.version}');
    }
    if (info.description != null) {
      buf.writeln('Description: ${info.description}');
    }
    buf.writeln('Dependencies: ${info.dependencyCount}');
    buf.writeln('Dev Dependencies: ${info.devDependencyCount}');

    if (info.entryPoints.isNotEmpty) {
      buf.writeln('Entry Points: ${info.entryPoints.join(", ")}');
    }
    if (info.testCommand != null) {
      buf.writeln('Test Command: ${info.testCommand}');
    }
    if (info.buildCommand != null) {
      buf.writeln('Build Command: ${info.buildCommand}');
    }
    if (info.scripts.isNotEmpty) {
      buf.writeln('Scripts: ${info.scripts.join(", ")}');
    }

    // Language breakdown.
    try {
      final languages = await getProjectLanguages(path);
      if (languages.isNotEmpty) {
        buf.writeln('Languages:');
        final sorted = languages.entries.toList()
          ..sort((a, b) => b.value.lineCount.compareTo(a.value.lineCount));
        for (final entry in sorted.take(8)) {
          buf.writeln(
            '  ${entry.key}: ${entry.value.fileCount} files, '
            '${entry.value.lineCount} lines '
            '(${entry.value.percentage.toStringAsFixed(1)}%)',
          );
        }
      }
    } catch (_) {
      // Non-critical.
    }

    return buf.toString();
  }

  // -------------------------------------------------------------------------
  // Private — language-specific detectors
  // -------------------------------------------------------------------------

  Future<ProjectInfo> _detectDartProject(String path, File pubspec) async {
    try {
      final content = await pubspec.readAsString();

      final nameMatch = RegExp(
        r'^name:\s*(.+)$',
        multiLine: true,
      ).firstMatch(content);
      final versionMatch = RegExp(
        r'^version:\s*(.+)$',
        multiLine: true,
      ).firstMatch(content);
      final descMatch = RegExp(
        r'^description:\s*(.+)$',
        multiLine: true,
      ).firstMatch(content);

      // Count dependencies by counting lines under the dependencies block.
      final depCount = _countYamlMapEntries(content, 'dependencies');
      final devDepCount = _countYamlMapEntries(content, 'dev_dependencies');

      // Detect Flutter vs pure Dart.
      final isFlutter =
          content.contains('flutter:') &&
          (content.contains('sdk: flutter') ||
              await File('$path/lib/main.dart').exists());

      final entryPoints = <String>[];
      if (await File('$path/lib/main.dart').exists()) {
        entryPoints.add('lib/main.dart');
      }
      if (await File('$path/bin/main.dart').exists()) {
        entryPoints.add('bin/main.dart');
      }

      return ProjectInfo(
        name: nameMatch?.group(1)?.trim() ?? _dirName(path),
        type: isFlutter ? ProjectType.flutter : ProjectType.dart,
        framework: isFlutter ? ProjectFramework.flutter : ProjectFramework.none,
        packageManager: PackageManager.pub,
        rootPath: path,
        version: versionMatch?.group(1)?.trim(),
        description: descMatch?.group(1)?.trim(),
        dependencyCount: depCount,
        devDependencyCount: devDepCount,
        entryPoints: entryPoints,
        testCommand: isFlutter ? 'flutter test' : 'dart test',
        buildCommand: isFlutter ? 'flutter build' : 'dart compile exe',
        lintCommand: 'dart analyze',
      );
    } catch (_) {
      return ProjectInfo(
        name: _dirName(path),
        type: ProjectType.dart,
        packageManager: PackageManager.pub,
        rootPath: path,
      );
    }
  }

  Future<ProjectInfo> _detectNodeProject(String path, File packageJson) async {
    try {
      final content = await packageJson.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      final deps = data['dependencies'] as Map<String, dynamic>? ?? {};
      final devDeps = data['devDependencies'] as Map<String, dynamic>? ?? {};
      final scripts = data['scripts'] as Map<String, dynamic>? ?? {};
      final allDeps = <String>{...deps.keys, ...devDeps.keys};

      // Detect framework.
      ProjectFramework framework = ProjectFramework.none;
      if (allDeps.contains('next')) {
        framework = ProjectFramework.nextjs;
      } else if (allDeps.contains('react')) {
        framework = ProjectFramework.react;
      } else if (allDeps.contains('vue')) {
        framework = ProjectFramework.vue;
      } else if (allDeps.contains('@angular/core')) {
        framework = ProjectFramework.angular;
      } else if (allDeps.contains('express')) {
        framework = ProjectFramework.express;
      }

      // Detect package manager.
      PackageManager pm = PackageManager.npm;
      if (await File('$path/pnpm-lock.yaml').exists()) {
        pm = PackageManager.pnpm;
      } else if (await File('$path/yarn.lock').exists()) {
        pm = PackageManager.yarn;
      }

      final entryPoints = <String>[];
      final main = data['main'] as String?;
      if (main != null) entryPoints.add(main);

      return ProjectInfo(
        name: (data['name'] as String?) ?? _dirName(path),
        type: ProjectType.node,
        framework: framework,
        packageManager: pm,
        rootPath: path,
        version: data['version'] as String?,
        description: data['description'] as String?,
        dependencyCount: deps.length,
        devDependencyCount: devDeps.length,
        scripts: scripts.keys.toList(),
        entryPoints: entryPoints,
        testCommand: scripts.containsKey('test') ? '${pm.name} run test' : null,
        buildCommand: scripts.containsKey('build')
            ? '${pm.name} run build'
            : null,
        lintCommand: scripts.containsKey('lint') ? '${pm.name} run lint' : null,
      );
    } catch (_) {
      return ProjectInfo(
        name: _dirName(path),
        type: ProjectType.node,
        packageManager: PackageManager.npm,
        rootPath: path,
      );
    }
  }

  Future<ProjectInfo> _detectRustProject(String path, File cargoToml) async {
    try {
      final content = await cargoToml.readAsString();

      final nameMatch = RegExp(
        r'^name\s*=\s*"(.+?)"',
        multiLine: true,
      ).firstMatch(content);
      final versionMatch = RegExp(
        r'^version\s*=\s*"(.+?)"',
        multiLine: true,
      ).firstMatch(content);
      final descMatch = RegExp(
        r'^description\s*=\s*"(.+?)"',
        multiLine: true,
      ).firstMatch(content);

      final depSection = RegExp(
        r'\[dependencies\]([^[]*)',
        dotAll: true,
      ).firstMatch(content);
      final depCount = depSection != null
          ? RegExp(
              r'^\w',
              multiLine: true,
            ).allMatches(depSection.group(1)!).length
          : 0;

      final devDepSection = RegExp(
        r'\[dev-dependencies\]([^[]*)',
        dotAll: true,
      ).firstMatch(content);
      final devDepCount = devDepSection != null
          ? RegExp(
              r'^\w',
              multiLine: true,
            ).allMatches(devDepSection.group(1)!).length
          : 0;

      return ProjectInfo(
        name: nameMatch?.group(1) ?? _dirName(path),
        type: ProjectType.rust,
        packageManager: PackageManager.cargo,
        rootPath: path,
        version: versionMatch?.group(1),
        description: descMatch?.group(1),
        dependencyCount: depCount,
        devDependencyCount: devDepCount,
        entryPoints: [
          if (await File('$path/src/main.rs').exists()) 'src/main.rs',
          if (await File('$path/src/lib.rs').exists()) 'src/lib.rs',
        ],
        testCommand: 'cargo test',
        buildCommand: 'cargo build --release',
        lintCommand: 'cargo clippy',
      );
    } catch (_) {
      return ProjectInfo(
        name: _dirName(path),
        type: ProjectType.rust,
        packageManager: PackageManager.cargo,
        rootPath: path,
      );
    }
  }

  Future<ProjectInfo> _detectGoProject(String path, File goMod) async {
    try {
      final content = await goMod.readAsString();
      final moduleMatch = RegExp(
        r'^module\s+(\S+)',
        multiLine: true,
      ).firstMatch(content);

      final moduleName = moduleMatch?.group(1) ?? _dirName(path);
      final name = moduleName.contains('/')
          ? moduleName.split('/').last
          : moduleName;

      // Count require() entries.
      final requireBlock = RegExp(
        r'require\s*\((.*?)\)',
        dotAll: true,
      ).firstMatch(content);
      int depCount = 0;
      if (requireBlock != null) {
        depCount = LineSplitter.split(
          requireBlock.group(1)!.trim(),
        ).where((l) => l.trim().isNotEmpty).length;
      }

      return ProjectInfo(
        name: name,
        type: ProjectType.go,
        packageManager: PackageManager.goMod,
        rootPath: path,
        dependencyCount: depCount,
        entryPoints: [
          if (await File('$path/main.go').exists()) 'main.go',
          if (await File('$path/cmd/main.go').exists()) 'cmd/main.go',
        ],
        testCommand: 'go test ./...',
        buildCommand: 'go build ./...',
        lintCommand: 'golangci-lint run',
      );
    } catch (_) {
      return ProjectInfo(
        name: _dirName(path),
        type: ProjectType.go,
        packageManager: PackageManager.goMod,
        rootPath: path,
      );
    }
  }

  Future<ProjectInfo> _detectJavaProject(
    String path,
    File manifest, {
    required bool isMaven,
  }) async {
    final pm = isMaven ? PackageManager.maven : PackageManager.gradle;
    final framework = await _detectJavaFramework(path);

    return ProjectInfo(
      name: _dirName(path),
      type: ProjectType.java,
      framework: framework,
      packageManager: pm,
      rootPath: path,
      testCommand: isMaven ? 'mvn test' : 'gradle test',
      buildCommand: isMaven ? 'mvn package' : 'gradle build',
    );
  }

  Future<ProjectInfo> _detectRubyProject(String path, File gemfile) async {
    final framework = await File('$path/config/routes.rb').exists()
        ? ProjectFramework.rails
        : ProjectFramework.none;

    return ProjectInfo(
      name: _dirName(path),
      type: ProjectType.ruby,
      framework: framework,
      packageManager: PackageManager.bundler,
      rootPath: path,
      testCommand: framework == ProjectFramework.rails
          ? 'bundle exec rails test'
          : 'bundle exec rspec',
      buildCommand: null,
      lintCommand: 'bundle exec rubocop',
    );
  }

  Future<ProjectInfo> _detectPythonProject(String path) async {
    PackageManager pm = PackageManager.pip;

    // Detect framework.
    ProjectFramework framework = ProjectFramework.none;
    try {
      final reqFile = File('$path/requirements.txt');
      if (await reqFile.exists()) {
        final content = await reqFile.readAsString();
        if (content.contains('django') || content.contains('Django')) {
          framework = ProjectFramework.django;
        } else if (content.contains('fastapi') || content.contains('FastAPI')) {
          framework = ProjectFramework.fastapi;
        }
      }
    } catch (_) {}

    // Check for manage.py as Django indicator.
    if (framework == ProjectFramework.none &&
        await File('$path/manage.py').exists()) {
      framework = ProjectFramework.django;
    }

    return ProjectInfo(
      name: _dirName(path),
      type: ProjectType.python,
      framework: framework,
      packageManager: pm,
      rootPath: path,
      testCommand: 'pytest',
      buildCommand: 'python -m build',
      lintCommand: 'ruff check .',
    );
  }

  Future<ProjectInfo> _detectSwiftProject(String path) async {
    return ProjectInfo(
      name: _dirName(path),
      type: ProjectType.swift,
      packageManager: PackageManager.cocoapods,
      rootPath: path,
      testCommand: 'swift test',
      buildCommand: 'swift build',
    );
  }

  // -------------------------------------------------------------------------
  // Private — dependency trees
  // -------------------------------------------------------------------------

  Future<DependencyNode> _dartDependencyTree(String path) async {
    try {
      final content = await File('$path/pubspec.yaml').readAsString();
      final nameMatch = RegExp(
        r'^name:\s*(.+)$',
        multiLine: true,
      ).firstMatch(content);
      final name = nameMatch?.group(1)?.trim() ?? _dirName(path);

      // Parse dependencies block.
      final children = <DependencyNode>[];
      final depBlock = RegExp(
        r'^dependencies:\s*\n((?:[ \t]+.+\n)*)',
        multiLine: true,
      ).firstMatch(content);

      if (depBlock != null) {
        for (final line in LineSplitter.split(depBlock.group(1)!)) {
          final match = RegExp(r'^\s+(\w[\w_]*):(.*)$').firstMatch(line);
          if (match != null) {
            final depName = match.group(1)!;
            final depVersion = match.group(2)!.trim();
            children.add(
              DependencyNode(
                name: depName,
                version: depVersion.startsWith('^')
                    ? depVersion.substring(1)
                    : depVersion,
              ),
            );
          }
        }
      }

      return DependencyNode(name: name, children: children);
    } catch (_) {
      return DependencyNode(name: _dirName(path));
    }
  }

  Future<DependencyNode> _nodeDependencyTree(String path) async {
    try {
      final content = await File('$path/package.json').readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final name = (data['name'] as String?) ?? _dirName(path);
      final version = data['version'] as String?;

      final deps = data['dependencies'] as Map<String, dynamic>? ?? {};
      final children = deps.entries
          .map(
            (e) => DependencyNode(
              name: e.key,
              version: (e.value as String).replaceAll(RegExp(r'[\^~]'), ''),
            ),
          )
          .toList();

      return DependencyNode(name: name, version: version, children: children);
    } catch (_) {
      return DependencyNode(name: _dirName(path));
    }
  }

  // -------------------------------------------------------------------------
  // Private — helpers
  // -------------------------------------------------------------------------

  Future<ProjectFramework> _detectJavaFramework(String path) async {
    try {
      final pomFile = File('$path/pom.xml');
      if (await pomFile.exists()) {
        final content = await pomFile.readAsString();
        if (content.contains('spring-boot')) return ProjectFramework.springBoot;
      }
      final gradleFile = File('$path/build.gradle');
      if (await gradleFile.exists()) {
        final content = await gradleFile.readAsString();
        if (content.contains('spring-boot')) return ProjectFramework.springBoot;
      }
    } catch (_) {}
    return ProjectFramework.none;
  }

  /// Counts top-level entries under a YAML mapping key (basic heuristic).
  int _countYamlMapEntries(String yamlContent, String key) {
    final match = RegExp(
      '^$key:\\s*\n((?:[ \t]+.+\n)*)',
      multiLine: true,
    ).firstMatch(yamlContent);
    if (match == null) return 0;

    return LineSplitter.split(match.group(1)!)
        .where((l) => l.trimLeft().isNotEmpty && !l.trimLeft().startsWith('#'))
        .where((l) {
          // Only count lines that look like a key (not continuation values).
          final trimmed = l.trimLeft();
          return trimmed.contains(':');
        })
        .length;
  }

  Future<List<String>> _listFilesRecursively(String path) async {
    final files = <String>[];
    try {
      await for (final entity in Directory(
        path,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File && !_shouldIgnore(entity.path)) {
          // Return relative path.
          files.add(entity.path.substring(path.length + 1));
        }
      }
    } catch (_) {}
    return files;
  }

  bool _shouldIgnore(String path) {
    const ignoreDirs = [
      '.git',
      'node_modules',
      '.dart_tool',
      'build',
      '.build',
      'target',
      '__pycache__',
      '.tox',
      'vendor',
      '.idea',
      '.vscode',
      'dist',
      'coverage',
    ];

    for (final dir in ignoreDirs) {
      if (path.contains('/$dir/') || path.endsWith('/$dir')) return true;
    }
    return false;
  }

  String _extension(String path) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot < 0) return '';
    return path.substring(lastDot);
  }

  String _dirName(String path) {
    final parts = path.split(Platform.pathSeparator);
    return parts.isNotEmpty ? parts.last : 'unknown';
  }
}
