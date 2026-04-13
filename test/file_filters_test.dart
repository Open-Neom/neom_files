import 'package:test/test.dart';
import 'package:neom_files/utils/file_filters.dart';

void main() {
  group('FileFilters.shouldSkip', () {
    test('empty path is skipped', () {
      expect(FileFilters.shouldSkip(''), isTrue);
    });

    test('skips generated Dart files', () {
      expect(FileFilters.shouldSkip('lib/models/user.freezed.dart'), isTrue);
      expect(FileFilters.shouldSkip('lib/models/user.g.dart'), isTrue);
    });

    test('skips build artifacts', () {
      expect(FileFilters.shouldSkip('project/build/out.js'), isTrue);
      expect(FileFilters.shouldSkip('project/.dart_tool/cache'), isTrue);
    });

    test('skips node_modules', () {
      expect(FileFilters.shouldSkip('app/node_modules/react/index.js'), isTrue);
    });

    test('skips hidden dot-dirs', () {
      expect(FileFilters.shouldSkip('project/.git/config'), isTrue);
      expect(FileFilters.shouldSkip('project/.idea/workspace.xml'), isTrue);
    });

    test('allows regular source files', () {
      expect(FileFilters.shouldSkip('lib/main.dart'), isFalse);
      expect(FileFilters.shouldSkip('src/index.ts'), isFalse);
    });

    test('Windows-style paths are normalized', () {
      expect(
        FileFilters.shouldSkip(r'C:\project\build\out.exe'),
        isTrue,
      );
    });

    test('extraSkip extends default list', () {
      expect(
        FileFilters.shouldSkip(
          'lib/foo.custom.dart',
          extraSkip: const ['.custom.dart'],
        ),
        isTrue,
      );
    });

    test('overrideSkip replaces default list', () {
      expect(
        FileFilters.shouldSkip(
          'lib/foo.freezed.dart',
          overrideSkip: const ['only_this'],
        ),
        isFalse,
      );
    });
  });

  group('FileFilters.normalizeIncludePaths', () {
    test('adds trailing slash to directories', () {
      expect(
        FileFilters.normalizeIncludePaths(['lib', 'src']),
        equals(['lib/', 'src/']),
      );
    });

    test('leaves files with extensions as-is', () {
      expect(
        FileFilters.normalizeIncludePaths(['lib/main.dart']),
        equals(['lib/main.dart']),
      );
    });

    test('converts backslashes', () {
      expect(
        FileFilters.normalizeIncludePaths([r'lib\models']),
        equals(['lib/models/']),
      );
    });

    test('drops empty paths', () {
      expect(
        FileFilters.normalizeIncludePaths(['', 'lib', '  ']),
        equals(['lib/']),
      );
    });
  });

  group('FileFilters.isIncluded', () {
    test('empty includes matches everything', () {
      expect(FileFilters.isIncluded('any/path.dart', const []), isTrue);
    });

    test('directory include matches files inside', () {
      expect(
        FileFilters.isIncluded('lib/main.dart', const ['lib']),
        isTrue,
      );
    });

    test('file include matches exact file', () {
      expect(
        FileFilters.isIncluded('lib/main.dart', const ['lib/main.dart']),
        isTrue,
      );
    });

    test('returns false for non-matching path', () {
      expect(
        FileFilters.isIncluded('test/foo_test.dart', const ['lib']),
        isFalse,
      );
    });
  });
}
