/// Text diff, patch application, and three-way merge utilities.
///
/// Implements the Myers O(ND) diff algorithm with support for:
///   - Hunk-based diff computation
///   - Unified and side-by-side formatting
///   - Patch application and reversal
///   - Three-way merge with conflict detection
///   - Inline (word-level) highlighting

import 'dart:io';
import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Algorithm used to compute diffs.
enum DiffAlgorithm { myers, patience, histogram }

/// Type of a single diff line.
enum DiffLineType { context, add, remove }

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

/// A single line within a diff hunk.
class DiffLine {
  final DiffLineType type;
  final String content;
  final int? oldLineNumber;
  final int? newLineNumber;

  const DiffLine({
    required this.type,
    required this.content,
    this.oldLineNumber,
    this.newLineNumber,
  });

  @override
  String toString() {
    final prefix = switch (type) {
      DiffLineType.context => ' ',
      DiffLineType.add => '+',
      DiffLineType.remove => '-',
    };
    return '$prefix$content';
  }
}

/// A contiguous group of changes in a diff.
class DiffHunk {
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<DiffLine> lines;

  const DiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  String get header => '@@ -$oldStart,$oldCount +$newStart,$newCount @@';

  @override
  String toString() {
    final buf = StringBuffer(header);
    buf.writeln();
    for (final line in lines) {
      buf.writeln(line);
    }
    return buf.toString();
  }
}

/// Statistics about additions and deletions in a diff.
class DiffStats {
  final int additions;
  final int deletions;
  const DiffStats({required this.additions, required this.deletions});
  int get total => additions + deletions;

  @override
  String toString() => '+$additions -$deletions';
}

/// Diff result for a single file.
class FileDiff {
  final String path;
  final String oldPath;
  final List<DiffHunk> hunks;
  final DiffStats stats;

  const FileDiff({
    required this.path,
    required this.oldPath,
    required this.hunks,
    required this.stats,
  });

  bool get isRename => path != oldPath;

  @override
  String toString() {
    final buf = StringBuffer();
    buf.writeln('--- a/$oldPath');
    buf.writeln('+++ b/$path');
    for (final hunk in hunks) {
      buf.write(hunk);
    }
    return buf.toString();
  }
}

/// A region where a three-way merge encountered a conflict.
class ConflictRegion {
  final List<String> base;
  final List<String> ours;
  final List<String> theirs;
  final int startLine;

  const ConflictRegion({
    required this.base,
    required this.ours,
    required this.theirs,
    required this.startLine,
  });
}

/// Result of a three-way merge.
class MergeResult {
  final String merged;
  final List<ConflictRegion> conflicts;

  const MergeResult({required this.merged, required this.conflicts});
  bool get hasConflicts => conflicts.isNotEmpty;
}

/// A span of text within a line, used for inline (word-level) highlighting.
class InlineSpan {
  final String text;
  final bool isChanged;

  const InlineSpan({required this.text, required this.isChanged});

  @override
  String toString() => isChanged ? '[$text]' : text;
}

// ---------------------------------------------------------------------------
// Internal Myers diff helpers
// ---------------------------------------------------------------------------

enum _EditType { insert, delete, equal }

class _Edit {
  final _EditType type;
  final int oldIndex;
  final int newIndex;
  const _Edit(this.type, this.oldIndex, this.newIndex);
}

List<_Edit> _myersDiff(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;

  if (n == 0 && m == 0) return const [];
  if (n == 0) return List.generate(m, (j) => _Edit(_EditType.insert, 0, j));
  if (m == 0) return List.generate(n, (i) => _Edit(_EditType.delete, i, 0));

  final max = n + m;
  final vSize = 2 * max + 1;
  final v = List<int>.filled(vSize, 0);
  final trace = <List<int>>[];

  outer:
  for (var d = 0; d <= max; d++) {
    trace.add(List<int>.from(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max])) {
        x = v[k + 1 + max];
      } else {
        x = v[k - 1 + max] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[k + max] = x;
      if (x >= n && y >= m) break outer;
    }
  }

  final edits = <_Edit>[];
  var x = n;
  var y = m;
  for (var d = trace.length - 1; d > 0; d--) {
    final prev = trace[d - 1];
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && prev[k - 1 + max] < prev[k + 1 + max])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = prev[prevK + max];
    final prevY = prevX - prevK;

    while (x > prevX && y > prevY) {
      x--;
      y--;
      edits.add(_Edit(_EditType.equal, x, y));
    }

    if (d > 0) {
      if (x == prevX) {
        y--;
        edits.add(_Edit(_EditType.insert, x, y));
      } else {
        x--;
        edits.add(_Edit(_EditType.delete, x, y));
      }
    }
  }
  while (x > 0 && y > 0) {
    x--;
    y--;
    edits.add(_Edit(_EditType.equal, x, y));
  }

  return edits.reversed.toList();
}

// ---------------------------------------------------------------------------
// DiffService
// ---------------------------------------------------------------------------

/// Service for computing diffs, applying patches, and performing merges.
class DiffService {
  final int defaultContextLines;

  DiffService({this.defaultContextLines = 3});

  /// Compute the diff between [oldText] and [newText].
  List<DiffHunk> computeDiff(
    String oldText,
    String newText, {
    DiffAlgorithm algorithm = DiffAlgorithm.myers,
    int? contextLines,
  }) {
    final ctx = contextLines ?? defaultContextLines;
    final oldLines = oldText.isEmpty ? <String>[] : oldText.split('\n');
    final newLines = newText.isEmpty ? <String>[] : newText.split('\n');

    final edits = _myersDiff(oldLines, newLines);
    return _editsToHunks(edits, oldLines, newLines, ctx);
  }

  /// Compute a [FileDiff] by reading files at [oldPath] and [newPath].
  Future<FileDiff> computeFileDiff(String oldPath, String newPath) async {
    final oldFile = File(oldPath);
    final newFile = File(newPath);
    final oldText = await oldFile.exists() ? await oldFile.readAsString() : '';
    final newText = await newFile.exists() ? await newFile.readAsString() : '';

    final hunks = computeDiff(oldText, newText);
    final stats = _computeStats(hunks);
    return FileDiff(path: newPath, oldPath: oldPath, hunks: hunks, stats: stats);
  }

  /// Compute diffs for every file that differs between [oldDir] and [newDir].
  Future<List<FileDiff>> computeDirectoryDiff(String oldDir, String newDir) async {
    final oldFiles = await _listFiles(oldDir);
    final newFiles = await _listFiles(newDir);
    final allRelative = <String>{...oldFiles, ...newFiles};
    final diffs = <FileDiff>[];

    for (final rel in allRelative) {
      final oldPath = '$oldDir/$rel';
      final newPath = '$newDir/$rel';
      final oldText = await File(oldPath).exists() ? await File(oldPath).readAsString() : '';
      final newText = await File(newPath).exists() ? await File(newPath).readAsString() : '';

      if (oldText == newText) continue;

      final hunks = computeDiff(oldText, newText);
      final stats = _computeStats(hunks);
      diffs.add(FileDiff(path: rel, oldPath: rel, hunks: hunks, stats: stats));
    }
    return diffs;
  }

  /// Apply a list of [hunks] to [original] text and return the result.
  String applyPatch(String original, List<DiffHunk> hunks) {
    final lines = original.isEmpty ? <String>[] : original.split('\n');
    var offset = 0;

    for (final hunk in hunks) {
      final start = hunk.oldStart - 1 + offset;
      final toRemove = <int>[];
      final toInsert = <String>[];
      var idx = start;

      for (final line in hunk.lines) {
        switch (line.type) {
          case DiffLineType.context:
            idx++;
          case DiffLineType.remove:
            toRemove.add(idx);
            idx++;
          case DiffLineType.add:
            toInsert.add(line.content);
        }
      }

      for (final i in toRemove.reversed) {
        if (i < lines.length) lines.removeAt(i);
      }
      final insertAt = toRemove.isEmpty ? start : toRemove.first;
      for (var i = 0; i < toInsert.length; i++) {
        lines.insert(insertAt + i, toInsert[i]);
      }

      offset += toInsert.length - toRemove.length;
    }

    return lines.join('\n');
  }

  /// Reverse a patch so that applying the reversed hunks undoes the original.
  List<DiffHunk> reversePatch(List<DiffHunk> hunks) {
    return hunks.map((hunk) {
      final reversedLines = hunk.lines.map((line) {
        final newType = switch (line.type) {
          DiffLineType.add => DiffLineType.remove,
          DiffLineType.remove => DiffLineType.add,
          DiffLineType.context => DiffLineType.context,
        };
        return DiffLine(
          type: newType,
          content: line.content,
          oldLineNumber: line.newLineNumber,
          newLineNumber: line.oldLineNumber,
        );
      }).toList();

      return DiffHunk(
        oldStart: hunk.newStart,
        oldCount: hunk.newCount,
        newStart: hunk.oldStart,
        newCount: hunk.oldCount,
        lines: reversedLines,
      );
    }).toList();
  }

  /// Format a [FileDiff] as a unified diff string.
  String formatUnifiedDiff(FileDiff diff, {int? contextLines}) {
    final buf = StringBuffer();
    buf.writeln('--- a/${diff.oldPath}');
    buf.writeln('+++ b/${diff.path}');
    for (final hunk in diff.hunks) {
      buf.writeln(hunk.header);
      for (final line in hunk.lines) {
        buf.writeln(line);
      }
    }
    return buf.toString();
  }

  /// Format a [FileDiff] as a side-by-side comparison.
  String formatSideBySide(FileDiff diff, {int width = 120}) {
    final colWidth = (width - 3) ~/ 2;
    final buf = StringBuffer();

    for (final hunk in diff.hunks) {
      final oldCol = <String>[];
      final newCol = <String>[];

      for (final line in hunk.lines) {
        switch (line.type) {
          case DiffLineType.context:
            oldCol.add(line.content);
            newCol.add(line.content);
          case DiffLineType.remove:
            oldCol.add(line.content);
            newCol.add('');
          case DiffLineType.add:
            oldCol.add('');
            newCol.add(line.content);
        }
      }

      final rows = math.max(oldCol.length, newCol.length);
      for (var i = 0; i < rows; i++) {
        final left = i < oldCol.length ? oldCol[i] : '';
        final right = i < newCol.length ? newCol[i] : '';
        buf.write(_pad(left, colWidth));
        buf.write(' | ');
        buf.writeln(_pad(right, colWidth));
      }
    }
    return buf.toString();
  }

  /// Parse a unified diff / patch string into a list of [FileDiff].
  List<FileDiff> parsePatch(String patchText) {
    final diffs = <FileDiff>[];
    final lines = patchText.split('\n');
    var i = 0;

    while (i < lines.length) {
      if (i < lines.length && lines[i].startsWith('--- ')) {
        final oldPath = _stripPrefix(lines[i], '--- ');
        i++;
        if (i >= lines.length || !lines[i].startsWith('+++ ')) continue;
        final newPath = _stripPrefix(lines[i], '+++ ');
        i++;

        final hunks = <DiffHunk>[];

        while (i < lines.length && lines[i].startsWith('@@ ')) {
          final header = _parseHunkHeader(lines[i]);
          if (header == null) { i++; continue; }
          i++;

          final hunkLines = <DiffLine>[];
          var oldLine = header.$1;
          var newLine = header.$3;

          while (i < lines.length &&
              !lines[i].startsWith('@@ ') &&
              !lines[i].startsWith('--- ')) {
            final raw = lines[i];
            if (raw.startsWith('+')) {
              hunkLines.add(DiffLine(
                type: DiffLineType.add,
                content: raw.substring(1),
                newLineNumber: newLine,
              ));
              newLine++;
            } else if (raw.startsWith('-')) {
              hunkLines.add(DiffLine(
                type: DiffLineType.remove,
                content: raw.substring(1),
                oldLineNumber: oldLine,
              ));
              oldLine++;
            } else if (raw.startsWith(' ') || raw.isEmpty) {
              final content = raw.isEmpty ? '' : raw.substring(1);
              hunkLines.add(DiffLine(
                type: DiffLineType.context,
                content: content,
                oldLineNumber: oldLine,
                newLineNumber: newLine,
              ));
              oldLine++;
              newLine++;
            }
            i++;
          }

          hunks.add(DiffHunk(
            oldStart: header.$1,
            oldCount: header.$2,
            newStart: header.$3,
            newCount: header.$4,
            lines: hunkLines,
          ));
        }

        final stats = _computeStats(hunks);
        diffs.add(FileDiff(path: newPath, oldPath: oldPath, hunks: hunks, stats: stats));
      } else {
        i++;
      }
    }
    return diffs;
  }

  /// Perform a three-way merge between [base], [ours], and [theirs].
  MergeResult threeWayMerge(String base, String ours, String theirs) {
    final baseLines = base.split('\n');
    final ourLines = ours.split('\n');
    final theirLines = theirs.split('\n');

    final ourEdits = _myersDiff(baseLines, ourLines);
    final theirEdits = _myersDiff(baseLines, theirLines);

    final ourChanges = ourEdits.where((e) => e.type != _EditType.equal).toList();
    final theirChanges = theirEdits.where((e) => e.type != _EditType.equal).toList();

    final merged = <String>[];
    final conflicts = <ConflictRegion>[];

    final ourMap = <int, List<String>>{};
    final theirMap = <int, List<String>>{};
    final ourDeletes = <int>{};
    final theirDeletes = <int>{};

    for (final c in ourChanges) {
      if (c.type == _EditType.delete) ourDeletes.add(c.oldIndex);
      if (c.type == _EditType.insert) {
        ourMap.putIfAbsent(c.oldIndex, () => []).add(ourLines[c.newIndex]);
      }
    }
    for (final c in theirChanges) {
      if (c.type == _EditType.delete) theirDeletes.add(c.oldIndex);
      if (c.type == _EditType.insert) {
        theirMap.putIfAbsent(c.oldIndex, () => []).add(theirLines[c.newIndex]);
      }
    }

    for (var baseIdx = 0; baseIdx < baseLines.length; baseIdx++) {
      final ourDel = ourDeletes.contains(baseIdx);
      final theirDel = theirDeletes.contains(baseIdx);
      final ourIns = ourMap[baseIdx];
      final theirIns = theirMap[baseIdx];

      if (ourDel == theirDel && _listEq(ourIns, theirIns)) {
        if (!ourDel) merged.add(baseLines[baseIdx]);
        if (ourIns != null) merged.addAll(ourIns);
        continue;
      }

      if (!ourDel && ourIns == null) {
        if (!theirDel) merged.add(baseLines[baseIdx]);
        if (theirIns != null) merged.addAll(theirIns);
        continue;
      }
      if (!theirDel && theirIns == null) {
        if (!ourDel) merged.add(baseLines[baseIdx]);
        if (ourIns != null) merged.addAll(ourIns);
        continue;
      }

      final startLine = merged.length + 1;
      final ourBlock = <String>[];
      final theirBlock = <String>[];
      if (!ourDel) ourBlock.add(baseLines[baseIdx]);
      if (ourIns != null) ourBlock.addAll(ourIns);
      if (!theirDel) theirBlock.add(baseLines[baseIdx]);
      if (theirIns != null) theirBlock.addAll(theirIns);

      conflicts.add(ConflictRegion(
        base: [baseLines[baseIdx]],
        ours: ourBlock,
        theirs: theirBlock,
        startLine: startLine,
      ));

      merged.add('<<<<<<< ours');
      merged.addAll(ourBlock);
      merged.add('=======');
      merged.addAll(theirBlock);
      merged.add('>>>>>>> theirs');
    }

    final ourTrail = ourMap[baseLines.length];
    final theirTrail = theirMap[baseLines.length];
    if (ourTrail != null) merged.addAll(ourTrail);
    if (theirTrail != null) merged.addAll(theirTrail);

    return MergeResult(merged: merged.join('\n'), conflicts: conflicts);
  }

  /// Compute word-level inline diff between [oldLine] and [newLine].
  (List<InlineSpan>, List<InlineSpan>) highlightInlineDiff(
    String oldLine,
    String newLine,
  ) {
    final oldTokens = _tokenize(oldLine);
    final newTokens = _tokenize(newLine);
    final edits = _myersDiff(oldTokens, newTokens);

    final oldSpans = <InlineSpan>[];
    final newSpans = <InlineSpan>[];

    for (final edit in edits) {
      switch (edit.type) {
        case _EditType.equal:
          oldSpans.add(InlineSpan(text: oldTokens[edit.oldIndex], isChanged: false));
          newSpans.add(InlineSpan(text: newTokens[edit.newIndex], isChanged: false));
        case _EditType.delete:
          oldSpans.add(InlineSpan(text: oldTokens[edit.oldIndex], isChanged: true));
        case _EditType.insert:
          newSpans.add(InlineSpan(text: newTokens[edit.newIndex], isChanged: true));
      }
    }

    return (_mergeSpans(oldSpans), _mergeSpans(newSpans));
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  List<DiffHunk> _editsToHunks(
    List<_Edit> edits,
    List<String> oldLines,
    List<String> newLines,
    int contextLines,
  ) {
    if (edits.isEmpty) return const [];

    final changeIndices = <int>[];
    for (var i = 0; i < edits.length; i++) {
      if (edits[i].type != _EditType.equal) changeIndices.add(i);
    }
    if (changeIndices.isEmpty) return const [];

    final groups = <List<int>>[];
    var currentGroup = <int>[changeIndices.first];

    for (var i = 1; i < changeIndices.length; i++) {
      if (changeIndices[i] - changeIndices[i - 1] <= contextLines * 2 + 1) {
        currentGroup.add(changeIndices[i]);
      } else {
        groups.add(currentGroup);
        currentGroup = [changeIndices[i]];
      }
    }
    groups.add(currentGroup);

    final hunks = <DiffHunk>[];
    for (final group in groups) {
      final first = group.first;
      final last = group.last;
      final startIdx = math.max(0, first - contextLines);
      final endIdx = math.min(edits.length - 1, last + contextLines);

      final hunkLines = <DiffLine>[];
      int? hunkOldStart;
      int? hunkNewStart;
      var oldCount = 0;
      var newCount = 0;

      for (var i = startIdx; i <= endIdx; i++) {
        final edit = edits[i];
        hunkOldStart ??= edit.oldIndex + 1;
        hunkNewStart ??= edit.newIndex + 1;

        switch (edit.type) {
          case _EditType.equal:
            hunkLines.add(DiffLine(
              type: DiffLineType.context,
              content: oldLines[edit.oldIndex],
              oldLineNumber: edit.oldIndex + 1,
              newLineNumber: edit.newIndex + 1,
            ));
            oldCount++;
            newCount++;
          case _EditType.delete:
            hunkLines.add(DiffLine(
              type: DiffLineType.remove,
              content: oldLines[edit.oldIndex],
              oldLineNumber: edit.oldIndex + 1,
            ));
            oldCount++;
          case _EditType.insert:
            hunkLines.add(DiffLine(
              type: DiffLineType.add,
              content: newLines[edit.newIndex],
              newLineNumber: edit.newIndex + 1,
            ));
            newCount++;
        }
      }

      hunks.add(DiffHunk(
        oldStart: hunkOldStart ?? 1,
        oldCount: oldCount,
        newStart: hunkNewStart ?? 1,
        newCount: newCount,
        lines: hunkLines,
      ));
    }
    return hunks;
  }

  DiffStats _computeStats(List<DiffHunk> hunks) {
    var additions = 0;
    var deletions = 0;
    for (final hunk in hunks) {
      for (final line in hunk.lines) {
        if (line.type == DiffLineType.add) additions++;
        if (line.type == DiffLineType.remove) deletions++;
      }
    }
    return DiffStats(additions: additions, deletions: deletions);
  }

  Future<List<String>> _listFiles(String dir) async {
    final directory = Directory(dir);
    if (!await directory.exists()) return const [];
    final result = <String>[];
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) result.add(entity.path.substring(dir.length + 1));
    }
    return result;
  }

  (int, int, int, int)? _parseHunkHeader(String line) {
    final re = RegExp(r'^@@ -(\d+),?(\d*) \+(\d+),?(\d*) @@');
    final match = re.firstMatch(line);
    if (match == null) return null;
    return (
      int.parse(match.group(1)!),
      match.group(2)!.isEmpty ? 1 : int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      match.group(4)!.isEmpty ? 1 : int.parse(match.group(4)!),
    );
  }

  String _stripPrefix(String line, String prefix) {
    var result = line.substring(prefix.length);
    if (result.startsWith('a/') || result.startsWith('b/')) {
      result = result.substring(2);
    }
    return result;
  }

  String _pad(String text, int width) {
    if (text.length >= width) return text.substring(0, width);
    return text + ' ' * (width - text.length);
  }

  List<String> _tokenize(String line) {
    final tokens = <String>[];
    final re = RegExp(r'\S+|\s+');
    for (final match in re.allMatches(line)) {
      tokens.add(match.group(0)!);
    }
    return tokens;
  }

  List<InlineSpan> _mergeSpans(List<InlineSpan> spans) {
    if (spans.isEmpty) return spans;
    final merged = <InlineSpan>[];
    var buf = StringBuffer(spans.first.text);
    var current = spans.first.isChanged;

    for (var i = 1; i < spans.length; i++) {
      if (spans[i].isChanged == current) {
        buf.write(spans[i].text);
      } else {
        merged.add(InlineSpan(text: buf.toString(), isChanged: current));
        buf = StringBuffer(spans[i].text);
        current = spans[i].isChanged;
      }
    }
    merged.add(InlineSpan(text: buf.toString(), isChanged: current));
    return merged;
  }

  bool _listEq(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
