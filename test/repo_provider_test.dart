import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/providers/repo_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.spotiflac/backend');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, null);
  });

  group('RepoNotifier.initialize concurrency guard', () {
    test(
      'a second overlapping call reuses the same in-flight future instead '
      'of starting a duplicate init',
      () async {
        SharedPreferences.setMockInitialValues({});

        var initExtensionRepoCalls = 0;
        var getRepoExtensionsCalls = 0;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(backendChannel, (call) async {
              switch (call.method) {
                case 'initExtensionRepo':
                  initExtensionRepoCalls++;
                  return null;
                case 'setRepoRegistryUrl':
                  return null;
                case 'getRepoExtensions':
                  getRepoExtensionsCalls++;
                  // Empty registry -> autoSyncExtensions() is a no-op, so
                  // this test stays focused on the initialize()-level guard
                  // rather than exercising install/update plumbing too.
                  return <Map<String, dynamic>>[];
                default:
                  return null;
              }
            });

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(repoProvider.notifier);

        // Both calls are issued synchronously, before either has had a
        // chance to reach an `await` past the guard checks — this is
        // exactly the window the reviewer flagged: two callers racing in
        // before `state.isInitialized` flips true.
        final future1 = notifier.initialize('/tmp/cache');
        final future2 = notifier.initialize('/tmp/cache');

        expect(
          identical(future1, future2),
          isTrue,
          reason:
              'second call while the first is in flight must return the '
              'same Future, not kick off a duplicate init',
        );

        await Future.wait([future1, future2]);

        expect(initExtensionRepoCalls, 1);
        expect(getRepoExtensionsCalls, 1);
        expect(container.read(repoProvider).isInitialized, isTrue);

        // A call after completion must take the isInitialized fast path,
        // not run initialization a second time.
        await notifier.initialize('/tmp/cache');
        expect(initExtensionRepoCalls, 1);
        expect(getRepoExtensionsCalls, 1);
      },
    );

    test(
      'a failed init clears the in-flight guard so a later retry can run',
      () async {
        SharedPreferences.setMockInitialValues({});

        var initExtensionRepoCalls = 0;
        var shouldFail = true;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(backendChannel, (call) async {
              switch (call.method) {
                case 'initExtensionRepo':
                  initExtensionRepoCalls++;
                  if (shouldFail) {
                    throw PlatformException(code: 'init_failed');
                  }
                  return null;
                case 'setRepoRegistryUrl':
                  return null;
                case 'getRepoExtensions':
                  return <Map<String, dynamic>>[];
                default:
                  return null;
              }
            });

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(repoProvider.notifier);

        await notifier.initialize('/tmp/cache');
        expect(container.read(repoProvider).isInitialized, isFalse);
        expect(container.read(repoProvider).error, isNotNull);
        expect(initExtensionRepoCalls, 1);

        // The failure must not leave a stale in-flight future behind —
        // a later retry has to actually re-run init, not hang forever
        // awaiting the first (failed) attempt's future.
        shouldFail = false;
        await notifier.initialize('/tmp/cache');
        expect(initExtensionRepoCalls, 2);
        expect(container.read(repoProvider).isInitialized, isTrue);
      },
    );
  });
}
