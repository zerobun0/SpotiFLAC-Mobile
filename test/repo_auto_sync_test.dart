import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

Map<String, dynamic> _registryJson({
  required String id,
  bool isInstalled = false,
  bool hasUpdate = false,
}) {
  return <String, dynamic>{
    'id': id,
    'name': id,
    'display_name': id,
    'version': '1.0.0',
    'description': '',
    'download_url': 'https://example.com/$id.sflx',
    'category': 'metadata',
    'updated_at': '',
    'is_installed': isInstalled,
    'has_update': hasUpdate,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.spotiflac/backend');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  // settingsProvider (pulled in transitively by extensionProvider's
  // reconcile passes) reads secure storage during build().
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
          if (call.method == 'readAll') return <String, String>{};
          return null;
        });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(backendChannel, null);
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
  });

  group('RepoNotifier.autoSyncExtensions', () {
    late List<String> enabledCalls;
    late int getRepoExtensionsCalls;

    void installHandlers(List<Map<String, dynamic>> registry) {
      enabledCalls = <String>[];
      getRepoExtensionsCalls = 0;

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
        // Both getTemporaryDirectory and getApplicationDocumentsDirectory.
        return '/tmp/spotiflac-test';
      });
      messenger.setMockMethodCallHandler(backendChannel, (call) async {
        switch (call.method) {
          case 'getRepoExtensions':
            getRepoExtensionsCalls++;
            return registry;
          case 'downloadRepoExtension':
            final args = call.arguments as Map<Object?, Object?>;
            return '/tmp/spotiflac-test/${args['extension_id']}.sflx';
          case 'loadExtensionFromPath':
          case 'upgradeExtension':
            return <String, dynamic>{'name': 'ext'};
          case 'getInstalledExtensions':
            return <Map<String, dynamic>>[];
          case 'setExtensionEnabled':
            final args = call.arguments as Map<Object?, Object?>;
            if (args['enabled'] == true) {
              enabledCalls.add(args['extension_id'] as String);
            }
            return null;
          default:
            return null;
        }
      });
    }

    test(
      'force-enables freshly installed extensions but leaves already-installed '
      'ones alone',
      () async {
        SharedPreferences.setMockInitialValues({});
        installHandlers([
          _registryJson(id: 'fresh'),
          _registryJson(id: 'stale', isInstalled: true, hasUpdate: true),
          _registryJson(id: 'current', isInstalled: true),
        ]);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(repoProvider.notifier);

        await notifier.refresh();
        await notifier.autoSyncExtensions();

        // 'fresh' was not installed before, so it must be enabled — the
        // native extension manager loads everything disabled, and nothing
        // else in the auto-bundle path would ever turn it on.
        expect(enabledCalls, ['fresh']);
        // 'stale' took the *update* path: it was already installed, so the
        // user may have deliberately disabled it. Never force it back on.
        expect(enabledCalls, isNot(contains('stale')));
        // 'current' needed no sync at all.
        expect(enabledCalls, isNot(contains('current')));
      },
    );

    test('refreshes the registry once for the whole batch, not per extension', () async {
      SharedPreferences.setMockInitialValues({});
      installHandlers([
        _registryJson(id: 'a'),
        _registryJson(id: 'b'),
        _registryJson(id: 'c', isInstalled: true, hasUpdate: true),
      ]);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(repoProvider.notifier);

      await notifier.refresh();
      expect(getRepoExtensionsCalls, 1);

      await notifier.autoSyncExtensions();

      // One batch refresh after the loop. Before this fix each of the three
      // install/update calls triggered its own registry fetch (4 total).
      expect(getRepoExtensionsCalls, 2);
    });

    test('a failed enable does not abort the rest of the sync', () async {
      SharedPreferences.setMockInitialValues({});
      installHandlers([_registryJson(id: 'a'), _registryJson(id: 'b')]);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(backendChannel, (call) async {
        switch (call.method) {
          case 'getRepoExtensions':
            return [_registryJson(id: 'a'), _registryJson(id: 'b')];
          case 'downloadRepoExtension':
            return '/tmp/spotiflac-test/x.sflx';
          case 'loadExtensionFromPath':
            return <String, dynamic>{'name': 'ext'};
          case 'getInstalledExtensions':
            return <Map<String, dynamic>>[];
          case 'setExtensionEnabled':
            final args = call.arguments as Map<Object?, Object?>;
            final id = args['extension_id'] as String;
            calls.add(id);
            if (id == 'a') {
              throw PlatformException(code: 'runtime_not_ready');
            }
            return null;
          default:
            return null;
        }
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(repoProvider.notifier);

      await notifier.refresh();
      await notifier.autoSyncExtensions();

      expect(calls, ['a', 'b']);
    });
  });

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
