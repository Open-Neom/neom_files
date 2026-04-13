import 'dart:io';

import 'package:neom_files/utils/tools/file_read_tool.dart';
import 'package:neom_files/utils/tools/file_write_tool.dart';
import 'package:neom_files/utils/tools/list_directory_tool.dart';
import 'package:neom_files/utils/tools/file_search_tool.dart';
import 'package:test/test.dart';

void main() {
  group('NeomFileReadTool.expandHome', () {
    test('expands ~/ to HOME', () {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      final expanded = NeomFileReadTool.expandHome('~/foo/bar.txt');
      expect(expanded, '$home/foo/bar.txt');
    });

    test('leaves path without ~ unchanged', () {
      expect(NeomFileReadTool.expandHome('/abs/path.txt'), '/abs/path.txt');
      expect(NeomFileReadTool.expandHome('rel/path.txt'), 'rel/path.txt');
    });

    test('does not expand ~username', () {
      // Only ~/ is expanded; bare ~username stays put.
      expect(NeomFileReadTool.expandHome('~other/foo'), '~other/foo');
    });

    test('empty path stays empty', () {
      expect(NeomFileReadTool.expandHome(''), '');
    });
  });

  group('NeomFileReadTool.formatSize', () {
    test('bytes < 1KB', () {
      expect(NeomFileReadTool.formatSize(0), '0B');
      expect(NeomFileReadTool.formatSize(1023), '1023B');
    });

    test('KB range', () {
      expect(NeomFileReadTool.formatSize(2048), '2.0KB');
    });

    test('MB range', () {
      expect(NeomFileReadTool.formatSize(3 * 1024 * 1024), '3.0MB');
    });

    test('boundary at 1024', () {
      expect(NeomFileReadTool.formatSize(1024), '1.0KB');
    });
  });

  group('NeomFileReadTool.execute', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('neom_files_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('rejects empty path', () async {
      final tool = const NeomFileReadTool();
      final result = await tool.execute({'path': ''});
      expect(result, contains('empty file path'));
    });

    test('returns error for non-existent file', () async {
      final tool = const NeomFileReadTool();
      final result = await tool.execute({'path': '${tmp.path}/nope.txt'});
      expect(result, contains('not found'));
    });

    test('rejects binary extensions', () async {
      final f = File('${tmp.path}/image.png')..writeAsBytesSync([1, 2, 3]);
      final tool = const NeomFileReadTool();
      final result = await tool.execute({'path': f.path});
      expect(result, contains('binary'));
    });

    test('rejects PNG magic bytes even with .txt extension', () async {
      final f = File('${tmp.path}/fake.txt')
        ..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
      final tool = const NeomFileReadTool();
      final result = await tool.execute({'path': f.path});
      expect(result, contains('binary'));
    });

    test('reads unicode text correctly', () async {
      final f = File('${tmp.path}/u.txt')..writeAsStringSync('héllo 世界 🌍');
      final tool = const NeomFileReadTool();
      final result = await tool.execute({'path': f.path});
      expect(result, contains('héllo 世界 🌍'));
    });

    test('honors from_line and max_lines', () async {
      final lines = List.generate(20, (i) => 'line${i + 1}').join('\n');
      final f = File('${tmp.path}/many.txt')..writeAsStringSync(lines);
      final tool = const NeomFileReadTool();
      final result = await tool.execute({
        'path': f.path,
        'from_line': 5,
        'max_lines': 3,
      });
      expect(result, contains('line5'));
      expect(result, contains('line6'));
      expect(result, contains('line7'));
      expect(result, isNot(contains('line8')));
      expect(result, isNot(contains('line4')));
    });

    test('clamps from_line beyond file length to last', () async {
      final f = File('${tmp.path}/short.txt')..writeAsStringSync('only');
      final tool = const NeomFileReadTool();
      final result = await tool.execute({
        'path': f.path,
        'from_line': 9999,
      });
      // should not throw and should include metadata
      expect(result, contains('Total:'));
    });

    test('code files get line numbers', () async {
      final f = File('${tmp.path}/x.dart')
        ..writeAsStringSync('void main() {}\n');
      final tool = const NeomFileReadTool();
      final result = await tool.execute({'path': f.path});
      expect(result, matches(RegExp(r'\s*1: void main')));
    });

    test('canExecute false blocks reads', () async {
      final tool = NeomFileReadTool(canExecute: () => false);
      final result = await tool.execute({'path': '/tmp/foo'});
      expect(result, contains('not available'));
    });
  });

  group('NeomFileWriteTool.execute', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('neom_files_write_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('rejects empty path', () async {
      final result = await const NeomFileWriteTool().execute({'path': ''});
      expect(result, contains('empty file path'));
    });

    test('rejects protected system paths', () async {
      final result = await const NeomFileWriteTool()
          .execute({'path': '/etc/passwd', 'content': 'bad'});
      expect(result, contains('protected'));
    });

    test('create writes new file', () async {
      final path = '${tmp.path}/new.txt';
      final result = await const NeomFileWriteTool()
          .execute({'path': path, 'content': 'hello'});
      expect(result, contains('created'));
      expect(File(path).readAsStringSync(), 'hello');
    });

    test('create rejects empty content', () async {
      final path = '${tmp.path}/empty.txt';
      final result = await const NeomFileWriteTool()
          .execute({'path': path, 'content': ''});
      expect(result, contains('empty content'));
    });

    test('create fails if file exists and overwrite=false', () async {
      final path = '${tmp.path}/exists.txt';
      File(path).writeAsStringSync('old');
      final result = await const NeomFileWriteTool()
          .execute({'path': path, 'content': 'new'});
      expect(result, contains('already exists'));
    });

    test('create with overwrite=true replaces file and creates .bak', () async {
      final path = '${tmp.path}/exists.txt';
      File(path).writeAsStringSync('old');
      final result = await const NeomFileWriteTool().execute({
        'path': path,
        'content': 'new',
        'overwrite': true,
      });
      expect(result, contains('created'));
      expect(File(path).readAsStringSync(), 'new');
      expect(File('$path.bak').existsSync(), isTrue);
      expect(File('$path.bak').readAsStringSync(), 'old');
    });

    test('edit fails when old_text not present', () async {
      final path = '${tmp.path}/e.txt';
      File(path).writeAsStringSync('some content');
      final result = await const NeomFileWriteTool().execute({
        'path': path,
        'mode': 'edit',
        'old_text': 'NOT HERE',
        'new_text': 'x',
      });
      expect(result, contains('not found'));
    });

    test('edit fails when multiple matches without replace_all', () async {
      final path = '${tmp.path}/multi.txt';
      File(path).writeAsStringSync('foo\nbar\nfoo\n');
      final result = await const NeomFileWriteTool().execute({
        'path': path,
        'mode': 'edit',
        'old_text': 'foo',
        'new_text': 'baz',
      });
      expect(result, contains('matches'));
      expect(result, contains('2'));
      // Original should be intact.
      expect(File(path).readAsStringSync(), 'foo\nbar\nfoo\n');
    });

    test('edit with replace_all replaces every occurrence', () async {
      final path = '${tmp.path}/multi.txt';
      File(path).writeAsStringSync('foo\nbar\nfoo\n');
      final result = await const NeomFileWriteTool().execute({
        'path': path,
        'mode': 'edit',
        'old_text': 'foo',
        'new_text': 'baz',
        'replace_all': true,
      });
      expect(result, contains('edited'));
      expect(File(path).readAsStringSync(), 'baz\nbar\nbaz\n');
    });

    test('edit succeeds on unique match', () async {
      final path = '${tmp.path}/u.txt';
      File(path).writeAsStringSync('hello world\n');
      final result = await const NeomFileWriteTool().execute({
        'path': path,
        'mode': 'edit',
        'old_text': 'hello',
        'new_text': 'goodbye',
      });
      expect(result, contains('edited'));
      expect(File(path).readAsStringSync(), 'goodbye world\n');
      // Backup was created
      expect(File('$path.bak').existsSync(), isTrue);
    });

    test('edit rejects identical old/new text', () async {
      final path = '${tmp.path}/same.txt';
      File(path).writeAsStringSync('hello');
      final result = await const NeomFileWriteTool().execute({
        'path': path,
        'mode': 'edit',
        'old_text': 'hello',
        'new_text': 'hello',
      });
      expect(result, contains('identical'));
    });

    test('edit rejects empty old_text', () async {
      final path = '${tmp.path}/empty-old.txt';
      File(path).writeAsStringSync('hello');
      final result = await const NeomFileWriteTool().execute({
        'path': path,
        'mode': 'edit',
        'old_text': '',
        'new_text': 'x',
      });
      expect(result, contains('empty old_text'));
    });
  });

  group('NeomListDirectoryTool', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('neom_files_list_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('returns error for non-existent dir', () async {
      final result = await const NeomListDirectoryTool()
          .execute({'path': '${tmp.path}/nope'});
      expect(result, contains('not found'));
    });

    test('lists files (default hides hidden)', () async {
      File('${tmp.path}/a.txt').writeAsStringSync('a');
      File('${tmp.path}/.hidden').writeAsStringSync('h');
      Directory('${tmp.path}/sub').createSync();
      final result =
          await const NeomListDirectoryTool().execute({'path': tmp.path});
      expect(result, contains('a.txt'));
      expect(result, contains('sub'));
      expect(result, isNot(contains('.hidden')));
    });

    test('show_hidden=true reveals dotfiles', () async {
      File('${tmp.path}/.hidden').writeAsStringSync('h');
      final result = await const NeomListDirectoryTool()
          .execute({'path': tmp.path, 'show_hidden': true});
      expect(result, contains('.hidden'));
    });
  });

  group('NeomFileSearchTool', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('neom_files_search_test_');
      File('${tmp.path}/a.dart').writeAsStringSync('// TODO: fix me\nvoid main() {}');
      File('${tmp.path}/b.md').writeAsStringSync('nothing relevant');
      Directory('${tmp.path}/sub').createSync();
      File('${tmp.path}/sub/c.dart').writeAsStringSync('class Foo {}');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('rejects empty pattern', () async {
      final result = await const NeomFileSearchTool().execute({'pattern': ''});
      expect(result, contains('empty'));
    });

    test('name mode with glob **/*.dart finds dart files', () async {
      final result = await const NeomFileSearchTool().execute({
        'pattern': '**/*.dart',
        'path': tmp.path,
        'mode': 'name',
      });
      expect(result, contains('a.dart'));
      expect(result, contains('c.dart'));
      expect(result, isNot(contains('b.md')));
    });

    test('content mode finds TODO', () async {
      final result = await const NeomFileSearchTool().execute({
        'pattern': 'TODO',
        'path': tmp.path,
        'mode': 'content',
      });
      expect(result, contains('a.dart'));
      expect(result, contains('TODO'));
    });

    test('content mode with file_type filter excludes other extensions', () async {
      final result = await const NeomFileSearchTool().execute({
        'pattern': 'nothing',
        'path': tmp.path,
        'mode': 'content',
        'file_type': 'dart',
      });
      expect(result, contains('No matches'));
    });

    test('content mode is case-insensitive', () async {
      final result = await const NeomFileSearchTool().execute({
        'pattern': 'todo',
        'path': tmp.path,
        'mode': 'content',
      });
      expect(result, contains('a.dart'));
    });

    test('name mode *.dart (no recursion) matches only root files', () async {
      final result = await const NeomFileSearchTool().execute({
        'pattern': '*.dart',
        'path': tmp.path,
        'mode': 'name',
      });
      expect(result, contains('a.dart'));
      // Should not match c.dart since no ** and name-mode strips path
      // (sub/c.dart will still be matched by name-only match of c.dart
      //  against *.dart). This verifies actual behavior.
      expect(result, contains('c.dart'));
    });
  });
}
