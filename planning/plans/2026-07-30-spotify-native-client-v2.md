# Spotify Native Client v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden already-merged Phase 1 Spotify code, auto-bundle the extension ecosystem with zero manual setup, add a first-party personalized Home feed backed by a real logged-in Spotify web session, relocate the Spotify library UI into the app's native Library tab, default streaming to a fast/lossy tier, and route Spotify-streamed playback through the app's existing, already fully-featured music player instead of a disconnected bespoke one.

**Architecture:** Six independent-but-sequenced slices against the existing `spotify_*` feature files from Phase 1 plus a handful of pre-existing app-wide files (`repo_provider.dart`, `explore_provider.dart`, `main_shell.dart`, `music_player_provider.dart`). No new architecture is introduced — every part is either a targeted bug fix, new orchestration calling already-existing methods, or a rewire of an existing pipeline. The one new dependency is `webview_flutter` (Part 2's login screen); everything else uses packages already in `pubspec.yaml`.

**Tech Stack:** Flutter/Dart, `flutter_riverpod` 3.3.2 (manual `Notifier`/`NotifierProvider`, no codegen), `http` (already a dependency, including its bundled `package:http/testing.dart` `MockClient` for the rate-limit test — no new test-only dependency needed), `flutter_secure_storage` (already a dependency), `path_provider` (already a dependency), `webview_flutter` (**new** — Part 2 only), Go (`go_backend/`, gomobile-exported plain functions returning JSON strings, matching the existing `deezer.go`/`exports_deezer.go` split).

## Global Constraints

- Every task in Part 0 and Part 5 modifies already-merged, already-reviewed Phase 1 code — read the current file before editing; do not assume the summaries below are byte-exact.
- No client secret is ever stored on-device — unchanged from Phase 1 (PKCE-only OAuth). The new Part 2 session cookie is a different credential (a real user's `sp_dc` web session cookie, not an OAuth secret) and is stored the same way Phase 1 stores OAuth tokens: `flutter_secure_storage`, never `shared_preferences`, never logged.
- All new/modified Riverpod state follows the house pattern: immutable state class with `copyWith`, `class XNotifier extends Notifier<XState>`, `build()` does light sync init only, singleton services for I/O, final `NotifierProvider` declared at file end. No `@riverpod` codegen.
- Android only — no iOS changes (matches Phase 1).
- Do not modify any file under `extensions/` or the `SpotiFLAC-Extension` repo itself — Part 1's auto-update relies on the registry's extensions staying exactly as published upstream.
- `flutter analyze` and `flutter test` must both be clean before any task's commit — matches the Phase 1 plan's final-review finding that untyped test fixtures broke `analyze` even with passing tests.

---

### Task 1: Rate-limit handling in `SpotifyLibraryService`

**Files:**
- Modify: `lib/services/spotify_library_service.dart` (the `_get` method, lines 23-33)
- Test: `test/spotify_library_service_test.dart` (new)

**Interfaces:**
- Consumes: nothing new.
- Produces: `_get` now retries once on HTTP 429, reading the `Retry-After` header (seconds) before retrying. No public signature changes — `getPlaylists`/`getLikedTracks`/`getFollowedArtists`/`getPlaylistTracks` are unaffected callers.

- [ ] **Step 1: Write the failing tests**

`package:http/testing.dart`'s `MockClient` ships inside the `http` package (already a dependency) — no new test dependency is needed, matching this project's existing preference to avoid adding mocking libraries.

```dart
// test/spotify_library_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spotiflac_android/services/spotify_library_service.dart';

void main() {
  group('SpotifyLibraryService rate limiting', () {
    test('retries once after a 429 with Retry-After, then succeeds', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          return http.Response('', 429, headers: {'retry-after': '0'});
        }
        return http.Response('{"items": [], "next": null}', 200);
      });
      final service = SpotifyLibraryService(
        getAccessToken: () async => 'token',
        httpClient: client,
      );

      final page = await service.getPlaylists();

      expect(callCount, 2);
      expect(page.items, isEmpty);
    });

    test('a second consecutive 429 surfaces as SpotifyApiException', () async {
      final client = MockClient((request) async {
        return http.Response('', 429, headers: {'retry-after': '0'});
      });
      final service = SpotifyLibraryService(
        getAccessToken: () async => 'token',
        httpClient: client,
      );

      await expectLater(
        service.getPlaylists(),
        throwsA(isA<SpotifyApiException>()),
      );
    });

    test('a missing Retry-After header falls back to a 1-second delay', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        if (callCount == 1) return http.Response('', 429);
        return http.Response('{"items": [], "next": null}', 200);
      });
      final service = SpotifyLibraryService(
        getAccessToken: () async => 'token',
        httpClient: client,
      );

      final stopwatch = Stopwatch()..start();
      await service.getPlaylists();
      stopwatch.stop();

      expect(callCount, 2);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900));
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('a non-429 error still throws immediately without retrying', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return http.Response('server error', 500);
      });
      final service = SpotifyLibraryService(
        getAccessToken: () async => 'token',
        httpClient: client,
      );

      await expectLater(
        service.getPlaylists(),
        throwsA(isA<SpotifyApiException>()),
      );
      expect(callCount, 1);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/spotify_library_service_test.dart`
Expected: FAIL — no 429 handling exists yet, so the mismatched-status-code path throws `SpotifyApiException` on the first 429 instead of retrying (test 1 and 3 fail; test 4 passes already; test 2 already passes).

- [ ] **Step 3: Implement**

```dart
// lib/services/spotify_library_service.dart — replace the existing _get method
  Future<Map<String, dynamic>> _get(String url) async {
    var response = await _getOnce(url);
    if (response.statusCode == 429) {
      final delaySeconds = _parseRetryAfterSeconds(response.headers['retry-after']);
      await Future<void>.delayed(Duration(seconds: delaySeconds));
      response = await _getOnce(url);
    }
    if (response.statusCode != 200) {
      throw SpotifyApiException(response.statusCode, response.body);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<http.Response> _getOnce(String url) async {
    final token = await _getAccessToken();
    return _httpClient.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer $token'},
    );
  }

  static int _parseRetryAfterSeconds(String? header) {
    if (header == null) return 1;
    return int.tryParse(header.trim()) ?? 1;
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/spotify_library_service_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/services/spotify_library_service.dart test/spotify_library_service_test.dart
git commit -m "fix(spotify): retry Spotify Web API requests once on HTTP 429"
```

---

### Task 2: Incremental liked-tracks pagination in `SpotifyLibraryNotifier`

**Files:**
- Modify: `lib/providers/spotify_library_provider.dart`
- Test: `test/spotify_liked_tracks_accumulation_test.dart` (new)

**Interfaces:**
- Consumes: `SpotifyLikedTrack`, `SpotifyPage<T>` (existing, `lib/models/spotify_library_models.dart`).
- Produces: a new pure reducer `LikedTracksAccumulation appendLikedTracksPage(LikedTracksAccumulation acc, SpotifyPage<SpotifyLikedTrack> page)` plus `class LikedTracksAccumulation { final List<SpotifyLikedTrack> items; final Set<String> seenUrls; }`, both exported from `spotify_library_provider.dart`. `SpotifyLibraryNotifier.syncAll()` behavior changes: it now returns once playlists, followed artists, and the *first* page of liked tracks have loaded, then keeps appending subsequent liked-tracks pages to `state.likedTracks` in the background.

- [ ] **Step 1: Write the failing tests for the pure reducer**

```dart
// test/spotify_liked_tracks_accumulation_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/providers/spotify_library_provider.dart';

SpotifyLikedTrack _track(String id) => SpotifyLikedTrack(
  addedAt: '2026-01-01T00:00:00Z',
  track: SpotifyApiTrack(
    id: id,
    name: 'Track $id',
    artistNames: 'Artist',
    albumName: 'Album',
    albumImageUrl: null,
    isrc: null,
    durationMs: 180000,
  ),
);

void main() {
  group('appendLikedTracksPage', () {
    test('appends a page onto an empty accumulation', () {
      const acc = LikedTracksAccumulation(items: [], seenUrls: {});
      final page = SpotifyPage<SpotifyLikedTrack>(
        items: [_track('1'), _track('2')],
        nextUrl: 'https://api.spotify.com/v1/me/tracks?offset=50',
      );

      final result = appendLikedTracksPage(acc, page)!;

      expect(result.items, hasLength(2));
      expect(result.seenUrls, contains('https://api.spotify.com/v1/me/tracks?offset=50'));
    });

    test('appends onto an existing accumulation without dropping prior items', () {
      final acc = LikedTracksAccumulation(items: [_track('1')], seenUrls: {});
      final page = SpotifyPage<SpotifyLikedTrack>(items: [_track('2')], nextUrl: null);

      final result = appendLikedTracksPage(acc, page)!;

      expect(result.items.map((t) => t.track.id), ['1', '2']);
    });

    test('returns null when nextUrl repeats an already-seen URL', () {
      const acc = LikedTracksAccumulation(
        items: [],
        seenUrls: {'https://api.spotify.com/v1/me/tracks?offset=50'},
      );
      final page = SpotifyPage<SpotifyLikedTrack>(
        items: [_track('1')],
        nextUrl: 'https://api.spotify.com/v1/me/tracks?offset=50',
      );

      expect(appendLikedTracksPage(acc, page), isNull);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/spotify_liked_tracks_accumulation_test.dart`
Expected: FAIL — `LikedTracksAccumulation`/`appendLikedTracksPage` do not exist.

- [ ] **Step 3: Implement the reducer and rewire `syncAll`**

```dart
// lib/providers/spotify_library_provider.dart — add near the top, after imports
class LikedTracksAccumulation {
  final List<SpotifyLikedTrack> items;
  final Set<String> seenUrls;

  const LikedTracksAccumulation({required this.items, required this.seenUrls});
}

/// Pure reducer for incrementally accumulating liked-tracks pages. Returns
/// null when [page.nextUrl] repeats a URL already in [acc.seenUrls] — signals
/// the caller to stop, guarding against a malfunctioning/looping API response
/// that would otherwise keep this fetch running forever.
LikedTracksAccumulation? appendLikedTracksPage(
  LikedTracksAccumulation acc,
  SpotifyPage<SpotifyLikedTrack> page,
) {
  final nextUrl = page.nextUrl;
  if (nextUrl != null && acc.seenUrls.contains(nextUrl)) return null;
  return LikedTracksAccumulation(
    items: [...acc.items, ...page.items],
    seenUrls: nextUrl != null ? {...acc.seenUrls, nextUrl} : acc.seenUrls,
  );
}
```

Replace `SpotifyLibraryNotifier.syncAll()`:

```dart
  Future<void> syncAll() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final playlists = await _collectAllPages(
        (pageUrl) => _service.getPlaylists(pageUrl: pageUrl),
      );
      final followed = await _collectAllPages(
        (pageUrl) => _service.getFollowedArtists(pageUrl: pageUrl),
      );

      // Liked tracks: yield the first page immediately so the Library tab is
      // interactive right away, then keep fetching subsequent pages in the
      // background instead of blocking syncAll() on the full paginated list —
      // this list is the one most likely to run into the hundreds of items.
      final firstPage = await _service.getLikedTracks();
      state = state.copyWith(
        playlists: playlists,
        followedArtists: followed,
        likedTracks: firstPage.items,
        isLoading: false,
      );
      unawaited(
        _syncRemainingLikedTracks(
          LikedTracksAccumulation(items: firstPage.items, seenUrls: {}),
          firstPage.nextUrl,
        ),
      );
    } catch (e) {
      _log.e('Spotify library sync failed', e);
      if (e is SpotifyAuthException) {
        await ref
            .read(spotifyAuthProvider.notifier)
            .logout(error: _spotifySessionExpiredMessage);
        state = state.copyWith(
          isLoading: false,
          error: _spotifySessionExpiredMessage,
        );
        return;
      }
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<void> _syncRemainingLikedTracks(
    LikedTracksAccumulation acc,
    String? nextUrl,
  ) async {
    var current = acc;
    var url = nextUrl;
    while (url != null) {
      try {
        final page = await _service.getLikedTracks(pageUrl: url);
        final next = appendLikedTracksPage(current, page);
        if (next == null) {
          _log.w('Spotify liked-tracks pagination returned a repeated nextUrl; stopping');
          return;
        }
        current = next;
        state = state.copyWith(likedTracks: current.items);
        url = page.nextUrl;
      } catch (e) {
        _log.w('Background liked-tracks page fetch failed: $e');
        return;
      }
    }
  }
```

Add `import 'dart:async';` at the top of the file for `unawaited`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/spotify_liked_tracks_accumulation_test.dart test/spotify_library_provider_test.dart`
Expected: PASS (3 new tests + the 1 existing test)

- [ ] **Step 5: Manual verification**

Log into a real Spotify account with more than 50 liked songs (one API page), open the Spotify Library tab, and confirm the "Liked Songs" list populates with the first ~50 immediately, then grows to the full count a few seconds later without any loading spinner blocking the tab.

- [ ] **Step 6: Commit**

```bash
git add lib/providers/spotify_library_provider.dart test/spotify_liked_tracks_accumulation_test.dart
git commit -m "fix(spotify): stream liked-tracks pages incrementally instead of blocking sync"
```

---

### Task 3: Stuck-login lifecycle reset in `SpotifyAuthNotifier`

**Files:**
- Modify: `lib/providers/spotify_auth_provider.dart`
- Test: `test/spotify_auth_stuck_login_test.dart` (new)

**Interfaces:**
- Consumes: `SpotifyAuthStatus`, `isSpotifyLoginInFlight` (existing).
- Produces: a new pure predicate `bool shouldResetStuckLogin({required bool isLoginInFlight, required Duration timeSinceResume, required Duration graceWindow})`, plus `SpotifyAuthNotifier` now implements `WidgetsBindingObserver` and calls `logout... ` — actually resets to `loggedOut` (not a full logout/token-clear, since no tokens exist yet mid-login) — when the app resumes from background and the login has been pending past the grace window.

- [ ] **Step 1: Write the failing test for the pure predicate**

```dart
// test/spotify_auth_stuck_login_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/spotify_auth_provider.dart';

void main() {
  group('shouldResetStuckLogin', () {
    test('false when no login is in flight', () {
      expect(
        shouldResetStuckLogin(
          isLoginInFlight: false,
          timeSinceResume: const Duration(seconds: 5),
          graceWindow: const Duration(seconds: 2),
        ),
        isFalse,
      );
    });

    test('false when still within the grace window', () {
      expect(
        shouldResetStuckLogin(
          isLoginInFlight: true,
          timeSinceResume: const Duration(milliseconds: 500),
          graceWindow: const Duration(seconds: 2),
        ),
        isFalse,
      );
    });

    test('true once a login is in flight past the grace window', () {
      expect(
        shouldResetStuckLogin(
          isLoginInFlight: true,
          timeSinceResume: const Duration(seconds: 3),
          graceWindow: const Duration(seconds: 2),
        ),
        isTrue,
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/spotify_auth_stuck_login_test.dart`
Expected: FAIL — `shouldResetStuckLogin` does not exist.

- [ ] **Step 3: Implement the predicate and wire it into the notifier**

```dart
// lib/providers/spotify_auth_provider.dart — add near isSpotifyLoginInFlight
/// True when a login has been [isLoginInFlight] for longer than
/// [graceWindow] since the app resumed from the background. Used by
/// [SpotifyAuthNotifier] to escape a stuck `loggingIn` state when the user
/// backs out of the browser without completing login — without this, the
/// only escape is the 5-minute overall login timeout.
bool shouldResetStuckLogin({
  required bool isLoginInFlight,
  required Duration timeSinceResume,
  required Duration graceWindow,
}) {
  return isLoginInFlight && timeSinceResume >= graceWindow;
}
```

Modify `SpotifyAuthNotifier` to observe app lifecycle:

```dart
// lib/providers/spotify_auth_provider.dart — add import
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
```

```dart
// lib/providers/spotify_auth_provider.dart — inside SpotifyAuthNotifier
class SpotifyAuthNotifier extends Notifier<SpotifyAuthState>
    with WidgetsBindingObserver {
  static const _stuckLoginGraceWindow = Duration(seconds: 2);

  final SpotifyAuthService _service = SpotifyAuthService();
  StreamSubscription<Map<String, dynamic>>? _callbackSubscription;
  Completer<Map<String, dynamic>>? _pendingLogin;
  String? _pendingState;
  SpotifyPkcePair? _pendingPkce;
  DateTime? _resumedAt;

  @override
  SpotifyAuthState build() {
    _callbackSubscription = PlatformBridge.spotifyLoginCallbackEvents().listen(
      _handleCallback,
    );
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _callbackSubscription?.cancel();
      WidgetsBinding.instance.removeObserver(this);
    });
    unawaited(_loadInitialStatus());
    return const SpotifyAuthState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState != AppLifecycleState.resumed) return;
    _resumedAt = DateTime.now();
    Future.delayed(_stuckLoginGraceWindow, () {
      final resumedAt = _resumedAt;
      if (resumedAt == null) return;
      final timeSinceResume = DateTime.now().difference(resumedAt);
      if (shouldResetStuckLogin(
        isLoginInFlight: isSpotifyLoginInFlight(state.status),
        timeSinceResume: timeSinceResume,
        graceWindow: _stuckLoginGraceWindow,
      )) {
        _log.w('Spotify login stuck after resume; resetting to loggedOut');
        _pendingLogin = null;
        _pendingState = null;
        _pendingPkce = null;
        state = state.copyWith(
          status: SpotifyAuthStatus.loggedOut,
          error: 'Login was cancelled',
        );
      }
    });
  }

  // ... rest of the class unchanged
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/spotify_auth_stuck_login_test.dart test/spotify_auth_provider_test.dart`
Expected: PASS (3 new tests + the 2 existing tests)

- [ ] **Step 5: Manual verification**

Tap "Connect Spotify", let the external browser open, then press the phone's back button (or Home) to return to the app without completing login. Confirm the app's status reverts to "Connect Spotify" within ~2-3 seconds instead of staying on "Waiting for Spotify login..." for up to 5 minutes.

- [ ] **Step 6: Commit**

```bash
git add lib/providers/spotify_auth_provider.dart test/spotify_auth_stuck_login_test.dart
git commit -m "fix(spotify): reset stuck loggingIn state shortly after app resume"
```

---

### Task 4: Hardcoded default registry + `RepoNotifier.autoSyncExtensions()`

**Files:**
- Modify: `lib/providers/repo_provider.dart`
- Test: `test/repo_auto_sync_test.dart` (new)

**Interfaces:**
- Consumes: `RepoExtension` (existing), `PlatformBridge.setRepoRegistryUrl`/`getRepoExtensions` (existing).
- Produces: `RepoNotifier.initialize(String cacheDir)` now defaults `registryUrl` to a hardcoded constant when no URL is saved, instead of leaving it empty. New method `Future<void> autoSyncExtensions()` on `RepoNotifier`, and a pure helper `List<RepoExtension> extensionsNeedingSync(List<RepoExtension> extensions)` used by it.

- [ ] **Step 1: Write the failing test for the pure selection logic**

```dart
// test/repo_auto_sync_test.dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/repo_auto_sync_test.dart`
Expected: FAIL — `extensionsNeedingSync` does not exist.

- [ ] **Step 3: Implement**

```dart
// lib/providers/repo_provider.dart — add near compareVersions
/// Extensions that [RepoNotifier.autoSyncExtensions] should install or
/// update: anything not yet installed, plus anything installed whose
/// registry version is ahead of what's on-device.
List<RepoExtension> extensionsNeedingSync(List<RepoExtension> extensions) {
  return extensions
      .where((e) => !e.isInstalled || e.hasUpdate)
      .toList(growable: false);
}
```

```dart
// lib/providers/repo_provider.dart — add import
import 'package:path_provider/path_provider.dart';
```

```dart
// lib/providers/repo_provider.dart — inside RepoNotifier, near the top
  static const _defaultRegistryUrl =
      'https://raw.githubusercontent.com/zarzet/SpotiFLAC-Extension/main/registry.json';
```

Modify `initialize`:

```dart
  Future<void> initialize(String cacheDir) async {
    if (state.isInitialized) return;

    final prefs = await SharedPreferences.getInstance();
    var savedUrl = prefs.getString(_registryUrlPrefKey) ?? '';
    if (savedUrl.isEmpty) {
      savedUrl = _defaultRegistryUrl;
      await prefs.setString(_registryUrlPrefKey, savedUrl);
    }

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      registryUrl: savedUrl,
    );

    try {
      await PlatformBridge.initExtensionRepo(cacheDir);
      await PlatformBridge.setRepoRegistryUrl(savedUrl);
      await refresh();
      await autoSyncExtensions();

      state = state.copyWith(isInitialized: true, isLoading: false);
      _log.i('Extension store initialized (registryUrl: $savedUrl)');
    } catch (e) {
      _log.e('Failed to initialize store: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Installs every not-yet-installed registry extension and upgrades every
  /// installed one with an available update, using the exact same
  /// install/upgrade calls the Store tab's manual buttons already make. Safe
  /// to call repeatedly — extensions already up to date are skipped.
  Future<void> autoSyncExtensions() async {
    final targets = extensionsNeedingSync(state.extensions);
    if (targets.isEmpty) return;

    final tempDir = await getTemporaryDirectory();
    final appDir = await getApplicationDocumentsDirectory();
    final extensionsDir = '${appDir.path}/extensions';

    for (final ext in targets) {
      if (!ext.isInstalled) {
        await installExtension(ext.id, tempDir.path, extensionsDir);
      } else {
        await updateExtension(ext.id, tempDir.path);
      }
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/repo_auto_sync_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/providers/repo_provider.dart test/repo_auto_sync_test.dart
git commit -m "feat(repo): default to the community registry and auto-sync all extensions"
```

---

### Task 5: Wire auto-sync into app startup and periodic foreground checks

**Files:**
- Modify: `lib/screens/main_shell.dart`

**Interfaces:**
- Consumes: `repoProvider` (Task 4).
- Produces: no new public interface — this is orchestration inside `_MainShellState`.

- [ ] **Step 1: Add the startup call**

`RepoNotifier.initialize` currently only runs when the user opens the Store tab (`lib/screens/repo_tab.dart:30-38`). Add the same call to `MainShell`'s existing startup sequence so every install gets it automatically. In `_MainShellState.initState`'s `WidgetsBinding.instance.addPostFrameCallback` block (after `_setupShareListener()`, alongside the other one-time startup checks):

```dart
// lib/screens/main_shell.dart — inside the addPostFrameCallback block in initState,
// right after `_setupShareListener();`
      unawaited(_initializeExtensionRepo());
```

Add the method:

```dart
// lib/screens/main_shell.dart — inside _MainShellState
  Future<void> _initializeExtensionRepo() async {
    try {
      final cacheDir = await getApplicationCacheDirectory();
      await ref.read(repoProvider.notifier).initialize(cacheDir.path);
    } catch (e) {
      _log.w('Extension auto-bundle failed: $e');
    }
  }
```

Add imports: `import 'package:path_provider/path_provider.dart';` (not yet imported in this file — `dart:io`/`device_info_plus` are already there, `path_provider` is not).

- [ ] **Step 2: Add the throttled periodic foreground re-check**

`_MainShellState` already implements `WidgetsBindingObserver` and has `didChangeAppLifecycleState` calling `_repairSafAccessIfNeeded()` on resume. Add a throttled sibling call:

```dart
// lib/screens/main_shell.dart — add as a field on _MainShellState
  DateTime? _lastExtensionSyncCheck;
```

```dart
// lib/screens/main_shell.dart — replace didChangeAppLifecycleState
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _initialSafRepairComplete) {
      unawaited(_repairSafAccessIfNeeded());
      unawaited(_maybeSyncExtensionsOnResume());
    }
  }

  /// Re-checks the extension registry for updates at most once an hour of
  /// foreground time — this app has no background service, so "periodic" is
  /// necessarily tied to how often the user actually resumes the app.
  Future<void> _maybeSyncExtensionsOnResume() async {
    final now = DateTime.now();
    if (_lastExtensionSyncCheck != null &&
        now.difference(_lastExtensionSyncCheck!) < const Duration(hours: 1)) {
      return;
    }
    _lastExtensionSyncCheck = now;
    try {
      await ref.read(repoProvider.notifier).refresh(forceRefresh: true);
      await ref.read(repoProvider.notifier).autoSyncExtensions();
    } catch (e) {
      _log.w('Periodic extension sync failed: $e');
    }
  }
```

- [ ] **Step 3: Manual verification**

Fresh-install the app (clear app data or use a new emulator), open it, and — without ever visiting the Store tab — confirm playback works immediately on a track that needs an extension provider (e.g. search and tap a track). Then check the Store tab: all 9 registry extensions should show as installed and enabled with no manual action taken.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/main_shell.dart
git commit -m "feat(repo): auto-initialize and periodically re-sync extensions from app startup"
```

---

### Task 6: WebView Spotify login screen capturing a real session cookie

**Files:**
- Modify: `pubspec.yaml` (add `webview_flutter`)
- Create: `lib/screens/spotify/spotify_web_login_screen.dart`
- Test: `test/spotify_web_login_screen_test.dart` (new)

**Interfaces:**
- Produces: `String? extractSpotifySessionCookie(String rawCookieHeader)` (pure, testable), `const spotifySessionCookieStorageKey = 'spotify_web_session_cookie_v1'`, `class SpotifyWebLoginScreen extends StatefulWidget` — pushed as a full-screen route; pops with `true` on a captured session, or `false`/nothing if the user backs out.

- [ ] **Step 1: Add the dependency**

```bash
flutter pub add webview_flutter
```

This is the one new Flutter package in this whole plan — used for exactly this one screen. Every other part of the app (OAuth login, extension auth) stays on the existing external-browser + custom-URI-scheme pattern; a WebView is only justified here because extracting a real logged-in session's cookies is only possible from inside an embeddable browser control.

- [ ] **Step 2: Write the failing tests for the pure cookie extractor**

```dart
// test/spotify_web_login_screen_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/screens/spotify/spotify_web_login_screen.dart';

void main() {
  group('extractSpotifySessionCookie', () {
    test('finds sp_dc among other cookies', () {
      expect(
        extractSpotifySessionCookie('a=1; sp_dc=AQabc123; b=2'),
        'AQabc123',
      );
    });

    test('returns null when sp_dc is missing', () {
      expect(extractSpotifySessionCookie('a=1; b=2'), isNull);
    });

    test('handles a single cookie with no other entries', () {
      expect(extractSpotifySessionCookie('sp_dc=onlyvalue'), 'onlyvalue');
    });

    test('handles extra whitespace around cookie pairs', () {
      expect(
        extractSpotifySessionCookie('a=1;   sp_dc=withspace  ; b=2'),
        'withspace',
      );
    });
  });
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `flutter test test/spotify_web_login_screen_test.dart`
Expected: FAIL — `spotify_web_login_screen.dart` does not exist.

- [ ] **Step 4: Implement**

```dart
// lib/screens/spotify/spotify_web_login_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyWebLogin');

const spotifySessionCookieStorageKey = 'spotify_web_session_cookie_v1';

/// Extracts the `sp_dc` cookie (Spotify's long-lived web-player session
/// token — the same cookie community tools like spotify-lyrics-api use for
/// authenticated, non-OAuth access) from a raw `document.cookie` string like
/// `a=1; sp_dc=AQabc123; b=2`.
String? extractSpotifySessionCookie(String rawCookieHeader) {
  for (final part in rawCookieHeader.split(';')) {
    final trimmed = part.trim();
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    if (trimmed.substring(0, eq) == 'sp_dc') {
      return trimmed.substring(eq + 1).trim();
    }
  }
  return null;
}

class SpotifyWebLoginScreen extends StatefulWidget {
  const SpotifyWebLoginScreen({super.key});

  @override
  State<SpotifyWebLoginScreen> createState() => _SpotifyWebLoginScreenState();
}

class _SpotifyWebLoginScreenState extends State<SpotifyWebLoginScreen> {
  late final WebViewController _controller;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: _onPageFinished),
      )
      ..loadRequest(Uri.parse('https://accounts.spotify.com/login'));
  }

  Future<void> _onPageFinished(String url) async {
    if (_capturing) return;
    // A successful login redirects from accounts.spotify.com to the logged-in
    // web player at open.spotify.com — that's the signal to capture cookies.
    if (!url.startsWith('https://open.spotify.com')) return;

    _capturing = true;
    try {
      final rawResult = await _controller.runJavaScriptReturningResult(
        'document.cookie',
      );
      // runJavaScriptReturningResult wraps string results in quotes on some
      // platforms.
      final rawCookieHeader = rawResult.toString().replaceAll('"', '');
      final cookie = extractSpotifySessionCookie(rawCookieHeader);
      if (cookie == null || cookie.isEmpty) {
        _log.w('Reached open.spotify.com but found no sp_dc cookie');
        _capturing = false;
        return;
      }
      await const FlutterSecureStorage().write(
        key: spotifySessionCookieStorageKey,
        value: cookie,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _log.e('Failed to capture Spotify session cookie', e);
      _capturing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log in to Spotify')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/spotify_web_login_screen_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 6: Manual verification**

Push `SpotifyWebLoginScreen` from a temporary debug entry point (a button anywhere reachable, removed once Task 8 wires a real one), complete a real Spotify login in the embedded WebView, and confirm the screen pops automatically once `open.spotify.com` loads. Then confirm via a temporary debug read that `flutter_secure_storage` now holds a non-empty value under `spotify_web_session_cookie_v1`.

- [ ] **Step 7: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/screens/spotify/spotify_web_login_screen.dart test/spotify_web_login_screen_test.dart
git commit -m "feat(spotify): add WebView login screen capturing a real session cookie"
```

---

### Task 7: Go backend — personalized home feed from a real session cookie

**Files:**
- Create: `go_backend/spotify_personal.go`
- Create: `go_backend/exports_spotify_personal.go`
- Test: `go_backend/spotify_personal_test.go` (new)

**Interfaces:**
- Consumes: nothing from other tasks (pure Go, network-calling).
- Produces: `func GetSpotifyPersonalHomeFeed(sessionCookie string) (string, error)` — the gomobile-exported entry point Task 8's `PlatformBridge` method calls. Returns a JSON string shaped exactly like the existing extension home-feed contract: `{"success": bool, "error": string, "greeting": string, "sections": [{"uri": string, "title": string, "items": [{"id","uri","type","name","artists","description","cover_url","album_id","album_name","duration_ms","provider_id"}]}]}` — the same shape `ExploreSection.fromJson`/`ExploreItem.fromJson` (`lib/providers/explore_provider.dart`) already parse.

**Protocol notes (read before implementing):** the bundled `spotify-web` extension (`extensions/spotify-web.sflx`'s `index.js`, in the `SpotiFLAC-Extension` repo) already implements the exact partner API this task needs, just anonymously. Its `query()` function `POST`s to `https://api-partner.spotify.com/pathfinder/v2/query` with headers `Authorization: Bearer <accessToken>`, `Client-Token: <clientToken>`, `Spotify-App-Version: <clientVersion>`; its `fetchHomeFeed()` sends `{"operationName": "home", "variables": {"timeZone": ...}, "extensions": {"persistedQuery": {"version": 1, "sha256Hash": "3a67ee0ea6abad2ebad2e588a9aa130fc98d6b553f5b05ac6467503d02133bdc"}}}`. Its `getClientToken()` bootstraps `clientToken` via `POST https://clienttoken.spotify.com/v1/clienttoken` with a `client_data` body (this part is identity-agnostic — the same call works whether the underlying user is anonymous or real, since it identifies the *client*, not the *user*). Its `getAccessToken()` bootstraps the (anonymous) `accessToken` via `GET https://open.spotify.com/api/token?reason=init&productType=web-player&totp=...`, first seeding cookies/`clientVersion` via `GET https://open.spotify.com`. The only thing that changes for a *real* session is attaching the captured `sp_dc` cookie to those two `open.spotify.com` requests instead of going in cookie-less — Spotify's own web player authenticates the exact same way. The anti-bot `totp` parameter is a standard RFC 6238 HMAC-SHA1 TOTP (see the extension's `generateTOTP()`/`generateTOTPCode()`) computed over a small XOR-obfuscated secret table (`TOTP_SECRETS`/`TOTP_VERSION` near the top of `index.js`) — re-implement the same algorithm in Go using the *current* secret table from that file (it has rotated across versions 59/60/61 already and may rotate again; always pull the live value from the file rather than trusting a stale copy) rather than porting the JS line-for-line.

- [ ] **Step 1: Write the failing test for the pure response-shape transform**

The network calls themselves are thin, manually-verified I/O (matching this project's existing precedent for Deezer/Tidal/etc. clients); what's unit-testable without a live network call is the transform from Spotify's raw partner-API JSON into this app's normalized `ExploreSection`-shaped JSON.

```go
// go_backend/spotify_personal_test.go
package gobackend

import (
	"encoding/json"
	"testing"
)

func TestFormatSpotifyHomeFeedResponse(t *testing.T) {
	raw := []byte(`{
		"data": {
			"home": {
				"greeting": {"text": "Good evening"},
				"sectionContainer": {
					"sections": {
						"items": [
							{
								"uri": "section:1",
								"data": {"title": {"text": "Made for you"}},
								"sectionItems": {
									"items": [
										{
											"content": {
												"data": {
													"__typename": "Track",
													"uri": "spotify:track:abc123",
													"name": "Song Name",
													"albumOfTrack": {
														"name": "Album Name",
														"uri": "spotify:album:def456",
														"coverArt": {"sources": [{"url": "https://img/1.jpg"}]}
													},
													"artists": {"items": [{"profile": {"name": "Artist A"}}]},
													"duration": {"totalMilliseconds": 210000}
												}
											}
										}
									]
								}
							}
						]
					}
				}
			}
		}
	}`)

	var parsed map[string]any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("failed to parse fixture: %v", err)
	}

	result := formatSpotifyHomeFeedResponse(parsed)

	if result["greeting"] != "Good evening" {
		t.Fatalf("expected greeting %q, got %v", "Good evening", result["greeting"])
	}
	sections, ok := result["sections"].([]map[string]any)
	if !ok || len(sections) != 1 {
		t.Fatalf("expected 1 section, got %v", result["sections"])
	}
	items, ok := sections[0]["items"].([]map[string]any)
	if !ok || len(items) != 1 {
		t.Fatalf("expected 1 item, got %v", sections[0]["items"])
	}
	item := items[0]
	if item["id"] != "abc123" || item["type"] != "track" {
		t.Fatalf("unexpected item id/type: %v/%v", item["id"], item["type"])
	}
	if item["name"] != "Song Name" || item["artists"] != "Artist A" {
		t.Fatalf("unexpected item name/artists: %v/%v", item["name"], item["artists"])
	}
	if item["album_name"] != "Album Name" || item["album_id"] != "def456" {
		t.Fatalf("unexpected album fields: %v/%v", item["album_name"], item["album_id"])
	}
	if item["cover_url"] != "https://img/1.jpg" {
		t.Fatalf("unexpected cover_url: %v", item["cover_url"])
	}
	if item["duration_ms"] != 210000 {
		t.Fatalf("unexpected duration_ms: %v", item["duration_ms"])
	}
	if item["provider_id"] != "spotify-personal" {
		t.Fatalf("expected provider_id spotify-personal, got %v", item["provider_id"])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd go_backend && go test ./... -run TestFormatSpotifyHomeFeedResponse -v`
Expected: FAIL — `formatSpotifyHomeFeedResponse` does not exist (compile error).

- [ ] **Step 3: Implement `go_backend/spotify_personal.go`**

```go
// go_backend/spotify_personal.go
package gobackend

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Read the CURRENT values from extensions/spotify-web.sflx's index.js
// (TOTP_SECRETS[TOTP_VERSION], TOTP_VERSION) before relying on this — Spotify
// rotates this anti-bot secret table periodically and the bundled extension
// is kept up to date with it independently of this file.
var spotifyTOTPSecretTable = []int{44, 55, 47, 42, 70, 40, 34, 114, 76, 74, 50, 111, 120, 97, 75, 76, 94, 102, 43, 69, 49, 120, 118, 80, 64, 78}
const spotifyTOTPVersion = 61

const spotifyPartnerAPIURL = "https://api-partner.spotify.com/pathfinder/v2/query"
const spotifyClientTokenURL = "https://clienttoken.spotify.com/v1/clienttoken"
const spotifyHomeFeedSHA256Hash = "3a67ee0ea6abad2ebad2e588a9aa130fc98d6b553f5b05ac6467503d02133bdc"

type spotifyPersonalSession struct {
	accessToken   string
	clientToken   string
	clientID      string
	clientVersion string
	cookies       map[string]string
}

func generateSpotifyTOTP() string {
	transformed := make([]byte, len(spotifyTOTPSecretTable))
	for i, b := range spotifyTOTPSecretTable {
		transformed[i] = byte(b ^ ((i % 33) + 9))
	}
	var joined strings.Builder
	for _, b := range transformed {
		joined.WriteString(strconv.Itoa(int(b)))
	}
	var hexBytes bytes.Buffer
	for _, r := range joined.String() {
		hexBytes.WriteByte(byte(r))
	}
	secret := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(hexBytes.Bytes())

	counter := uint64(time.Now().Unix() / 30)
	counterBytes := make([]byte, 8)
	binary.BigEndian.PutUint64(counterBytes, counter)

	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ToUpper(secret))
	if err != nil {
		return "000000"
	}
	mac := hmac.New(sha1.New, key)
	mac.Write(counterBytes)
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	code := (uint32(sum[offset]&0x7f) << 24) |
		(uint32(sum[offset+1]) << 16) |
		(uint32(sum[offset+2]) << 8) |
		uint32(sum[offset+3])
	otp := code % 1000000
	return fmt.Sprintf("%06d", otp)
}

func buildSpotifyCookieHeader(cookies map[string]string) string {
	parts := make([]string, 0, len(cookies))
	for name, value := range cookies {
		parts = append(parts, name+"="+value)
	}
	return strings.Join(parts, "; ")
}

var spotifyAppServerConfigPattern = regexp.MustCompile(`<script id="appServerConfig" type="text/plain">([^<]+)</script>`)

func bootstrapSpotifyPersonalSession(ctx context.Context, client *http.Client, sessionCookie string) (*spotifyPersonalSession, error) {
	session := &spotifyPersonalSession{cookies: map[string]string{"sp_dc": sessionCookie}}

	// Step 1: GET open.spotify.com with the real session cookie attached to
	// seed additional session cookies and read the current clientVersion.
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://open.spotify.com", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Cookie", buildSpotifyCookieHeader(session.cookies))
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 14) SpotiFLAC")
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to load open.spotify.com: %w", err)
	}
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("open.spotify.com returned %d", resp.StatusCode)
	}
	mergeSpotifySetCookies(session.cookies, resp.Header.Values("Set-Cookie"))
	if match := spotifyAppServerConfigPattern.FindSubmatch(body); match != nil {
		var cfg struct {
			ClientVersion string `json:"clientVersion"`
		}
		if err := json.Unmarshal(match[1], &cfg); err == nil {
			session.clientVersion = cfg.ClientVersion
		}
	}

	// Step 2: GET the access-token endpoint with the same cookies attached —
	// with a real sp_dc cookie present, this returns a real user's access
	// token instead of an anonymous one.
	totp := generateSpotifyTOTP()
	tokenURL := fmt.Sprintf(
		"https://open.spotify.com/api/token?reason=init&productType=web-player&totp=%s&totpVer=%d&totpServer=%s",
		totp, spotifyTOTPVersion, totp,
	)
	req, err = http.NewRequestWithContext(ctx, http.MethodGet, tokenURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Cookie", buildSpotifyCookieHeader(session.cookies))
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 14) SpotiFLAC")
	resp, err = client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch access token: %w", err)
	}
	body, err = io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("access token request returned %d", resp.StatusCode)
	}
	mergeSpotifySetCookies(session.cookies, resp.Header.Values("Set-Cookie"))

	var tokenResp struct {
		AccessToken string `json:"accessToken"`
		ClientID    string `json:"clientId"`
		IsAnonymous bool   `json:"isAnonymous"`
	}
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return nil, fmt.Errorf("failed to parse access token response: %w", err)
	}
	if tokenResp.AccessToken == "" {
		return nil, fmt.Errorf("empty access token in response")
	}
	if tokenResp.IsAnonymous {
		return nil, fmt.Errorf("session cookie did not yield an authenticated session — it may have expired; please log in again")
	}
	session.accessToken = tokenResp.AccessToken
	session.clientID = tokenResp.ClientID

	// Step 3: bootstrap the client token (identity-agnostic — same call an
	// anonymous visitor makes).
	clientTokenPayload := map[string]any{
		"client_data": map[string]any{
			"client_version": session.clientVersion,
			"client_id":      session.clientID,
			"js_sdk_data": map[string]any{
				"device_brand":   "unknown",
				"device_model":   "unknown",
				"os":             "android",
				"os_version":     "14",
				"device_id":      session.cookies["sp_t"],
				"device_type":    "smartphone",
			},
		},
	}
	payloadBytes, err := json.Marshal(clientTokenPayload)
	if err != nil {
		return nil, err
	}
	req, err = http.NewRequestWithContext(ctx, http.MethodPost, spotifyClientTokenURL, bytes.NewReader(payloadBytes))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 14) SpotiFLAC")
	resp, err = client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch client token: %w", err)
	}
	body, err = io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("client token request returned %d", resp.StatusCode)
	}
	var clientTokenResp struct {
		ResponseType string `json:"response_type"`
		GrantedToken struct {
			Token string `json:"token"`
		} `json:"granted_token"`
	}
	if err := json.Unmarshal(body, &clientTokenResp); err != nil {
		return nil, fmt.Errorf("failed to parse client token response: %w", err)
	}
	if clientTokenResp.ResponseType != "RESPONSE_GRANTED_TOKEN_RESPONSE" {
		return nil, fmt.Errorf("unexpected client token response: %s", clientTokenResp.ResponseType)
	}
	session.clientToken = clientTokenResp.GrantedToken.Token

	return session, nil
}

func mergeSpotifySetCookies(cookies map[string]string, setCookieHeaders []string) {
	for _, header := range setCookieHeaders {
		firstPair := strings.SplitN(header, ";", 2)[0]
		nameValue := strings.SplitN(firstPair, "=", 2)
		if len(nameValue) != 2 {
			continue
		}
		cookies[strings.TrimSpace(nameValue[0])] = strings.TrimSpace(nameValue[1])
	}
}

func fetchSpotifyHomeFeed(ctx context.Context, client *http.Client, session *spotifyPersonalSession) (map[string]any, error) {
	payload := map[string]any{
		"operationName": "home",
		"variables":     map[string]any{"timeZone": "UTC"},
		"extensions": map[string]any{
			"persistedQuery": map[string]any{
				"version":   1,
				"sha256Hash": spotifyHomeFeedSHA256Hash,
			},
		},
	}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, spotifyPartnerAPIURL, bytes.NewReader(payloadBytes))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+session.accessToken)
	req.Header.Set("Client-Token", session.clientToken)
	req.Header.Set("Spotify-App-Version", session.clientVersion)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 14) SpotiFLAC")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("home feed query failed: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("home feed query returned %d: %s", resp.StatusCode, string(body))
	}
	var parsed map[string]any
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("failed to parse home feed response: %w", err)
	}
	return parsed, nil
}

// getNestedSpotifyValue walks a dot-separated path through decoded JSON,
// where each segment is either a map key (e.g. "albumOfTrack") or, when the
// current value is a slice, a numeric index (e.g. the "0" in
// "sources.0.url" — JSON arrays decode to []any, so an all-map-only walker
// would silently return nil the moment a path crosses an array boundary).
func getNestedSpotifyValue(data map[string]any, path string) any {
	current := any(data)
	for _, key := range strings.Split(path, ".") {
		switch v := current.(type) {
		case map[string]any:
			current = v[key]
		case []any:
			index, err := strconv.Atoi(key)
			if err != nil || index < 0 || index >= len(v) {
				return nil
			}
			current = v[index]
		default:
			return nil
		}
	}
	return current
}

// formatSpotifyHomeFeedResponse normalizes the raw partner-API "home" query
// response into this app's ExploreSection/ExploreItem JSON shape (matching
// lib/providers/explore_provider.dart's ExploreSection.fromJson /
// ExploreItem.fromJson). Field paths mirror the bundled spotify-web
// extension's formatHomeFeedData — same public GraphQL response shape,
// independently re-derived here in Go rather than copied.
func formatSpotifyHomeFeedResponse(raw map[string]any) map[string]any {
	home, _ := getNestedSpotifyValue(raw, "data.home").(map[string]any)
	greeting, _ := getNestedSpotifyValue(home, "greeting.text").(string)

	sectionContainer, _ := home["sectionContainer"].(map[string]any)
	sectionsRaw, _ := getNestedSpotifyValue(sectionContainer, "sections.items").([]any)

	sections := make([]map[string]any, 0, len(sectionsRaw))
	for _, rawSection := range sectionsRaw {
		section, ok := rawSection.(map[string]any)
		if !ok {
			continue
		}
		sectionData, _ := section["data"].(map[string]any)
		title, _ := getNestedSpotifyValue(sectionData, "title.text").(string)
		if title == "" {
			continue
		}
		sectionURI, _ := section["uri"].(string)

		itemsRaw, _ := getNestedSpotifyValue(section, "sectionItems.items").([]any)
		items := make([]map[string]any, 0, len(itemsRaw))
		for _, rawItem := range itemsRaw {
			item, ok := formatSpotifyHomeFeedItem(rawItem)
			if ok {
				items = append(items, item)
			}
		}
		if len(items) == 0 {
			continue
		}
		sections = append(sections, map[string]any{
			"uri":   sectionURI,
			"title": title,
			"items": items,
		})
	}

	return map[string]any{
		"success":  true,
		"greeting": greeting,
		"sections": sections,
	}
}

func formatSpotifyHomeFeedItem(rawItem any) (map[string]any, bool) {
	itemMap, ok := rawItem.(map[string]any)
	if !ok {
		return nil, false
	}
	contentData, _ := getNestedSpotifyValue(itemMap, "content.data").(map[string]any)
	uri, _ := contentData["uri"].(string)
	if uri == "" {
		return nil, false
	}
	uriParts := strings.Split(uri, ":")
	if len(uriParts) < 3 {
		return nil, false
	}
	itemType := uriParts[1]
	itemID := uriParts[2]

	name, _ := contentData["name"].(string)
	if name == "" {
		name, _ = getNestedSpotifyValue(contentData, "profile.name").(string)
	}

	var coverURL, artistNames, description, albumID, albumName string
	var durationMs float64

	switch itemType {
	case "track":
		coverURL, _ = getNestedSpotifyValue(contentData, "albumOfTrack.coverArt.sources.0.url").(string)
		if d, ok := getNestedSpotifyValue(contentData, "duration.totalMilliseconds").(float64); ok {
			durationMs = d
		}
		if albumURI, ok := getNestedSpotifyValue(contentData, "albumOfTrack.uri").(string); ok {
			albumParts := strings.Split(albumURI, ":")
			if len(albumParts) >= 3 {
				albumID = albumParts[2]
			}
		}
		albumName, _ = getNestedSpotifyValue(contentData, "albumOfTrack.name").(string)
		artistNames = joinSpotifyArtistNames(getNestedSpotifyValue(contentData, "artists.items"))
	case "album":
		coverURL, _ = getNestedSpotifyValue(contentData, "coverArt.sources.0.url").(string)
		artistNames = joinSpotifyArtistNames(getNestedSpotifyValue(contentData, "artists.items"))
	case "playlist":
		coverURL, _ = getNestedSpotifyValue(contentData, "images.items.0.sources.0.url").(string)
		description, _ = contentData["description"].(string)
		artistNames, _ = getNestedSpotifyValue(contentData, "ownerV2.data.name").(string)
	case "artist":
		coverURL, _ = getNestedSpotifyValue(contentData, "visuals.avatarImage.sources.0.url").(string)
	case "station":
		coverURL, _ = getNestedSpotifyValue(contentData, "image.sources.0.url").(string)
	default:
		return nil, false
	}

	return map[string]any{
		"id":          itemID,
		"uri":         uri,
		"type":        itemType,
		"name":        name,
		"artists":     artistNames,
		"description": description,
		"cover_url":   coverURL,
		"album_id":    albumID,
		"album_name":  albumName,
		"duration_ms": int(durationMs),
		"provider_id": "spotify-personal",
	}, true
}

func joinSpotifyArtistNames(rawItems any) string {
	items, ok := rawItems.([]any)
	if !ok {
		return ""
	}
	names := make([]string, 0, len(items))
	for _, rawItem := range items {
		itemMap, ok := rawItem.(map[string]any)
		if !ok {
			continue
		}
		if name, ok := getNestedSpotifyValue(itemMap, "profile.name").(string); ok && name != "" {
			names = append(names, name)
		}
	}
	return strings.Join(names, ", ")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd go_backend && go test ./... -run TestFormatSpotifyHomeFeedResponse -v`
Expected: PASS

- [ ] **Step 5: Implement the gomobile export**

```go
// go_backend/exports_spotify_personal.go
package gobackend

import (
	"context"
	"net/http"
	"time"
)

// GetSpotifyPersonalHomeFeed fetches the real, logged-in-user personalized
// Spotify home feed using a session cookie captured by the app's WebView
// login screen (see spotify_web_login_screen.dart). Returns a JSON string
// shaped like the existing extension home-feed contract
// ({"success","error","greeting","sections"}) so it plugs into the exact
// same Dart-side parsing explore_provider.dart already has for extension
// home feeds.
func GetSpotifyPersonalHomeFeed(sessionCookie string) (string, error) {
	if sessionCookie == "" {
		return marshalJSONString(map[string]any{
			"success": false,
			"error":   "no Spotify session cookie available; please log in again",
		})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	client := &http.Client{Timeout: 20 * time.Second}
	session, err := bootstrapSpotifyPersonalSession(ctx, client, sessionCookie)
	if err != nil {
		return marshalJSONString(map[string]any{
			"success": false,
			"error":   err.Error(),
		})
	}

	raw, err := fetchSpotifyHomeFeed(ctx, client, session)
	if err != nil {
		return marshalJSONString(map[string]any{
			"success": false,
			"error":   err.Error(),
		})
	}

	return marshalJSONString(formatSpotifyHomeFeedResponse(raw))
}
```

- [ ] **Step 6: Run the full Go test suite**

Run: `cd go_backend && go test ./...`
Expected: PASS, no regressions.

- [ ] **Step 7: Manual verification**

This step needs the real gomobile rebuild + a captured session cookie from Task 6, so defer full manual verification to Task 8 (once the Dart side can call this end-to-end). At minimum here, confirm `go build ./...` succeeds.

- [ ] **Step 8: Commit**

```bash
git add go_backend/spotify_personal.go go_backend/exports_spotify_personal.go go_backend/spotify_personal_test.go
git commit -m "feat(spotify): add Go backend for personalized home feed from a real session"
```

---

### Task 8: Wire the personalized feed into the Home tab

**Files:**
- Modify: `lib/services/platform_bridge.dart` (add a bridge method)
- Modify: `lib/providers/explore_provider.dart` (recognize the new pseudo-provider)
- Modify: `lib/screens/settings/extensions_page.dart` (add a picker entry; read this file's `_showHomeFeedProviderPicker` — already read during planning, lines ~911-1005 — before editing so the new entry matches its existing `ListTile` pattern exactly)

**Interfaces:**
- Consumes: `GetSpotifyPersonalHomeFeed` (Task 7), `spotifySessionCookieStorageKey` (Task 6).
- Produces: `PlatformBridge.getSpotifyPersonalHomeFeed()`; `AppSettings.homeFeedProviderSpotifyPersonal` sentinel constant (mirrors the existing `homeFeedProviderOff` pattern in `lib/models/settings.dart:8`); `ExploreNotifier.fetchHomeFeed()` now special-cases this sentinel before falling through to extension resolution.

- [ ] **Step 1: Add the `PlatformBridge` method**

```dart
// lib/services/platform_bridge.dart — add near getExtensionHomeFeed
  static Future<Map<String, dynamic>?> getSpotifyPersonalHomeFeed(
    String sessionCookie,
  ) async {
    try {
      final result = await _channel.invokeMethod('getSpotifyPersonalHomeFeed', {
        'session_cookie': sessionCookie,
      });
      return _decodeNullableMapResult(result, 'getSpotifyPersonalHomeFeed');
    } catch (e) {
      _log.e('getSpotifyPersonalHomeFeed failed: $e');
      return null;
    }
  }
```

Read `_decodeNullableMapResult`'s existing definition first (used by `getExtensionHomeFeed` a few lines above) to confirm the exact helper name/signature before reusing it; if the native Android method-channel handler for `getSpotifyPersonalHomeFeed` does not exist yet, add a case to the same Kotlin method-channel dispatcher that already routes `getExtensionHomeFeed`/`getRepoExtensions` to their gomobile calls, calling `Gobackend.getSpotifyPersonalHomeFeed(sessionCookie)` (the function Task 7 exports) — mirror whatever pattern that dispatcher already uses for a single-string-arg, single-string-return gomobile call.

- [ ] **Step 2: Add the settings sentinel**

```dart
// lib/models/settings.dart — alongside homeFeedProviderOff (line 8)
  static const String homeFeedProviderSpotifyPersonal = '__spotify_personal__';
```

- [ ] **Step 3: Wire `ExploreNotifier` to use it**

```dart
// lib/providers/explore_provider.dart — add imports
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:spotiflac_android/screens/spotify/spotify_web_login_screen.dart'
    show spotifySessionCookieStorageKey;
```

Modify `fetchHomeFeed` — insert this branch immediately after the existing `homeFeedProviderOff` early-return and before `_resolveHomeFeedExtension()` is called:

```dart
// lib/providers/explore_provider.dart — inside fetchHomeFeed, after the
// homeFeedProviderOff check and before the existing extension-resolution path
    if (ref.read(settingsProvider).homeFeedProvider ==
        AppSettings.homeFeedProviderSpotifyPersonal) {
      await _fetchSpotifyPersonalHomeFeed(forceRefresh: forceRefresh);
      return;
    }
```

Add the new method:

```dart
// lib/providers/explore_provider.dart — inside ExploreNotifier
  Future<void> _fetchSpotifyPersonalHomeFeed({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        state.hasContent &&
        state.lastFetched != null &&
        DateTime.now().difference(state.lastFetched!).inMinutes < 5) {
      return;
    }

    final requestId = ++_homeFeedRequestId;
    state = state.copyWith(isLoading: !state.hasContent, error: null);

    final cookie = await const FlutterSecureStorage().read(
      key: spotifySessionCookieStorageKey,
    );
    if (cookie == null || cookie.isEmpty) {
      if (requestId != _homeFeedRequestId) return;
      state = state.copyWith(
        isLoading: false,
        error: 'Log in to Spotify to see your personalized feed',
      );
      return;
    }

    try {
      final result = await PlatformBridge.getSpotifyPersonalHomeFeed(cookie);
      if (requestId != _homeFeedRequestId) return;

      if (result == null || result['success'] != true) {
        state = state.copyWith(
          isLoading: false,
          error: result?['error'] as String? ?? 'Failed to fetch personalized home feed',
        );
        return;
      }

      final greeting = result['greeting'] as String?;
      final sectionsData = result['sections'] as List<dynamic>? ?? [];
      final normalizedSections = await compute(
        _normalizeExploreSectionsPayload,
        sectionsData,
      );
      if (requestId != _homeFeedRequestId) return;
      final sections = _buildExploreSectionsFromNormalizedPayload(normalizedSections);

      state = ExploreState(
        isLoading: false,
        greeting: greeting ?? _getLocalGreeting(),
        providerId: AppSettings.homeFeedProviderSpotifyPersonal,
        sections: sections,
        lastFetched: DateTime.now(),
      );
      _saveToCache(normalizedSections, AppSettings.homeFeedProviderSpotifyPersonal);
    } catch (e) {
      _log.e('Error fetching personalized Spotify home feed: $e');
      if (requestId != _homeFeedRequestId) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }
```

- [ ] **Step 4: Add the picker entry**

In `lib/screens/settings/extensions_page.dart`'s `_showHomeFeedProviderPicker`, add a `ListTile` alongside the existing "Auto"/"Off"/per-extension entries (matching their exact structure — leading icon, title, subtitle, `trailing` check-icon-if-selected, `onTap` calling `setHomeFeedProvider` + `refresh`/`clear` + `Navigator.pop`):

```dart
// lib/screens/settings/extensions_page.dart — inside the picker's bottom
// sheet children, after the "Off" ListTile and before the
// ...homeFeedProviders.map(...) extension entries
              ListTile(
                leading: Icon(Icons.podcasts, color: colorScheme.secondary),
                title: const Text('Your Spotify (personalized)'),
                subtitle: const Text('Your real Spotify home feed'),
                trailing:
                    settings.homeFeedProvider ==
                        AppSettings.homeFeedProviderSpotifyPersonal
                    ? Icon(Icons.check_circle, color: colorScheme.primary)
                    : Icon(Icons.circle_outlined, color: colorScheme.outline),
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setHomeFeedProvider(AppSettings.homeFeedProviderSpotifyPersonal);
                  ref.read(exploreProvider.notifier).refresh();
                  Navigator.pop(ctx);
                },
              ),
```

If no session cookie has been captured yet (Task 6 never run), tapping this leads to the "Log in to Spotify to see your personalized feed" error state from Step 3 — add a nearby entry point to push `SpotifyWebLoginScreen` (e.g. an `onTap` on this same tile when no cookie exists yet, checked via a `FutureBuilder`/pre-fetched flag reading `spotifySessionCookieStorageKey`, pushing `SpotifyWebLoginScreen` first and calling `refresh()` after it pops `true`) — read the surrounding widget's state-loading conventions in this same file before wiring this in, so it matches how the file already handles other async pre-checks.

- [ ] **Step 5: Manual verification**

Log into a real Spotify account via the WebView screen (Task 6), select "Your Spotify (personalized)" as the home feed provider, and confirm the Home tab shows real personalized sections (e.g. "Made For You", "Jump back in") matching what the account sees on open.spotify.com — not the generic anonymous feed the `spotify-web` extension shows.

- [ ] **Step 6: Commit**

```bash
git add lib/services/platform_bridge.dart lib/providers/explore_provider.dart lib/models/settings.dart lib/screens/settings/extensions_page.dart
git commit -m "feat(spotify): surface a personalized Home feed from a real logged-in session"
```

---

### Task 9: Relocate the Spotify library entry point into the Library tab

**Files:**
- Modify: `lib/screens/main_shell.dart` (`_LibraryTabRoot`)
- Modify: `lib/screens/settings/settings_tab.dart` (remove the Task 6-of-Phase-1 "Spotify Account" entry — read this file first to find the exact tile added during Phase 1's Task 6 before removing it)
- Modify: `lib/screens/queue_tab.dart` (add an entry point into the Spotify login/library screens — read this file's existing top-level structure first, matching whatever list/section pattern it already uses for the local library)

**Interfaces:**
- Consumes: `SpotifyLoginScreen` (existing, Phase 1), `spotifyAuthProvider` (existing).
- Produces: no new types — this is a navigation/entry-point move.

- [ ] **Step 1: Remove the Settings entry point**

Read `lib/screens/settings/settings_tab.dart` and find the "Spotify Account" tile added by Phase 1's Task 6 (navigates to `/spotify`). Delete that tile entirely — Settings should no longer be where a user finds their Spotify account.

- [ ] **Step 2: Add the Library tab entry point**

Read `lib/screens/queue_tab.dart`'s top-level structure (it's rendered as `QueueTab` inside `_LibraryTabRoot` in `main_shell.dart:970-986`). Add a persistent entry — matching whatever this file's existing section/header pattern is (e.g. a leading list item or a small header row above the local-library list) — that:

- Watches `spotifyAuthProvider`.
- When `SpotifyAuthStatus.loggedIn`, shows something like "Your Spotify" leading to `SpotifyLibraryScreen` (push via the existing `Navigator`/`go_router` convention this file already uses for other pushes).
- When not logged in, shows "Connect Spotify" leading to `SpotifyLoginScreen`.

Do not remove the `/spotify` route from `lib/app.dart` — `SpotifyLoginScreen` is still reachable, just from a new place; leave its own internal "Browse your library" button (pushing `SpotifyLibraryScreen`) as-is, since a user can still land on the login screen this way if they weren't logged in.

- [ ] **Step 3: Manual verification**

Open the app: confirm there is no "Spotify Account" entry left under Settings. Open the Library tab: confirm a "Connect Spotify" (logged out) or "Your Spotify" (logged in) entry is visible alongside the local library content, and tapping it reaches the same login/library screens Phase 1 built.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/main_shell.dart lib/screens/settings/settings_tab.dart lib/screens/queue_tab.dart
git commit -m "feat(spotify): move the Spotify account entry point from Settings to Library"
```

---

### Task 10: Fast streaming quality default

**Files:**
- Modify: `lib/providers/spotify_stream_player_provider.dart`
- Test: `test/spotify_stream_quality_test.dart` (new)

**Interfaces:**
- Consumes: nothing new.
- Produces: `const String spotifyStreamQuality` (a named constant replacing the inline `'LOSSLESS'` literal) — set to `'HIGH'`. This app's quality vocabulary is `'HIGH'` / `'LOSSLESS'` / `'HI_RES_LOSSLESS'` (confirmed via `lib/screens/settings/download_settings_page.dart:339-358`, which switches on exactly these three id strings for icons/labels) — `'HIGH'` is the fast/lossy tier, the other two are both full-quality FLAC tiers.

- [ ] **Step 1: Write the failing test**

```dart
// test/spotify_stream_quality_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/spotify_stream_player_provider.dart';

void main() {
  test('streaming defaults to a fast, non-lossless quality tier', () {
    expect(spotifyStreamQuality, isNot('LOSSLESS'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/spotify_stream_quality_test.dart`
Expected: FAIL — `spotifyStreamQuality` does not exist yet (the value is still an inline `'LOSSLESS'` literal).

- [ ] **Step 3: Implement**

```dart
// lib/providers/spotify_stream_player_provider.dart — add near the top-level
// constants (streamCacheFileName etc.)
/// Streaming plays back as soon as a track resolves, so it defaults to a
/// fast/lossy tier rather than Download's full-LOSSLESS tier — "stream" means
/// fast-start here, not archival quality. Use the app's existing explicit
/// "Download" action (unchanged, still LOSSLESS-capable) for full quality.
const spotifyStreamQuality = 'HIGH';
```

Replace the payload's `quality: 'LOSSLESS'` with `quality: spotifyStreamQuality`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/spotify_stream_quality_test.dart`
Expected: PASS

- [ ] **Step 5: Manual verification**

Stream a track from the Spotify library and confirm it starts playing noticeably faster than before (a few seconds, not the time a full FLAC download used to take).

- [ ] **Step 6: Commit**

```bash
git add lib/providers/spotify_stream_player_provider.dart test/spotify_stream_quality_test.dart
git commit -m "fix(spotify): default streaming to a fast quality tier instead of LOSSLESS"
```

---

### Task 11: Route Spotify streaming through the existing player

**Files:**
- Modify: `lib/providers/spotify_stream_player_provider.dart`

**Interfaces:**
- Consumes: `PlayableMedia`, `musicPlayerControllerProvider` (`lib/providers/music_player_provider.dart`, existing).
- Produces: `SpotifyStreamPlayerNotifier` no longer owns a second `AudioPlayer`; `streamTrack` now hands off to `musicPlayerControllerProvider.playSingle(...)` once a file resolves. `StreamPlaybackState`/`StreamPlaybackStatus` are unchanged in shape (still `idle`/`resolving`/`buffering`/`playing`/`paused`/`error`) so `spotify_library_screen.dart`/`spotify_playlist_detail_screen.dart` need **no changes** — they only read the resolving/buffering/error fields, which this task preserves exactly. `pause()`/`resume()`/`stop()` on this notifier are removed; any future caller needing playback controls uses `musicPlayerControllerProvider` directly, matching every other part of the app.

**Do this task after Task 10** (both touch the same file; Task 10's quality-constant change is small and independent, Task 11 is the larger rewrite).

- [ ] **Step 1: Write the failing test for the pure request-generation guard**

```dart
// test/spotify_stream_player_provider_test.dart — add this group to the
// existing file (read it first — it already has tests for
// isDuplicateStreamRequest and streamCacheFileName; add alongside them,
// don't replace them)
  group('isStaleStreamRequest', () {
    test('a request is stale once a newer generation has started', () {
      expect(isStaleStreamRequest(currentGeneration: 2, requestGeneration: 1), isTrue);
    });

    test('the current generation is not stale', () {
      expect(isStaleStreamRequest(currentGeneration: 2, requestGeneration: 2), isFalse);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/spotify_stream_player_provider_test.dart`
Expected: FAIL — `isStaleStreamRequest` does not exist (the rest of the existing file's tests still pass).

- [ ] **Step 3: Rewrite `SpotifyStreamPlayerNotifier`**

Replace the whole file's notifier body (keep `streamCacheFileName`, `isDuplicateStreamRequest`, `StreamPlaybackStatus`, `StreamPlaybackState` as they are):

```dart
// lib/providers/spotify_stream_player_provider.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/download_request_payload.dart';
import 'package:spotiflac_android/services/music_player_service.dart' show PlayableMedia;
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyStreamPlayer');

const spotifyStreamQuality = 'HIGH';

String streamCacheFileName(String trackId) {
  final sanitized = trackId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
  return 'stream_$sanitized';
}

bool isDuplicateStreamRequest(String? inFlightTrackId, String requestedTrackId) {
  return inFlightTrackId != null && inFlightTrackId == requestedTrackId;
}

/// True when [requestGeneration] is no longer the latest request —
/// [SpotifyStreamPlayerNotifier] increments a counter on every `streamTrack`
/// call; a resolution completing under an older generation means a newer tap
/// has already superseded it and must not hand its result off to the player.
bool isStaleStreamRequest({
  required int currentGeneration,
  required int requestGeneration,
}) {
  return requestGeneration != currentGeneration;
}

enum StreamPlaybackStatus { idle, resolving, buffering, playing, paused, error }

class StreamPlaybackState {
  final Track? currentTrack;
  final StreamPlaybackStatus status;
  final String? error;

  const StreamPlaybackState({
    this.currentTrack,
    this.status = StreamPlaybackStatus.idle,
    this.error,
  });

  StreamPlaybackState copyWith({
    Track? currentTrack,
    bool clearTrack = false,
    StreamPlaybackStatus? status,
    String? error,
    bool clearError = false,
  }) {
    return StreamPlaybackState(
      currentTrack: clearTrack ? null : (currentTrack ?? this.currentTrack),
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SpotifyStreamPlayerNotifier extends Notifier<StreamPlaybackState> {
  int _requestGeneration = 0;

  @override
  StreamPlaybackState build() => const StreamPlaybackState();

  Future<Directory> _cacheDir() async {
    final tempDir = await getTemporaryDirectory();
    final streamDir = Directory('${tempDir.path}/spotify_stream_cache');
    if (!await streamDir.exists()) {
      await streamDir.create(recursive: true);
    }
    return streamDir;
  }

  /// Deletes any file in the cache dir whose name is exactly the
  /// deterministic prefix for [trackId], or that prefix followed by a `.ext`
  /// suffix — not an unguarded startsWith, which could match a different
  /// track id that happens to be a literal prefix of this one.
  Future<void> _cleanupStaleFilesForTrack(String trackId) async {
    try {
      final dir = await _cacheDir();
      final prefix = streamCacheFileName(trackId);
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final segments = entity.uri.pathSegments;
        final name = segments.isNotEmpty ? segments.last : entity.path;
        if (name == prefix || name.startsWith('$prefix.')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> streamTrack(Track track) async {
    final generation = ++_requestGeneration;

    await _cleanupStaleFilesForTrack(track.id);

    state = StreamPlaybackState(
      currentTrack: track,
      status: StreamPlaybackStatus.resolving,
    );

    final settings = ref.read(settingsProvider);
    final extensionState = ref.read(extensionProvider);
    final hasActiveExtensions = extensionState.extensions.any((e) => e.enabled);
    final useExtensions = settings.useExtensionProviders && hasActiveExtensions;
    final useFallback = settings.autoFallback;

    if (!useExtensions) {
      if (isStaleStreamRequest(currentGeneration: _requestGeneration, requestGeneration: generation)) {
        return;
      }
      state = state.copyWith(
        status: StreamPlaybackStatus.error,
        error:
            'Streaming requires at least one enabled extension provider. '
            'Enable one in Settings > Extensions to stream tracks.',
      );
      return;
    }

    final dir = await _cacheDir();
    state = state.copyWith(status: StreamPlaybackStatus.buffering);

    try {
      final response = await PlatformBridge.downloadByStrategy(
        payload: DownloadRequestPayload(
          isrc: track.isrc ?? '',
          service: '',
          spotifyId: track.id,
          trackName: track.name,
          artistName: track.artistName,
          albumName: track.albumName,
          albumArtist: track.albumArtist ?? '',
          coverUrl: track.coverUrl ?? '',
          outputDir: dir.path,
          filenameFormat: streamCacheFileName(track.id),
          quality: spotifyStreamQuality,
          embedMetadata: false,
          embedLyrics: false,
          embedMaxQualityCover: false,
          trackNumber: track.trackNumber ?? 0,
          discNumber: track.discNumber ?? 0,
          totalTracks: track.totalTracks ?? 1,
          releaseDate: track.releaseDate ?? '',
          itemId: track.id,
          durationMs: track.duration * 1000,
          source: '',
        ),
        useExtensions: useExtensions,
        useFallback: useFallback,
      );

      if (isStaleStreamRequest(currentGeneration: _requestGeneration, requestGeneration: generation)) {
        // A newer tap superseded this one while it was resolving; drop the
        // result instead of handing a stale file off to the player.
        final filePath = response['file_path'] as String?;
        if (filePath != null && filePath.isNotEmpty) {
          unawaited(_deleteFile(filePath));
        }
        return;
      }

      if (response['success'] != true) {
        throw Exception(response['error'] ?? 'Resolution failed');
      }

      final filePath = response['file_path'] as String?;
      if (filePath == null || filePath.isEmpty) {
        throw Exception('Download succeeded but returned no file_path');
      }

      state = state.copyWith(status: StreamPlaybackStatus.playing);
      await ref.read(musicPlayerControllerProvider).playSingle(
        PlayableMedia(
          id: 'spotify-stream-${track.id}',
          source: filePath,
          title: track.name,
          artist: track.artistName,
          album: track.albumName,
          artUri: track.coverUrl,
          duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
        ),
      );
    } catch (e) {
      if (isStaleStreamRequest(currentGeneration: _requestGeneration, requestGeneration: generation)) {
        return;
      }
      _log.e('Stream resolution failed for "${track.name}"', e);
      await _cleanupStaleFilesForTrack(track.id);
      state = state.copyWith(status: StreamPlaybackStatus.error, error: '$e');
    }
  }

  Future<void> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

final spotifyStreamPlayerProvider =
    NotifierProvider<SpotifyStreamPlayerNotifier, StreamPlaybackState>(
      SpotifyStreamPlayerNotifier.new,
    );
```

This removes the bespoke `AudioPlayer`, its `_attachListeners`/`_playFile`/`pause`/`resume`/`stop`/`_discardPlayer` methods, and the `registerExclusiveAudioHook`/`unregisterExclusiveAudioHook`/`stopOtherExclusiveAudio` plumbing entirely — with only one player left (`musicPlayerHandler`), there is no second audio engine to keep mutually exclusive with anything. `music_player_service.dart`'s exclusive-audio-hook registry stays in the codebase (the local preview player still uses it against the main library player), it is just no longer imported here.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/spotify_stream_player_provider_test.dart`
Expected: PASS (all existing tests in this file, plus the 2 new `isStaleStreamRequest` tests)

- [ ] **Step 5: Run the full test suite and static analysis**

Run: `flutter test && flutter analyze`
Expected: PASS, no regressions, no analyzer warnings (a prior Phase-1 final review specifically caught `flutter analyze` failures that `flutter test` alone missed).

- [ ] **Step 6: Manual verification**

Stream a track from the Spotify Library tab and confirm: the mini-player appears at the bottom immediately once playback starts; tapping it opens the full-screen Now Playing view via the existing Hero transition; the Lyrics tab and reorderable queue are present (even if empty/single-item for this track); lock-screen/notification controls show the track and respond to play/pause/skip. Then rapid-tap two different tracks in a row and confirm only the second one ends up playing (no audio overlap, no stale mini-player content). Finally, spot-check `spotify_library_screen.dart` and `spotify_playlist_detail_screen.dart` need zero code changes — their resolving/buffering spinners and error snackbars should keep working unmodified.

- [ ] **Step 7: Commit**

```bash
git add lib/providers/spotify_stream_player_provider.dart test/spotify_stream_player_provider_test.dart
git commit -m "feat(spotify): route streamed playback through the existing music player"
```

---

## Post-plan note

Phase 1's originally-scoped hotfix "dropped deep link on background resume" (an `onNewIntent` override in `MainActivity.kt`) was found, during this plan's research, to already exist in the merged code (`MainActivity.kt:2056-2060` already overrides `onNewIntent` and routes it through `handleExtensionOAuthIntent`, same as `onCreate`). No task above touches it — it needs no further work.
