import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/repo_provider.dart';

RepoExtension _ext({
  required String id,
  bool isInstalled = false,
  bool hasUpdate = false,
}) {
  return RepoExtension(
    id: id,
    name: id,
    displayName: id,
    version: '1.0.0',
    description: '',
    downloadUrl: 'https://example.com/$id.sflx',
    category: 'metadata',
    updatedAt: '',
    isInstalled: isInstalled,
    hasUpdate: hasUpdate,
  );
}

void main() {
  group('extensionsNeedingSync', () {
    test('includes not-installed extensions', () {
      final result = extensionsNeedingSync([_ext(id: 'a')]);
      expect(result.map((e) => e.id), ['a']);
    });

    test('includes installed extensions with an available update', () {
      final result = extensionsNeedingSync([
        _ext(id: 'a', isInstalled: true, hasUpdate: true),
      ]);
      expect(result.map((e) => e.id), ['a']);
    });

    test('excludes installed extensions that are already up to date', () {
      final result = extensionsNeedingSync([_ext(id: 'a', isInstalled: true)]);
      expect(result, isEmpty);
    });

    test('preserves order and handles a mix', () {
      final result = extensionsNeedingSync([
        _ext(id: 'a', isInstalled: true),
        _ext(id: 'b'),
        _ext(id: 'c', isInstalled: true, hasUpdate: true),
      ]);
      expect(result.map((e) => e.id), ['b', 'c']);
    });
  });
}
