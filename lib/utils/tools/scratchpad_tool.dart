import '../../domain/use_cases/neom_tool.dart';

/// Scratchpad tool — persistent external notepad for intermediate reasoning.
///
/// Allows the AI agent to write and read notes outside the main conversation
/// context. This prevents intermediate discoveries, partial results, and
/// working hypotheses from polluting the conversation history.
///
/// Research shows this pattern improves agent benchmarks by up to 54%:
///   "Agents persistently write notes to external memory outside the
///    context window, retrieving them later."
///   — Anthropic, "Effective Context Engineering for AI Agents"
///
/// The scratchpad survives microcompaction and context clearing — it's
/// stored externally, not in the chat messages. Notes are injected into
/// the system prompt only when the agent reads them back.
class NeomScratchpadTool extends NeomTool {
  /// Maximum notes to retain (FIFO eviction).
  static const int maxNotes = 20;

  /// Maximum characters per note.
  static const int maxNoteLength = 2000;

  /// Maximum total characters across all notes.
  static const int maxTotalLength = 15000;

  /// Internal storage (survives across tool calls, cleared on session reset).
  final List<ScratchpadNote> _notes = [];

  /// All current notes (read-only).
  List<ScratchpadNote> get notes => List.unmodifiable(_notes);

  /// Total character count across all notes.
  int get totalLength => _notes.fold(0, (sum, n) => sum + n.content.length);

  /// Whether the scratchpad has any notes.
  bool get hasNotes => _notes.isNotEmpty;

  @override
  String get name => 'scratchpad';

  @override
  String get description =>
      'Persistent notepad for intermediate reasoning and partial results. '
      'Use this to store discoveries, hypotheses, and working notes that '
      'should survive context clearing. '
      'Actions: "write" to add a note, "read" to retrieve all notes, '
      '"clear" to reset the scratchpad. '
      'Notes are stored OUTSIDE the conversation history — they do NOT '
      'consume context tokens until you read them back. '
      'Use this instead of repeating information in your responses.';

  @override
  Map<String, dynamic> get parameters => {
    'properties': {
      'action': {
        'type': 'string',
        'description': 'The action to perform: "write", "read", or "clear"',
      },
      'content': {
        'type': 'string',
        'description': 'The note content to write (only for "write" action). '
            'Max $maxNoteLength characters.',
      },
      'tag': {
        'type': 'string',
        'description': 'Optional tag to categorize the note (e.g., "findings", '
            '"todo", "decision"). Helps organize notes for later retrieval.',
      },
    },
    'required': ['action'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final action = (args['action'] as String?)?.toLowerCase().trim() ?? '';

    return switch (action) {
      'write' => _write(
        content: args['content'] as String? ?? '',
        tag: args['tag'] as String?,
      ),
      'read' => _read(tag: args['tag'] as String?),
      'clear' => _clear(),
      _ => 'Error: unknown action "$action". '
          'Use "write", "read", or "clear".',
    };
  }

  String _write({required String content, String? tag}) {
    if (content.trim().isEmpty) {
      return 'Error: empty content. Provide text to save.';
    }

    final truncated = content.length > maxNoteLength
        ? '${content.substring(0, maxNoteLength)}... [truncated]'
        : content;

    while (_notes.length >= maxNotes) {
      _notes.removeAt(0);
    }

    while (totalLength + truncated.length > maxTotalLength && _notes.isNotEmpty) {
      _notes.removeAt(0);
    }

    _notes.add(ScratchpadNote(
      content: truncated,
      tag: tag?.toLowerCase().trim(),
      timestamp: DateTime.now(),
    ));

    return 'Note saved${tag != null ? ' [tag: $tag]' : ''}. '
        'Scratchpad: ${_notes.length} notes, '
        '${totalLength} characters.';
  }

  String _read({String? tag}) {
    if (_notes.isEmpty) {
      return 'Scratchpad empty — no notes stored.';
    }

    final filtered = tag != null
        ? _notes.where((n) => n.tag == tag.toLowerCase().trim()).toList()
        : _notes;

    if (filtered.isEmpty) {
      return 'No notes with tag "$tag". '
          'Available tags: ${_notes.map((n) => n.tag ?? "untagged").toSet().join(", ")}';
    }

    final buffer = StringBuffer();
    buffer.writeln('## Scratchpad (${filtered.length} notes)');
    buffer.writeln();

    for (int i = 0; i < filtered.length; i++) {
      final note = filtered[i];
      final tagStr = note.tag != null ? ' [${note.tag}]' : '';
      final timeStr = _formatTime(note.timestamp);
      buffer.writeln('### Note ${i + 1}$tagStr — $timeStr');
      buffer.writeln(note.content);
      buffer.writeln();
    }

    return buffer.toString();
  }

  String _clear() {
    final count = _notes.length;
    _notes.clear();
    return count > 0
        ? 'Scratchpad cleared ($count notes removed).'
        : 'Scratchpad was already empty.';
  }

  /// Reset the scratchpad (call on session reset).
  void reset() {
    _notes.clear();
  }

  /// Build a context injection string for the system prompt.
  /// Returns empty string if no notes exist.
  String buildContextInjection() {
    if (_notes.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('## Active Scratchpad (${_notes.length} notes)');
    for (int i = 0; i < _notes.length; i++) {
      final note = _notes[i];
      final tagStr = note.tag != null ? ' [${note.tag}]' : '';
      buffer.writeln('- Note ${i + 1}$tagStr: ${note.content}');
    }
    return buffer.toString();
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// A single note in the scratchpad.
class ScratchpadNote {
  final String content;
  final String? tag;
  final DateTime timestamp;

  const ScratchpadNote({
    required this.content,
    this.tag,
    required this.timestamp,
  });

  @override
  String toString() => 'ScratchpadNote(${tag ?? "untagged"}, '
      '${content.length}ch, $timestamp)';
}
