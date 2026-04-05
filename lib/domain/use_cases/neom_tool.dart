/// Base interface for Neom agent tools.
///
/// Tools are capabilities that AI agents can invoke during reasoning phases
/// to interact with the filesystem, web, or other external resources.
///
/// Implementations must be stateless or manage their own state lifecycle.
/// Results are always returned as formatted strings suitable for LLM context.
abstract class NeomTool {
  /// Tool identifier (e.g. 'read_file', 'write_file').
  String get name;

  /// Human-readable description of what the tool does.
  /// This is shown to the LLM so it can decide when to invoke the tool.
  String get description;

  /// JSON schema describing the tool's input parameters.
  Map<String, dynamic> get parameters;

  /// Execute the tool with the given arguments.
  /// Returns a formatted string result suitable for injection into LLM prompts.
  Future<String> execute(Map<String, dynamic> args);
}
