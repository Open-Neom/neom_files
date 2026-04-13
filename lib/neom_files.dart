/// Cross-platform file operation tools for Open Neom AI agents.
///
/// Provides a shared set of file tools that can be used by any AI agent
/// in the Neom ecosystem (SAIA, Neomage, etc.)
///
/// ## Quick start
///
/// ```dart
/// import 'package:neom_files/neom_files.dart';
///
/// final tools = [
///   NeomFileReadTool(),
///   NeomFileWriteTool(),
///   NeomFileSearchTool(),
///   NeomListDirectoryTool(),
///   NeomScratchpadTool(),
/// ];
///
/// // Register with your agent's tool system
/// for (final tool in tools) {
///   registry.register(tool.name, tool);
/// }
/// ```
///
/// ## Platform restriction
///
/// All file tools accept an optional `canExecute` callback for
/// platform-specific restrictions:
///
/// ```dart
/// NeomFileReadTool(canExecute: () => Platform.isMacOS || Platform.isLinux);
/// ```
library neom_files;

// ── Tool Interface ──
export 'domain/use_cases/neom_tool.dart';

// ── Pure-Dart filters (safe for web) ──
export 'utils/file_filters.dart';

// ── File Tools ──
export 'utils/tools/file_read_tool.dart';
export 'utils/tools/file_write_tool.dart';
export 'utils/tools/file_search_tool.dart';
export 'utils/tools/list_directory_tool.dart';
export 'utils/tools/scratchpad_tool.dart';

// ── Utilities (dart:io required — import separately for web builds) ──
// export 'utils/diff/diff_service.dart';
// export 'utils/services/project_service.dart';
// Import these directly when needed:
//   import 'package:neom_files/utils/diff/diff_service.dart';
//   import 'package:neom_files/utils/services/project_service.dart';
