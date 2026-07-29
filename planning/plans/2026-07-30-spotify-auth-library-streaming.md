# Spotify Auth + Library Sync + Streaming (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user log into their real Spotify account (OAuth PKCE, external browser + deep link — not a Flutter WebView widget), browse their real playlists/liked songs/followed artists/albums, and tap a track to have it stream (auto-resolve + auto-play, no manual "Download" tap required) via the app's existing multi-source extension pipeline.

**Architecture:** New, isolated feature slice under `lib/services/spotify_*`, `lib/models/spotify_*`, `lib/providers/spotify_*`, `lib/screens/spotify/*`. Zero changes to the Go backend or the extension contract — auth is pure Dart (PKCE, `http`, `flutter_secure_storage`) plus a small new native deep-link branch to catch the OAuth redirect; streaming reuses the existing `PlatformBridge.downloadByStrategy` call unchanged, pointed at a temp cache dir instead of the permanent library folder, then autoplays the resulting local file.

**Tech Stack:** Flutter/Dart, `flutter_riverpod` 3.3.2 (manual `Notifier`/`NotifierProvider`, no codegen), `http` (already a dependency), `flutter_secure_storage` (already a dependency), `url_launcher` (already a dependency), `audioplayers` (already a dependency, `DeviceFileSource`), `json_annotation`/`json_serializable` (already dependencies), Kotlin (Android native, `MainActivity.kt`).

## Global Constraints

- No new Flutter package dependencies. `webview_flutter` is deliberately NOT added — Spotify OAuth uses external-browser + custom-URI-scheme redirect (`url_launcher` + a native intent-filter), matching this codebase's existing extension-auth pattern (`lib/utils/extension_auth_launcher.dart`) and avoiding the credential-phishing concerns Spotify itself warns against for in-app WebView login.
- No client secret is ever stored on-device (PKCE flow only — `code_verifier`/`code_challenge`, no `client_secret`). `settings_provider.dart:18`'s retired `_spotifyClientSecretKey` is the cautionary precedent — do not repeat it.
- All new Riverpod state follows the house pattern exactly: immutable state class with `copyWith`, `class XNotifier extends Notifier<XState>`, `build()` does light sync init only (heavier init via `Future.microtask`), singleton services for I/O, final `NotifierProvider` declared at file end. No `@riverpod` codegen.
- Go backend (`go_backend/`) and the extension contract (`DownloadRequest`/`DownloadResponse`) are unmodified in this plan.
- Android only — no iOS changes.
- Redirect URI host is **`spotiflac://spotify-login-callback`** — a new, distinct host from the existing `spotiflac://spotify-callback` (which is already wired in `MainActivity.kt` to the extension-runtime auth system and must not be repurposed, since it always treats `state` as an extension ID).
- Scopes requested: `playlist-read-private playlist-read-collaborative user-library-read user-follow-read user-read-email`.

---

### Task 1: PKCE helper (pure, testable)

**Files:**
- Create: `lib/services/spotify_pkce.dart`
- Test: `test/spotify_pkce_test.dart`

**Interfaces:**
- Produces: `class SpotifyPkcePair { final String verifier; final String challenge; }`, `SpotifyPkcePair generateSpotifyPkcePair({math.Random? random})`, `String buildSpotifyAuthorizeUrl({required String clientId, required String redirectUri, required String codeChallenge, required List<String> scopes, required String state})`.

- [ ] **Step 1: Write the failing tests**

```dart
// test/spotify_pkce_test.dart
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/spotify_pkce.dart';

void main() {
  group('generateSpotifyPkcePair', () {
    test('verifier is 43-128 chars of the unreserved PKCE charset', () {
      final pair = generateSpotifyPkcePair(random: Random(1));
      expect(pair.verifier.length, inInclusiveRange(43, 128));
      expect(
        RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(pair.verifier),
        isTrue,
      );
    });

    test('challenge is the base64url(SHA256(verifier)) with no padding', () {
      final pair = generateSpotifyPkcePair(random: Random(1));
      expect(pair.challenge, isNot(contains('=')));
      expect(pair.challenge, isNot(contains('+')));
      expect(pair.challenge, isNot(contains('/')));
    });

    test('two calls produce different verifiers', () {
      final a = generateSpotifyPkcePair(random: Random(1));
      final b = generateSpotifyPkcePair(random: Random(2));
      expect(a.verifier, isNot(equals(b.verifier)));
    });
  });

  group('buildSpotifyAuthorizeUrl', () {
    test('builds a correctly-shaped authorize URL', () {
      final uri = Uri.parse(
        buildSpotifyAuthorizeUrl(
          clientId: 'abc123',
          redirectUri: 'spotiflac://spotify-login-callback',
          codeChallenge: 'challenge-value',
          scopes: const ['user-library-read', 'playlist-read-private'],
          state: 'xyz',
        ),
      );

      expect(uri.scheme, 'https');
      expect(uri.host, 'accounts.spotify.com');
      expect(uri.path, '/authorize');
      expect(uri.queryParameters['client_id'], 'abc123');
      expect(uri.queryParameters['response_type'], 'code');
      expect(
        uri.queryParameters['redirect_uri'],
        'spotiflac://spotify-login-callback',
      );
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      expect(uri.queryParameters['code_challenge'], 'challenge-value');
      expect(
        uri.queryParameters['scope'],
        'user-library-read playlist-read-private',
      );
      expect(uri.queryParameters['state'], 'xyz');
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/spotify_pkce_test.dart`
Expected: FAIL — `spotify_pkce.dart` does not exist yet (import error).

- [ ] **Step 3: Implement**

```dart
// lib/services/spotify_pkce.dart
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

const _pkceCharset =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

class SpotifyPkcePair {
  final String verifier;
  final String challenge;

  const SpotifyPkcePair({required this.verifier, required this.challenge});
}

SpotifyPkcePair generateSpotifyPkcePair({Random? random}) {
  final rng = random ?? Random.secure();
  final verifier = List.generate(
    96,
    (_) => _pkceCharset[rng.nextInt(_pkceCharset.length)],
  ).join();
  final challenge = base64Url
      .encode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');
  return SpotifyPkcePair(verifier: verifier, challenge: challenge);
}

String buildSpotifyAuthorizeUrl({
  required String clientId,
  required String redirectUri,
  required String codeChallenge,
  required List<String> scopes,
  required String state,
}) {
  final uri = Uri.https('accounts.spotify.com', '/authorize', {
    'client_id': clientId,
    'response_type': 'code',
    'redirect_uri': redirectUri,
    'code_challenge_method': 'S256',
    'code_challenge': codeChallenge,
    'scope': scopes.join(' '),
    'state': state,
  });
  return uri.toString();
}
```

Note: `package:crypto` is not currently in `pubspec.yaml` — add it:

```bash
flutter pub add crypto
```

This is the one new dependency in this plan; it's a small, dependency-free (besides `typed_data`), widely-used primitive (SHA-256), not a UI/OAuth-flow library like `webview_flutter` would have been.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/spotify_pkce_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/services/spotify_pkce.dart test/spotify_pkce_test.dart
git commit -m "feat(spotify): add PKCE pair generation and authorize URL builder"
```

---

### Task 2: Token model with expiry logic (pure, testable)

**Files:**
- Create: `lib/models/spotify_auth_tokens.dart`
- Test: `test/spotify_auth_tokens_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: `class SpotifyAuthTokens { final String accessToken; final String? refreshToken; final DateTime expiresAt; bool get isExpired; bool needsRefresh; Map<String,dynamic> toStorageJson(); factory SpotifyAuthTokens.fromStorageJson(Map<String,dynamic>); factory SpotifyAuthTokens.fromTokenResponse(Map<String,dynamic> json, {required DateTime now}); }`

- [ ] **Step 1: Write the failing tests**

```dart
// test/spotify_auth_tokens_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/spotify_auth_tokens.dart';

void main() {
  group('SpotifyAuthTokens.fromTokenResponse', () {
    test('parses a token endpoint response', () {
      final now = DateTime.utc(2026, 7, 30, 12, 0, 0);
      final tokens = SpotifyAuthTokens.fromTokenResponse({
        'access_token': 'access-1',
        'refresh_token': 'refresh-1',
        'expires_in': 3600,
        'token_type': 'Bearer',
      }, now: now);

      expect(tokens.accessToken, 'access-1');
      expect(tokens.refreshToken, 'refresh-1');
      expect(tokens.expiresAt, now.add(const Duration(seconds: 3600)));
    });

    test('a refresh response with no refresh_token keeps the old one', () {
      final now = DateTime.utc(2026, 7, 30, 12, 0, 0);
      final tokens = SpotifyAuthTokens.fromTokenResponse(
        {'access_token': 'access-2', 'expires_in': 3600},
        now: now,
        previousRefreshToken: 'refresh-1',
      );
      expect(tokens.refreshToken, 'refresh-1');
    });
  });

  group('expiry', () {
    test('isExpired is true once past expiresAt', () {
      final tokens = SpotifyAuthTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.utc(2026, 1, 1),
      );
      expect(tokens.isExpiredAt(DateTime.utc(2026, 1, 2)), isTrue);
      expect(tokens.isExpiredAt(DateTime.utc(2025, 12, 31)), isFalse);
    });

    test('needsRefresh is true within 60s of expiry, not just after', () {
      final tokens = SpotifyAuthTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.utc(2026, 1, 1, 0, 1, 0),
      );
      expect(
        tokens.needsRefreshAt(DateTime.utc(2026, 1, 1, 0, 0, 30)),
        isTrue,
      );
      expect(
        tokens.needsRefreshAt(DateTime.utc(2026, 1, 1, 0, 0, 0)),
        isFalse,
      );
    });
  });

  group('storage round-trip', () {
    test('toStorageJson/fromStorageJson round-trips', () {
      final tokens = SpotifyAuthTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.utc(2026, 1, 1),
      );
      final restored = SpotifyAuthTokens.fromStorageJson(
        tokens.toStorageJson(),
      );
      expect(restored.accessToken, tokens.accessToken);
      expect(restored.refreshToken, tokens.refreshToken);
      expect(restored.expiresAt, tokens.expiresAt);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/spotify_auth_tokens_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement**

```dart
// lib/models/spotify_auth_tokens.dart
class SpotifyAuthTokens {
  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  const SpotifyAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  bool get isExpired => isExpiredAt(DateTime.now());
  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  bool get needsRefresh => needsRefreshAt(DateTime.now());
  bool needsRefreshAt(DateTime now) =>
      !now.isBefore(expiresAt.subtract(const Duration(seconds: 60)));

  factory SpotifyAuthTokens.fromTokenResponse(
    Map<String, dynamic> json, {
    required DateTime now,
    String? previousRefreshToken,
  }) {
    final expiresInSeconds = (json['expires_in'] as num?)?.toInt() ?? 3600;
    return SpotifyAuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken:
          (json['refresh_token'] as String?) ?? previousRefreshToken,
      expiresAt: now.add(Duration(seconds: expiresInSeconds)),
    );
  }

  factory SpotifyAuthTokens.fromStorageJson(Map<String, dynamic> json) {
    return SpotifyAuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
  }

  Map<String, dynamic> toStorageJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.toIso8601String(),
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/spotify_auth_tokens_test.dart`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/models/spotify_auth_tokens.dart test/spotify_auth_tokens_test.dart
git commit -m "feat(spotify): add SpotifyAuthTokens model with expiry/refresh logic"
```

---

### Task 3: Native deep-link plumbing for the OAuth redirect

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml` (near line 101-106, alongside the existing `spotify-callback`/`session-grant` intent-filters)
- Modify: `android/app/src/main/kotlin/com/zarz/spotiflac/MainActivity.kt` (`handleExtensionOAuthIntent`, lines 2065-2110, and the method channel handler block around line 3410)

**Interfaces:**
- Produces: a new MethodChannel call from native→Dart: `com.zarz.spotiflac/backend` channel, method `spotifyLoginCallback`, arguments `{'code': String?, 'state': String?, 'error': String?}`.

- [ ] **Step 1: Add the new intent-filter**

In `android/app/src/main/AndroidManifest.xml`, immediately after the existing `spotify-callback` intent-filter block (ends at line 106):

```xml
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="spotiflac" android:host="spotify-login-callback" />
            </intent-filter>
```

- [ ] **Step 2: Branch the native intent handler before the existing extension routing**

In `MainActivity.kt`, `handleExtensionOAuthIntent` (starts line 2065). Add a new early-return branch checking for the new host *before* the existing `isCallback`/`extId` logic runs, so it never falls into the extension-routed path:

```kotlin
    private fun handleExtensionOAuthIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (!uri.scheme.equals("spotiflac", ignoreCase = true)) {
            return
        }
        val host = (uri.host ?: "").lowercase(Locale.US)

        if (host == "spotify-login-callback") {
            val code = uri.getQueryParameter("code")
            val state = uri.getQueryParameter("state")
            val error = uri.getQueryParameter("error")
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, "com.zarz.spotiflac/backend").invokeMethod(
                    "spotifyLoginCallback",
                    mapOf("code" to code, "state" to state, "error" to error),
                )
            }
            return
        }

        // ... existing isSessionGrant / isCallback / extId logic unchanged below
```

Note: `flutterEngine` must be accessible here — confirm the existing class already exposes it as a field (it does, since `AudioServicePlugin.getFlutterEngine(this)` is called in `onCreate` at line 2028 and the class is a `FlutterActivity` subclass, which exposes `flutterEngine` after `configureFlutterEngine`). If `handleExtensionOAuthIntent` runs before the engine is attached (cold start), the call is a no-op — this is fine, because `onCreate` calls `handleExtensionOAuthIntent(intent)` *after* `super.onCreate(savedInstanceState)`, which is where `FlutterActivity` attaches the engine.

- [ ] **Step 3: Manual verification**

Build and install a debug APK, then from a shell trigger the intent directly (simulates the OS handing back control after the user completes login in the browser):

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -W -a android.intent.action.VIEW \
  -d "spotiflac://spotify-login-callback?code=test-code-123&state=test-state" \
  com.zarz.spotiflac
```

Expected: app opens (or resumes) with no crash. Add a temporary `Log.i("SpotiFLAC", "spotifyLoginCallback fired: code=$code")` line during this check if needed to confirm via `adb logcat`, then remove it once Task 4 wires a real Dart-side handler that will make this observable in-app instead.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml android/app/src/main/kotlin/com/zarz/spotiflac/MainActivity.kt
git commit -m "feat(spotify): add native deep-link handling for Spotify OAuth redirect"
```

---

### Task 4: SpotifyAuthService — orchestrates login, token exchange, refresh, storage

**Files:**
- Create: `lib/services/spotify_auth_service.dart`
- Test: `test/spotify_auth_service_test.dart`

**Interfaces:**
- Consumes: `generateSpotifyPkcePair`, `buildSpotifyAuthorizeUrl` (Task 1), `SpotifyAuthTokens` (Task 2).
- Produces:
  - `class SpotifyConfig { static const clientId = '...'; static const redirectUri = 'spotiflac://spotify-login-callback'; static const scopes = [...]; }`
  - `class SpotifyAuthService { Future<SpotifyAuthTokens?> loadStoredTokens(); Future<void> clearStoredTokens(); Future<SpotifyAuthTokens> exchangeCodeForTokens({required String code, required String verifier}); Future<SpotifyAuthTokens> refreshTokens(SpotifyAuthTokens current); Future<String> ensureFreshAccessToken(); }` — later tasks (auth notifier) call `ensureFreshAccessToken()` before every Spotify Web API request.
  - Exposes the pending native callback as a stream: `static Stream<Map<String, dynamic>> loginCallbackEvents()` added to `PlatformBridge` (mirrors the existing `extensionSessionGrantEvents()` shape at `platform_bridge.dart:137-140`).

- [ ] **Step 1: Add the config constants file**

```dart
// lib/constants/spotify_config.dart
class SpotifyConfig {
  /// Client ID from your app at https://developer.spotify.com/dashboard.
  /// Fill this in with your own app's Client ID before building — it is not
  /// checked in with a real value since it's specific to your Spotify
  /// Developer account's redirect URI registration.
  static const clientId = String.fromEnvironment(
    'SPOTIFY_CLIENT_ID',
    defaultValue: '',
  );

  static const redirectUri = 'spotiflac://spotify-login-callback';

  static const scopes = [
    'playlist-read-private',
    'playlist-read-collaborative',
    'user-library-read',
    'user-follow-read',
    'user-read-email',
  ];
}
```

This reads from `--dart-define=SPOTIFY_CLIENT_ID=...` at build time (`flutter run --dart-define=SPOTIFY_CLIENT_ID=your_client_id`), so the real ID never needs to be committed to the repo, matching this codebase's "no secrets in source" precedent from the retired `_spotifyClientSecretKey` cleanup in `settings_provider.dart`.

- [ ] **Step 2: Add the PlatformBridge callback stream**

In `lib/services/platform_bridge.dart`, alongside `_extensionSessionGrantEvents` (line 127-129) and its handler in `_ensureBackendEventHandler` (line 145-164), add a sibling stream for the new native method:

```dart
  static final StreamController<Map<String, dynamic>>
  _spotifyLoginCallbackEvents = StreamController<Map<String, dynamic>>.broadcast();

  static Stream<Map<String, dynamic>> spotifyLoginCallbackEvents() {
    _ensureBackendEventHandler();
    return _spotifyLoginCallbackEvents.stream;
  }
```

And inside `_ensureBackendEventHandler`'s `switch (call.method)` (line 146), add a case alongside the existing `'extensionSessionGrantCompleted'` one:

```dart
        case 'spotifyLoginCallback':
          final args = call.arguments;
          if (args is Map) {
            _spotifyLoginCallbackEvents.add(Map<String, dynamic>.from(args));
          }
          return null;
```

- [ ] **Step 3: Write the failing tests for the pure/testable parts**

The HTTP calls themselves (`exchangeCodeForTokens`, `refreshTokens`) are thin wrappers with no branching logic worth unit-testing without a mock HTTP client (none is set up in this repo — see Task plan constraints). What *is* unit-testable without mocking is the request body construction, which is factored out as a pure function:

```dart
// test/spotify_auth_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/spotify_auth_service.dart';

void main() {
  group('buildTokenExchangeBody', () {
    test('authorization_code grant includes code_verifier, not a secret', () {
      final body = buildTokenExchangeBody(
        grantType: 'authorization_code',
        code: 'auth-code',
        verifier: 'verifier-value',
        redirectUri: 'spotiflac://spotify-login-callback',
        clientId: 'client-1',
      );
      expect(body['grant_type'], 'authorization_code');
      expect(body['code'], 'auth-code');
      expect(body['code_verifier'], 'verifier-value');
      expect(body['redirect_uri'], 'spotiflac://spotify-login-callback');
      expect(body['client_id'], 'client-1');
      expect(body.containsKey('client_secret'), isFalse);
    });

    test('refresh_token grant omits code/verifier/redirect_uri', () {
      final body = buildTokenExchangeBody(
        grantType: 'refresh_token',
        refreshToken: 'refresh-1',
        clientId: 'client-1',
      );
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'refresh-1');
      expect(body.containsKey('code'), isFalse);
      expect(body.containsKey('code_verifier'), isFalse);
    });
  });
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `flutter test test/spotify_auth_service_test.dart`
Expected: FAIL — `spotify_auth_service.dart` does not exist.

- [ ] **Step 5: Implement**

```dart
// lib/services/spotify_auth_service.dart
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:spotiflac_android/constants/spotify_config.dart';
import 'package:spotiflac_android/models/spotify_auth_tokens.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyAuthService');

const _tokenStorageKey = 'spotify_auth_tokens_v1';

Map<String, String> buildTokenExchangeBody({
  required String grantType,
  String? code,
  String? verifier,
  String? refreshToken,
  String? redirectUri,
  required String clientId,
}) {
  final body = <String, String>{'grant_type': grantType, 'client_id': clientId};
  if (grantType == 'authorization_code') {
    body['code'] = code!;
    body['code_verifier'] = verifier!;
    body['redirect_uri'] = redirectUri!;
  } else if (grantType == 'refresh_token') {
    body['refresh_token'] = refreshToken!;
  }
  return body;
}

class SpotifyAuthException implements Exception {
  final String message;
  const SpotifyAuthException(this.message);
  @override
  String toString() => 'SpotifyAuthException: $message';
}

class SpotifyAuthService {
  final FlutterSecureStorage _secureStorage;
  final http.Client _httpClient;

  SpotifyAuthService({
    FlutterSecureStorage? secureStorage,
    http.Client? httpClient,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _httpClient = httpClient ?? http.Client();

  Future<SpotifyAuthTokens?> loadStoredTokens() async {
    final raw = await _secureStorage.read(key: _tokenStorageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return SpotifyAuthTokens.fromStorageJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      _log.w('Failed to parse stored Spotify tokens: $e');
      return null;
    }
  }

  Future<void> _storeTokens(SpotifyAuthTokens tokens) async {
    await _secureStorage.write(
      key: _tokenStorageKey,
      value: jsonEncode(tokens.toStorageJson()),
    );
  }

  Future<void> clearStoredTokens() async {
    await _secureStorage.delete(key: _tokenStorageKey);
  }

  Future<SpotifyAuthTokens> exchangeCodeForTokens({
    required String code,
    required String verifier,
  }) async {
    final tokens = await _requestTokens(
      buildTokenExchangeBody(
        grantType: 'authorization_code',
        code: code,
        verifier: verifier,
        redirectUri: SpotifyConfig.redirectUri,
        clientId: SpotifyConfig.clientId,
      ),
    );
    await _storeTokens(tokens);
    return tokens;
  }

  Future<SpotifyAuthTokens> refreshTokens(SpotifyAuthTokens current) async {
    if (current.refreshToken == null) {
      throw const SpotifyAuthException('No refresh token available');
    }
    final tokens = await _requestTokens(
      buildTokenExchangeBody(
        grantType: 'refresh_token',
        refreshToken: current.refreshToken,
        clientId: SpotifyConfig.clientId,
      ),
      previousRefreshToken: current.refreshToken,
    );
    await _storeTokens(tokens);
    return tokens;
  }

  Future<SpotifyAuthTokens> _requestTokens(
    Map<String, String> body, {
    String? previousRefreshToken,
  }) async {
    final response = await _httpClient.post(
      Uri.https('accounts.spotify.com', '/api/token'),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
    );
    if (response.statusCode != 200) {
      throw SpotifyAuthException(
        'Token request failed: ${response.statusCode} ${response.body}',
      );
    }
    return SpotifyAuthTokens.fromTokenResponse(
      jsonDecode(response.body) as Map<String, dynamic>,
      now: DateTime.now(),
      previousRefreshToken: previousRefreshToken,
    );
  }

  /// Returns a valid access token, transparently refreshing if needed.
  /// Throws [SpotifyAuthException] if there are no stored tokens or refresh
  /// fails — callers should treat that as "user needs to log in again".
  Future<String> ensureFreshAccessToken() async {
    final stored = await loadStoredTokens();
    if (stored == null) {
      throw const SpotifyAuthException('Not logged in');
    }
    if (!stored.needsRefresh) {
      return stored.accessToken;
    }
    final refreshed = await refreshTokens(stored);
    return refreshed.accessToken;
  }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/spotify_auth_service_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 7: Commit**

```bash
git add lib/constants/spotify_config.dart lib/services/spotify_auth_service.dart lib/services/platform_bridge.dart test/spotify_auth_service_test.dart
git commit -m "feat(spotify): add SpotifyAuthService (PKCE token exchange, refresh, secure storage)"
```

---

### Task 5: SpotifyAuthNotifier — end-to-end login flow

**Files:**
- Create: `lib/providers/spotify_auth_provider.dart`
- Test: `test/spotify_auth_provider_test.dart`

**Interfaces:**
- Consumes: `SpotifyAuthService` (Task 4), `generateSpotifyPkcePair`/`buildSpotifyAuthorizeUrl` (Task 1), `PlatformBridge.spotifyLoginCallbackEvents()` (Task 4).
- Produces:
  - `enum SpotifyAuthStatus { unknown, loggedOut, loggingIn, loggedIn }`
  - `class SpotifyAuthState { final SpotifyAuthStatus status; final String? error; }`
  - `class SpotifyAuthNotifier extends Notifier<SpotifyAuthState> { Future<void> login(); Future<void> logout(); Future<String> accessToken(); }`
  - `final spotifyAuthProvider = NotifierProvider<SpotifyAuthNotifier, SpotifyAuthState>(SpotifyAuthNotifier.new);`

- [ ] **Step 1: Write the failing test** (covers the pure state-transition helper; the full flow needs a live browser/deep-link and is covered by manual verification in Step 4)

```dart
// test/spotify_auth_provider_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/spotify_auth_provider.dart';

void main() {
  group('SpotifyAuthState', () {
    test('copyWith overrides only the given fields', () {
      const initial = SpotifyAuthState(status: SpotifyAuthStatus.loggedOut);
      final updated = initial.copyWith(
        status: SpotifyAuthStatus.loggingIn,
      );
      expect(updated.status, SpotifyAuthStatus.loggingIn);
      expect(updated.error, isNull);

      final withError = updated.copyWith(
        status: SpotifyAuthStatus.loggedOut,
        error: 'denied',
      );
      expect(withError.status, SpotifyAuthStatus.loggedOut);
      expect(withError.error, 'denied');
    });

    test('clearError removes a previously-set error', () {
      const withError = SpotifyAuthState(
        status: SpotifyAuthStatus.loggedOut,
        error: 'denied',
      );
      final cleared = withError.copyWith(clearError: true);
      expect(cleared.error, isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/spotify_auth_provider_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement**

```dart
// lib/providers/spotify_auth_provider.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:spotiflac_android/constants/spotify_config.dart';
import 'package:spotiflac_android/services/spotify_auth_service.dart';
import 'package:spotiflac_android/services/spotify_pkce.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyAuth');

enum SpotifyAuthStatus { unknown, loggedOut, loggingIn, loggedIn }

class SpotifyAuthState {
  final SpotifyAuthStatus status;
  final String? error;

  const SpotifyAuthState({
    this.status = SpotifyAuthStatus.unknown,
    this.error,
  });

  SpotifyAuthState copyWith({
    SpotifyAuthStatus? status,
    String? error,
    bool clearError = false,
  }) {
    return SpotifyAuthState(
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SpotifyAuthNotifier extends Notifier<SpotifyAuthState> {
  final SpotifyAuthService _service = SpotifyAuthService();
  StreamSubscription<Map<String, dynamic>>? _callbackSubscription;
  Completer<Map<String, dynamic>>? _pendingLogin;
  String? _pendingState;
  SpotifyPkcePair? _pendingPkce;

  @override
  SpotifyAuthState build() {
    _callbackSubscription = PlatformBridge.spotifyLoginCallbackEvents().listen(
      _handleCallback,
    );
    ref.onDispose(() => _callbackSubscription?.cancel());
    unawaited(_loadInitialStatus());
    return const SpotifyAuthState();
  }

  Future<void> _loadInitialStatus() async {
    final tokens = await _service.loadStoredTokens();
    state = state.copyWith(
      status: tokens != null
          ? SpotifyAuthStatus.loggedIn
          : SpotifyAuthStatus.loggedOut,
    );
  }

  void _handleCallback(Map<String, dynamic> args) {
    final pending = _pendingLogin;
    if (pending == null || pending.isCompleted) return;
    if (args['state'] != _pendingState) {
      _log.w('Ignoring Spotify callback with mismatched state');
      return;
    }
    pending.complete(args);
  }

  Future<void> login() async {
    if (SpotifyConfig.clientId.isEmpty) {
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedOut,
        error: 'SpotifyConfig.clientId is not set',
      );
      return;
    }

    state = state.copyWith(
      status: SpotifyAuthStatus.loggingIn,
      clearError: true,
    );

    final pkce = generateSpotifyPkcePair();
    final oauthState = DateTime.now().microsecondsSinceEpoch.toString();
    _pendingPkce = pkce;
    _pendingState = oauthState;
    _pendingLogin = Completer<Map<String, dynamic>>();

    final authorizeUrl = buildSpotifyAuthorizeUrl(
      clientId: SpotifyConfig.clientId,
      redirectUri: SpotifyConfig.redirectUri,
      codeChallenge: pkce.challenge,
      scopes: SpotifyConfig.scopes,
      state: oauthState,
    );

    final launched = await launchUrl(
      Uri.parse(authorizeUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedOut,
        error: 'Could not open the browser for Spotify login',
      );
      return;
    }

    try {
      final result = await _pendingLogin!.future.timeout(
        const Duration(minutes: 5),
      );
      final error = result['error'] as String?;
      final code = result['code'] as String?;
      if (error != null || code == null) {
        state = state.copyWith(
          status: SpotifyAuthStatus.loggedOut,
          error: error ?? 'Login was cancelled',
        );
        return;
      }
      await _service.exchangeCodeForTokens(
        code: code,
        verifier: _pendingPkce!.verifier,
      );
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedIn,
        clearError: true,
      );
    } on TimeoutException {
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedOut,
        error: 'Login timed out',
      );
    } catch (e) {
      _log.e('Spotify login failed', e);
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedOut,
        error: 'Login failed: $e',
      );
    } finally {
      _pendingLogin = null;
      _pendingState = null;
      _pendingPkce = null;
    }
  }

  Future<void> logout() async {
    await _service.clearStoredTokens();
    state = const SpotifyAuthState(status: SpotifyAuthStatus.loggedOut);
  }

  /// Used by the library/streaming services before every Spotify Web API call.
  Future<String> accessToken() => _service.ensureFreshAccessToken();
}

final spotifyAuthProvider =
    NotifierProvider<SpotifyAuthNotifier, SpotifyAuthState>(
      SpotifyAuthNotifier.new,
    );
```

- [ ] **Step 4: Run test to verify it passes, then manually verify the live flow**

Run: `flutter test test/spotify_auth_provider_test.dart`
Expected: PASS (2 tests)

Manual verification (needs Task 6's UI to trigger `login()`, so do this after Task 6): tap "Connect Spotify", complete login in the browser, confirm the app resumes and `spotifyAuthProvider` state becomes `loggedIn`.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/spotify_auth_provider.dart test/spotify_auth_provider_test.dart
git commit -m "feat(spotify): add SpotifyAuthNotifier driving the end-to-end login flow"
```

---

### Task 6: Login UI + Settings entry point

**Files:**
- Create: `lib/screens/spotify/spotify_login_screen.dart`
- Modify: `lib/screens/settings/settings_tab.dart` (add a "Spotify Account" entry — read the file first to match its existing `SettingsGroup`/list-tile pattern before inserting)
- Modify: `lib/app.dart` (add a route)

**Interfaces:**
- Consumes: `spotifyAuthProvider` (Task 5).
- Produces: route `/spotify` pushed from Settings.

- [ ] **Step 1: Add the route**

In `lib/app.dart`, inside the `routes:` list (after the `/tutorial` route, before `errorBuilder`):

```dart
      GoRoute(
        path: '/spotify',
        builder: (context, state) => const SpotifyLoginScreen(),
      ),
```

Add the import: `import 'package:spotiflac_android/screens/spotify/spotify_login_screen.dart';`

- [ ] **Step 2: Build the login screen**

```dart
// lib/screens/spotify/spotify_login_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/spotify_auth_provider.dart';
import 'package:spotiflac_android/screens/spotify/spotify_library_screen.dart';

class SpotifyLoginScreen extends ConsumerWidget {
  const SpotifyLoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(spotifyAuthProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Spotify Account')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.podcasts, size: 64),
              const SizedBox(height: 16),
              switch (authState.status) {
                SpotifyAuthStatus.loggedIn => Column(
                  children: [
                    const Text('Connected to Spotify'),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SpotifyLibraryScreen(),
                        ),
                      ),
                      child: const Text('Browse your library'),
                    ),
                    TextButton(
                      onPressed: () =>
                          ref.read(spotifyAuthProvider.notifier).logout(),
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
                SpotifyAuthStatus.loggingIn => const Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Waiting for Spotify login...'),
                  ],
                ),
                _ => Column(
                  children: [
                    const Text('Connect your Spotify account to stream your library'),
                    if (authState.error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        authState.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () =>
                          ref.read(spotifyAuthProvider.notifier).login(),
                      child: const Text('Connect Spotify'),
                    ),
                  ],
                ),
              },
            ],
          ),
        ),
      ),
    );
  }
}
```

(`SpotifyLibraryScreen` is created in Task 9 — this file will not compile until then; that's expected and corrected by the end of Task 9, consistent with building a vertical slice top-down. If you want every task independently green, stub `SpotifyLibraryScreen` here as an empty `Scaffold` and let Task 9 replace it.)

- [ ] **Step 3: Add the Settings entry point**

Read `lib/screens/settings/settings_tab.dart` first to find its `SettingsGroup`/tile list, then add one tile near the top (account-related settings), navigating to `/spotify` via `context.push('/spotify')` (go_router) or `GoRouter.of(context).push('/spotify')`, following whatever navigation call convention the surrounding tiles already use in that file.

- [ ] **Step 4: Manual verification**

Run the app, go to Settings → Spotify Account, tap Connect Spotify, confirm the external browser opens Spotify's login page, and (once Task 9 exists) confirm a successful login returns you to the app showing "Connected to Spotify".

- [ ] **Step 5: Commit**

```bash
git add lib/app.dart lib/screens/spotify/spotify_login_screen.dart lib/screens/settings/settings_tab.dart
git commit -m "feat(spotify): add login screen and Settings entry point"
```

---

### Task 7: Spotify Web API library client (pure JSON parsing, testable)

**Files:**
- Create: `lib/models/spotify_library_models.dart`
- Create: `lib/services/spotify_library_service.dart`
- Test: `test/spotify_library_models_test.dart`

**Interfaces:**
- Produces:
  - `class SpotifyPlaylistSummary { final String id; final String name; final String? imageUrl; final int trackCount; final String ownerName; }`
  - `class SpotifyLikedTrack { final String addedAt; final SpotifyApiTrack track; }`
  - `class SpotifyApiTrack { final String id; final String name; final String artistNames; final String albumName; final String? albumImageUrl; final String? isrc; final int durationMs; }` with `factory SpotifyApiTrack.fromJson(Map<String, dynamic> json)`.
  - `class SpotifyFollowedArtist { final String id; final String name; final String? imageUrl; }`
  - `class SpotifyPage<T> { final List<T> items; final String? nextUrl; }`
  - Parsing functions: `SpotifyPage<SpotifyPlaylistSummary> parsePlaylistsPage(Map<String,dynamic> json)`, `SpotifyPage<SpotifyLikedTrack> parseLikedTracksPage(Map<String,dynamic> json)`, `SpotifyPage<SpotifyFollowedArtist> parseFollowedArtistsPage(Map<String,dynamic> json)`.
  - `class SpotifyLibraryService { Future<SpotifyPage<SpotifyPlaylistSummary>> getPlaylists({String? pageUrl}); Future<SpotifyPage<SpotifyLikedTrack>> getLikedTracks({String? pageUrl}); Future<SpotifyPage<SpotifyFollowedArtist>> getFollowedArtists({String? pageUrl}); Future<List<SpotifyApiTrack>> getPlaylistTracks(String playlistId); }` (each method calls `spotifyAuthProvider`-supplied token via constructor injection — see implementation).

- [ ] **Step 1: Write the failing tests**

```dart
// test/spotify_library_models_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';

void main() {
  group('parsePlaylistsPage', () {
    test('parses items and next url', () {
      final page = parsePlaylistsPage({
        'items': [
          {
            'id': 'pl1',
            'name': 'My Playlist',
            'owner': {'display_name': 'Alice'},
            'tracks': {'total': 12},
            'images': [
              {'url': 'https://img/1.jpg'},
            ],
          },
        ],
        'next': 'https://api.spotify.com/v1/me/playlists?offset=50',
      });

      expect(page.items, hasLength(1));
      expect(page.items.first.id, 'pl1');
      expect(page.items.first.name, 'My Playlist');
      expect(page.items.first.ownerName, 'Alice');
      expect(page.items.first.trackCount, 12);
      expect(page.items.first.imageUrl, 'https://img/1.jpg');
      expect(page.nextUrl, 'https://api.spotify.com/v1/me/playlists?offset=50');
    });

    test('handles a playlist with no images', () {
      final page = parsePlaylistsPage({
        'items': [
          {
            'id': 'pl2',
            'name': 'Empty Art',
            'owner': {'display_name': 'Bob'},
            'tracks': {'total': 0},
            'images': [],
          },
        ],
        'next': null,
      });
      expect(page.items.first.imageUrl, isNull);
      expect(page.nextUrl, isNull);
    });
  });

  group('SpotifyApiTrack.fromJson', () {
    test('joins multiple artist names and reads ISRC from external_ids', () {
      final track = SpotifyApiTrack.fromJson({
        'id': 'tr1',
        'name': 'Song Name',
        'artists': [
          {'name': 'Artist A'},
          {'name': 'Artist B'},
        ],
        'album': {
          'name': 'Album Name',
          'images': [
            {'url': 'https://img/album.jpg'},
          ],
        },
        'external_ids': {'isrc': 'US1234567890'},
        'duration_ms': 210000,
      });

      expect(track.artistNames, 'Artist A, Artist B');
      expect(track.albumName, 'Album Name');
      expect(track.albumImageUrl, 'https://img/album.jpg');
      expect(track.isrc, 'US1234567890');
      expect(track.durationMs, 210000);
    });
  });

  group('parseLikedTracksPage', () {
    test('unwraps the {added_at, track} envelope', () {
      final page = parseLikedTracksPage({
        'items': [
          {
            'added_at': '2026-01-01T00:00:00Z',
            'track': {
              'id': 'tr1',
              'name': 'Liked Song',
              'artists': [
                {'name': 'Someone'},
              ],
              'album': {'name': 'An Album', 'images': []},
              'external_ids': {},
              'duration_ms': 180000,
            },
          },
        ],
        'next': null,
      });
      expect(page.items, hasLength(1));
      expect(page.items.first.addedAt, '2026-01-01T00:00:00Z');
      expect(page.items.first.track.name, 'Liked Song');
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/spotify_library_models_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement the models file**

```dart
// lib/models/spotify_library_models.dart
class SpotifyPage<T> {
  final List<T> items;
  final String? nextUrl;
  const SpotifyPage({required this.items, this.nextUrl});
}

class SpotifyPlaylistSummary {
  final String id;
  final String name;
  final String? imageUrl;
  final int trackCount;
  final String ownerName;

  const SpotifyPlaylistSummary({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.trackCount,
    required this.ownerName,
  });
}

class SpotifyApiTrack {
  final String id;
  final String name;
  final String artistNames;
  final String albumName;
  final String? albumImageUrl;
  final String? isrc;
  final int durationMs;

  const SpotifyApiTrack({
    required this.id,
    required this.name,
    required this.artistNames,
    required this.albumName,
    required this.albumImageUrl,
    required this.isrc,
    required this.durationMs,
  });

  factory SpotifyApiTrack.fromJson(Map<String, dynamic> json) {
    final artists = (json['artists'] as List? ?? const [])
        .map((a) => (a as Map)['name'] as String)
        .join(', ');
    final album = json['album'] as Map<String, dynamic>? ?? const {};
    final images = album['images'] as List? ?? const [];
    final externalIds = json['external_ids'] as Map<String, dynamic>? ?? const {};
    return SpotifyApiTrack(
      id: json['id'] as String,
      name: json['name'] as String,
      artistNames: artists,
      albumName: album['name'] as String? ?? '',
      albumImageUrl: images.isNotEmpty
          ? (images.first as Map)['url'] as String?
          : null,
      isrc: externalIds['isrc'] as String?,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

class SpotifyLikedTrack {
  final String addedAt;
  final SpotifyApiTrack track;
  const SpotifyLikedTrack({required this.addedAt, required this.track});
}

class SpotifyFollowedArtist {
  final String id;
  final String name;
  final String? imageUrl;
  const SpotifyFollowedArtist({
    required this.id,
    required this.name,
    required this.imageUrl,
  });
}

SpotifyPage<SpotifyPlaylistSummary> parsePlaylistsPage(
  Map<String, dynamic> json,
) {
  final items = (json['items'] as List? ?? const [])
      .map((raw) {
        final map = raw as Map<String, dynamic>;
        final images = map['images'] as List? ?? const [];
        final owner = map['owner'] as Map<String, dynamic>? ?? const {};
        final tracks = map['tracks'] as Map<String, dynamic>? ?? const {};
        return SpotifyPlaylistSummary(
          id: map['id'] as String,
          name: map['name'] as String,
          imageUrl: images.isNotEmpty
              ? (images.first as Map)['url'] as String?
              : null,
          trackCount: (tracks['total'] as num?)?.toInt() ?? 0,
          ownerName: owner['display_name'] as String? ?? '',
        );
      })
      .toList();
  return SpotifyPage(items: items, nextUrl: json['next'] as String?);
}

SpotifyPage<SpotifyLikedTrack> parseLikedTracksPage(
  Map<String, dynamic> json,
) {
  final items = (json['items'] as List? ?? const [])
      .map(
        (raw) => SpotifyLikedTrack(
          addedAt: (raw as Map<String, dynamic>)['added_at'] as String,
          track: SpotifyApiTrack.fromJson(
            raw['track'] as Map<String, dynamic>,
          ),
        ),
      )
      .toList();
  return SpotifyPage(items: items, nextUrl: json['next'] as String?);
}

SpotifyPage<SpotifyFollowedArtist> parseFollowedArtistsPage(
  Map<String, dynamic> json,
) {
  final artistsBlock = json['artists'] as Map<String, dynamic>? ?? json;
  final items = (artistsBlock['items'] as List? ?? const [])
      .map((raw) {
        final map = raw as Map<String, dynamic>;
        final images = map['images'] as List? ?? const [];
        return SpotifyFollowedArtist(
          id: map['id'] as String,
          name: map['name'] as String,
          imageUrl: images.isNotEmpty
              ? (images.first as Map)['url'] as String?
              : null,
        );
      })
      .toList();
  return SpotifyPage(items: items, nextUrl: artistsBlock['next'] as String?);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/spotify_library_models_test.dart`
Expected: PASS (5 tests)

- [ ] **Step 5: Implement the HTTP service (thin wrapper, manually verified)**

```dart
// lib/services/spotify_library_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:spotiflac_android/models/spotify_library_models.dart';

class SpotifyApiException implements Exception {
  final int statusCode;
  final String body;
  const SpotifyApiException(this.statusCode, this.body);
  @override
  String toString() => 'SpotifyApiException($statusCode): $body';
}

class SpotifyLibraryService {
  final Future<String> Function() _getAccessToken;
  final http.Client _httpClient;

  SpotifyLibraryService({
    required Future<String> Function() getAccessToken,
    http.Client? httpClient,
  }) : _getAccessToken = getAccessToken,
       _httpClient = httpClient ?? http.Client();

  Future<Map<String, dynamic>> _get(String url) async {
    final token = await _getAccessToken();
    final response = await _httpClient.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw SpotifyApiException(response.statusCode, response.body);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<SpotifyPage<SpotifyPlaylistSummary>> getPlaylists({
    String? pageUrl,
  }) async {
    final url =
        pageUrl ?? 'https://api.spotify.com/v1/me/playlists?limit=50';
    return parsePlaylistsPage(await _get(url));
  }

  Future<SpotifyPage<SpotifyLikedTrack>> getLikedTracks({
    String? pageUrl,
  }) async {
    final url = pageUrl ?? 'https://api.spotify.com/v1/me/tracks?limit=50';
    return parseLikedTracksPage(await _get(url));
  }

  Future<SpotifyPage<SpotifyFollowedArtist>> getFollowedArtists({
    String? pageUrl,
  }) async {
    final url =
        pageUrl ?? 'https://api.spotify.com/v1/me/following?type=artist&limit=50';
    return parseFollowedArtistsPage(await _get(url));
  }

  Future<SpotifyPage<SpotifyApiTrack>> getPlaylistTracks(
    String playlistId, {
    String? pageUrl,
  }) async {
    final url =
        pageUrl ??
        'https://api.spotify.com/v1/playlists/$playlistId/tracks?limit=100';
    final json = await _get(url);
    final items = (json['items'] as List? ?? const [])
        .map(
          (raw) => SpotifyApiTrack.fromJson(
            (raw as Map<String, dynamic>)['track'] as Map<String, dynamic>,
          ),
        )
        .toList();
    return SpotifyPage(items: items, nextUrl: json['next'] as String?);
  }
}
```

- [ ] **Step 6: Commit**

```bash
git add lib/models/spotify_library_models.dart lib/services/spotify_library_service.dart test/spotify_library_models_test.dart
git commit -m "feat(spotify): add library models + Spotify Web API client"
```

---

### Task 8: Map Spotify API tracks onto the existing `Track` model

**Files:**
- Create: `lib/utils/spotify_track_mapper.dart`
- Test: `test/spotify_track_mapper_test.dart`

**Interfaces:**
- Consumes: `SpotifyApiTrack` (Task 7), `Track` (existing, `lib/models/track.dart`).
- Produces: `Track spotifyApiTrackToTrack(SpotifyApiTrack apiTrack)`.

This is the seam between the new Spotify-account feature and the app's existing extension-resolution pipeline — every screen in Task 9 converts to `Track` at the boundary so Task 10's streaming provider can stay unaware that the track came from Spotify's own library rather than a pasted link.

- [ ] **Step 1: Write the failing test**

```dart
// test/spotify_track_mapper_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/utils/spotify_track_mapper.dart';

void main() {
  test('maps a SpotifyApiTrack onto the app Track model', () {
    const apiTrack = SpotifyApiTrack(
      id: 'tr1',
      name: 'Song Name',
      artistNames: 'Artist A, Artist B',
      albumName: 'Album Name',
      albumImageUrl: 'https://img/album.jpg',
      isrc: 'US1234567890',
      durationMs: 210000,
    );

    final track = spotifyApiTrackToTrack(apiTrack);

    expect(track.id, 'tr1');
    expect(track.name, 'Song Name');
    expect(track.artistName, 'Artist A, Artist B');
    expect(track.albumName, 'Album Name');
    expect(track.coverUrl, 'https://img/album.jpg');
    expect(track.isrc, 'US1234567890');
    expect(track.duration, 210); // seconds, not ms
    expect(track.source, 'spotify-library');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/spotify_track_mapper_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement**

```dart
// lib/utils/spotify_track_mapper.dart
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/models/track.dart';

/// Marks tracks that came from the user's own Spotify library sync, as
/// opposed to `source` values naming a resolving extension (e.g. `deezer`).
/// [stream_resolution_service] (Task 10) uses this to know a track has no
/// resolved audio source yet and must go through provider-priority resolution.
const spotifyLibrarySourceId = 'spotify-library';

Track spotifyApiTrackToTrack(SpotifyApiTrack apiTrack) {
  return Track(
    id: apiTrack.id,
    name: apiTrack.name,
    artistName: apiTrack.artistNames,
    albumName: apiTrack.albumName,
    coverUrl: apiTrack.albumImageUrl,
    isrc: apiTrack.isrc,
    duration: (apiTrack.durationMs / 1000).round(),
    source: spotifyLibrarySourceId,
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/spotify_track_mapper_test.dart`
Expected: PASS (1 test)

- [ ] **Step 5: Commit**

```bash
git add lib/utils/spotify_track_mapper.dart test/spotify_track_mapper_test.dart
git commit -m "feat(spotify): map Spotify API tracks onto the app's Track model"
```

---

### Task 9: SpotifyLibraryNotifier + library UI screens

**Files:**
- Create: `lib/providers/spotify_library_provider.dart`
- Create: `lib/screens/spotify/spotify_library_screen.dart`
- Create: `lib/screens/spotify/spotify_playlist_detail_screen.dart`
- Test: `test/spotify_library_provider_test.dart`

**Interfaces:**
- Consumes: `SpotifyLibraryService` (Task 7), `spotifyAuthProvider.notifier.accessToken()` (Task 5).
- Produces:
  - `class SpotifyLibraryState { final List<SpotifyPlaylistSummary> playlists; final List<SpotifyLikedTrack> likedTracks; final List<SpotifyFollowedArtist> followedArtists; final bool isLoading; final String? error; }` with `copyWith`.
  - `class SpotifyLibraryNotifier extends Notifier<SpotifyLibraryState> { Future<void> syncAll(); }`
  - `final spotifyLibraryProvider = NotifierProvider<SpotifyLibraryNotifier, SpotifyLibraryState>(SpotifyLibraryNotifier.new);`

- [ ] **Step 1: Write the failing test** (state shape only — network calls are manually verified, consistent with Task 7)

```dart
// test/spotify_library_provider_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/providers/spotify_library_provider.dart';

void main() {
  test('copyWith merges playlists/likedTracks/followedArtists independently', () {
    const initial = SpotifyLibraryState();
    final withPlaylists = initial.copyWith(
      playlists: const [
        SpotifyPlaylistSummary(
          id: 'p1',
          name: 'P',
          imageUrl: null,
          trackCount: 1,
          ownerName: 'Me',
        ),
      ],
    );
    expect(withPlaylists.playlists, hasLength(1));
    expect(withPlaylists.likedTracks, isEmpty);

    final withError = withPlaylists.copyWith(
      isLoading: false,
      error: 'network error',
    );
    expect(withError.playlists, hasLength(1)); // unrelated field preserved
    expect(withError.error, 'network error');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/spotify_library_provider_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement the provider**

```dart
// lib/providers/spotify_library_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/providers/spotify_auth_provider.dart';
import 'package:spotiflac_android/services/spotify_library_service.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyLibrary');

class SpotifyLibraryState {
  final List<SpotifyPlaylistSummary> playlists;
  final List<SpotifyLikedTrack> likedTracks;
  final List<SpotifyFollowedArtist> followedArtists;
  final bool isLoading;
  final String? error;

  const SpotifyLibraryState({
    this.playlists = const [],
    this.likedTracks = const [],
    this.followedArtists = const [],
    this.isLoading = false,
    this.error,
  });

  SpotifyLibraryState copyWith({
    List<SpotifyPlaylistSummary>? playlists,
    List<SpotifyLikedTrack>? likedTracks,
    List<SpotifyFollowedArtist>? followedArtists,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return SpotifyLibraryState(
      playlists: playlists ?? this.playlists,
      likedTracks: likedTracks ?? this.likedTracks,
      followedArtists: followedArtists ?? this.followedArtists,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SpotifyLibraryNotifier extends Notifier<SpotifyLibraryState> {
  late final SpotifyLibraryService _service;

  @override
  SpotifyLibraryState build() {
    _service = SpotifyLibraryService(
      getAccessToken: () => ref.read(spotifyAuthProvider.notifier).accessToken(),
    );
    return const SpotifyLibraryState();
  }

  Future<void> syncAll() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final playlists = await _collectAllPages(
        (pageUrl) => _service.getPlaylists(pageUrl: pageUrl),
      );
      final liked = await _collectAllPages(
        (pageUrl) => _service.getLikedTracks(pageUrl: pageUrl),
      );
      final followed = await _collectAllPages(
        (pageUrl) => _service.getFollowedArtists(pageUrl: pageUrl),
      );
      state = state.copyWith(
        playlists: playlists,
        likedTracks: liked,
        followedArtists: followed,
        isLoading: false,
      );
    } catch (e) {
      _log.e('Spotify library sync failed', e);
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<List<T>> _collectAllPages<T>(
    Future<SpotifyPage<T>> Function(String? pageUrl) fetchPage,
  ) async {
    final all = <T>[];
    String? nextUrl;
    do {
      final page = await fetchPage(nextUrl);
      all.addAll(page.items);
      nextUrl = page.nextUrl;
    } while (nextUrl != null);
    return all;
  }
}

final spotifyLibraryProvider =
    NotifierProvider<SpotifyLibraryNotifier, SpotifyLibraryState>(
      SpotifyLibraryNotifier.new,
    );
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/spotify_library_provider_test.dart`
Expected: PASS (1 test)

- [ ] **Step 5: Build the library screen (tabbed: Playlists / Liked Songs / Followed Artists)**

```dart
// lib/screens/spotify/spotify_library_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/spotify_library_provider.dart';
import 'package:spotiflac_android/screens/spotify/spotify_playlist_detail_screen.dart';
import 'package:spotiflac_android/utils/spotify_track_mapper.dart';
import 'package:spotiflac_android/providers/spotify_stream_player_provider.dart';

class SpotifyLibraryScreen extends ConsumerStatefulWidget {
  const SpotifyLibraryScreen({super.key});

  @override
  ConsumerState<SpotifyLibraryScreen> createState() =>
      _SpotifyLibraryScreenState();
}

class _SpotifyLibraryScreenState extends ConsumerState<SpotifyLibraryScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(spotifyLibraryProvider.notifier).syncAll(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(spotifyLibraryProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Your Spotify Library'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Playlists'),
              Tab(text: 'Liked Songs'),
              Tab(text: 'Following'),
            ],
          ),
        ),
        body: library.isLoading
            ? const Center(child: CircularProgressIndicator())
            : library.error != null
            ? Center(child: Text(library.error!))
            : TabBarView(
                children: [
                  ListView.builder(
                    itemCount: library.playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = library.playlists[index];
                      return ListTile(
                        leading: playlist.imageUrl != null
                            ? Image.network(playlist.imageUrl!, width: 48)
                            : const Icon(Icons.queue_music),
                        title: Text(playlist.name),
                        subtitle: Text('${playlist.trackCount} tracks · ${playlist.ownerName}'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SpotifyPlaylistDetailScreen(
                              playlistId: playlist.id,
                              playlistName: playlist.name,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  ListView.builder(
                    itemCount: library.likedTracks.length,
                    itemBuilder: (context, index) {
                      final liked = library.likedTracks[index];
                      return ListTile(
                        title: Text(liked.track.name),
                        subtitle: Text(liked.track.artistNames),
                        onTap: () => ref
                            .read(spotifyStreamPlayerProvider.notifier)
                            .streamTrack(spotifyApiTrackToTrack(liked.track)),
                      );
                    },
                  ),
                  ListView.builder(
                    itemCount: library.followedArtists.length,
                    itemBuilder: (context, index) {
                      final artist = library.followedArtists[index];
                      return ListTile(
                        leading: artist.imageUrl != null
                            ? Image.network(artist.imageUrl!, width: 48)
                            : const Icon(Icons.person),
                        title: Text(artist.name),
                      );
                    },
                  ),
                ],
              ),
      ),
    );
  }
}
```

- [ ] **Step 6: Build the playlist detail screen**

```dart
// lib/screens/spotify/spotify_playlist_detail_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/providers/spotify_auth_provider.dart';
import 'package:spotiflac_android/services/spotify_library_service.dart';
import 'package:spotiflac_android/utils/spotify_track_mapper.dart';
import 'package:spotiflac_android/providers/spotify_stream_player_provider.dart';

class SpotifyPlaylistDetailScreen extends ConsumerStatefulWidget {
  final String playlistId;
  final String playlistName;

  const SpotifyPlaylistDetailScreen({
    super.key,
    required this.playlistId,
    required this.playlistName,
  });

  @override
  ConsumerState<SpotifyPlaylistDetailScreen> createState() =>
      _SpotifyPlaylistDetailScreenState();
}

class _SpotifyPlaylistDetailScreenState
    extends ConsumerState<SpotifyPlaylistDetailScreen> {
  List<SpotifyApiTrack> _tracks = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = SpotifyLibraryService(
      getAccessToken: () =>
          ref.read(spotifyAuthProvider.notifier).accessToken(),
    );
    try {
      final all = <SpotifyApiTrack>[];
      String? nextUrl;
      do {
        final page = await service.getPlaylistTracks(
          widget.playlistId,
          pageUrl: nextUrl,
        );
        all.addAll(page.items);
        nextUrl = page.nextUrl;
      } while (nextUrl != null);
      setState(() {
        _tracks = all;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlistName)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : ListView.builder(
              itemCount: _tracks.length,
              itemBuilder: (context, index) {
                final track = _tracks[index];
                return ListTile(
                  title: Text(track.name),
                  subtitle: Text(track.artistNames),
                  onTap: () => ref
                      .read(spotifyStreamPlayerProvider.notifier)
                      .streamTrack(spotifyApiTrackToTrack(track)),
                );
              },
            ),
    );
  }
}
```

(`spotifyStreamPlayerProvider` is created in Task 10 — same top-down-slice note as Task 6.)

- [ ] **Step 7: Manual verification**

Run the app, log in, open "Browse your library", confirm playlists/liked songs/followed artists load with real data from your account.

- [ ] **Step 8: Commit**

```bash
git add lib/providers/spotify_library_provider.dart lib/screens/spotify/spotify_library_screen.dart lib/screens/spotify/spotify_playlist_detail_screen.dart test/spotify_library_provider_test.dart
git commit -m "feat(spotify): add library sync provider and library/playlist UI"
```

---

### Task 10: Stream playback — resolve via the existing extension pipeline, autoplay

**Files:**
- Create: `lib/providers/spotify_stream_player_provider.dart`
- Test: `test/spotify_stream_player_provider_test.dart`

**Interfaces:**
- Consumes: `Track` (existing), `PlatformBridge.downloadByStrategy` (existing, `platform_bridge.dart:470`), `DownloadRequestPayload` (existing, `lib/services/download_request_payload.dart`).
- Produces:
  - `enum StreamPlaybackStatus { idle, resolving, buffering, playing, paused, error }`
  - `class StreamPlaybackState { final Track? currentTrack; final StreamPlaybackStatus status; final String? error; }`
  - `class SpotifyStreamPlayerNotifier extends Notifier<StreamPlaybackState> { Future<void> streamTrack(Track track); Future<void> pause(); Future<void> resume(); Future<void> stop(); }`
  - `final spotifyStreamPlayerProvider = NotifierProvider<SpotifyStreamPlayerNotifier, StreamPlaybackState>(SpotifyStreamPlayerNotifier.new);`

Design: one track streams at a time (mirrors `preview_player_provider.dart`'s single-active-item model). On `streamTrack`, the previous temp file (if any) is deleted, a fresh `downloadByStrategy` call targets a per-track file under the app's temp cache dir, and once it resolves, `audioplayers`' `DeviceFileSource` plays the completed local file — this is the "download-then-autoplay, no separate Download tap" model documented in the design spec (`planning/specs/2026-07-30-spotify-streaming-client-design.md`), not byte-range progressive streaming, since the Go backend's download contract has no partial-file signal to build progressive playback on top of.

- [ ] **Step 1: Write the failing test** (state-shape and temp-path-building are pure; the actual `downloadByStrategy`/`AudioPlayer` calls are manually verified)

```dart
// test/spotify_stream_player_provider_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/spotify_stream_player_provider.dart';

void main() {
  group('streamCacheFileName', () {
    test('is stable and filesystem-safe for a given track id', () {
      final name = streamCacheFileName('abc123');
      expect(name, 'stream_abc123');
      expect(RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(name), isTrue);
    });

    test('sanitizes ids containing path separators', () {
      final name = streamCacheFileName('a/b:c');
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(':')));
    });
  });

  group('StreamPlaybackState', () {
    test('copyWith clearTrack removes the current track', () {
      const track = null; // placeholder to keep import list minimal below
      const initial = StreamPlaybackState(
        status: StreamPlaybackStatus.playing,
      );
      final cleared = initial.copyWith(
        clearTrack: true,
        status: StreamPlaybackStatus.idle,
      );
      expect(cleared.currentTrack, track);
      expect(cleared.status, StreamPlaybackStatus.idle);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/spotify_stream_player_provider_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement**

```dart
// lib/providers/spotify_stream_player_provider.dart
import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/download_request_payload.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/services/music_player_service.dart'
    show musicPlayerHandler, musicPlayerExclusiveAudioHook;
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyStreamPlayer');

String streamCacheFileName(String trackId) {
  final sanitized = trackId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
  return 'stream_$sanitized';
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
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String? _activeTempPath;

  @override
  StreamPlaybackState build() {
    musicPlayerExclusiveAudioHook = () async {
      if (state.status != StreamPlaybackStatus.idle) await stop();
    };
    ref.onDispose(() {
      musicPlayerExclusiveAudioHook = null;
      _discardPlayer();
    });
    return const StreamPlaybackState();
  }

  Future<Directory> _cacheDir() async {
    final tempDir = await getTemporaryDirectory();
    final streamDir = Directory('${tempDir.path}/spotify_stream_cache');
    if (!await streamDir.exists()) {
      await streamDir.create(recursive: true);
    }
    return streamDir;
  }

  Future<void> streamTrack(Track track) async {
    try {
      await musicPlayerHandler?.pause();
    } catch (_) {}

    await _cleanupPreviousTempFile();

    state = StreamPlaybackState(
      currentTrack: track,
      status: StreamPlaybackStatus.resolving,
    );

    final dir = await _cacheDir();

    state = state.copyWith(status: StreamPlaybackStatus.buffering);

    try {
      // DownloadRequestPayload has no `outputPath` field — the Go backend
      // derives the final path from `outputDir` + `filenameFormat` (+ the
      // extension it detects from the resolved source) and returns the
      // actual path it wrote to in the response's `file_path`.
      final response = await PlatformBridge.downloadByStrategy(
        payload: DownloadRequestPayload(
          isrc: track.isrc ?? '',
          service: track.source ?? '',
          spotifyId: track.id,
          trackName: track.name,
          artistName: track.artistName,
          albumName: track.albumName,
          albumArtist: track.albumArtist ?? '',
          coverUrl: track.coverUrl ?? '',
          outputDir: dir.path,
          filenameFormat: streamCacheFileName(track.id),
          quality: 'LOSSLESS',
          embedMetadata: false,
          embedLyrics: false,
          embedMaxQualityCover: false,
          trackNumber: track.trackNumber ?? 0,
          discNumber: track.discNumber ?? 0,
          totalTracks: track.totalTracks ?? 1,
          releaseDate: track.releaseDate ?? '',
          itemId: track.id,
          durationMs: track.duration * 1000,
          source: track.source ?? '',
        ),
      );

      if (response['success'] != true) {
        throw Exception(response['error'] ?? 'Resolution failed');
      }

      final filePath = response['file_path'] as String?;
      if (filePath == null || filePath.isEmpty) {
        throw Exception('Download succeeded but returned no file_path');
      }
      _activeTempPath = filePath;
      await _playFile(filePath);
    } catch (e) {
      _log.e('Stream resolution failed for "${track.name}"', e);
      state = state.copyWith(
        status: StreamPlaybackStatus.error,
        error: '$e',
      );
    }
  }

  Future<void> _playFile(String path) async {
    final player = _player ??= AudioPlayer(playerId: 'spotify-stream-player');
    _attachListeners(player);
    await player.play(DeviceFileSource(path));
    state = state.copyWith(status: StreamPlaybackStatus.playing);
  }

  void _attachListeners(AudioPlayer player) {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions
      ..clear()
      ..add(
        player.onPlayerComplete.listen((_) {
          state = state.copyWith(status: StreamPlaybackStatus.idle);
        }),
      );
  }

  Future<void> pause() async {
    await _player?.pause();
    state = state.copyWith(status: StreamPlaybackStatus.paused);
  }

  Future<void> resume() async {
    await _player?.resume();
    state = state.copyWith(status: StreamPlaybackStatus.playing);
  }

  Future<void> stop() async {
    await _player?.stop();
    await _cleanupPreviousTempFile();
    state = const StreamPlaybackState();
  }

  Future<void> _cleanupPreviousTempFile() async {
    final path = _activeTempPath;
    _activeTempPath = null;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _discardPlayer() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _player?.dispose();
    _player = null;
  }
}

final spotifyStreamPlayerProvider =
    NotifierProvider<SpotifyStreamPlayerNotifier, StreamPlaybackState>(
      SpotifyStreamPlayerNotifier.new,
    );
```

Before wiring this in, **read `lib/services/download_request_payload.dart` in full** to confirm `DownloadRequestPayload`'s exact constructor field names/types match what's used above (it mirrors the Go `DownloadRequest` struct from `go_backend/exports_download.go`, but field naming on the Dart side may differ slightly, e.g. camelCase vs the struct's JSON tags) — adjust the constructor call to match exactly; do not guess-and-ship a field name mismatch.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/spotify_stream_player_provider_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Manual verification**

Tap a liked song or playlist track in the Spotify library UI (Task 9). Confirm: status shows "resolving"/"buffering" briefly, then audio plays; confirm the main library player (`music_player_provider`) was paused first (mutual exclusion, matching `preview_player_provider`'s behavior); confirm tapping a second track cleans up the first track's temp file (check `<app temp dir>/spotify_stream_cache/` doesn't accumulate).

- [ ] **Step 6: Commit**

```bash
git add lib/providers/spotify_stream_player_provider.dart test/spotify_stream_player_provider_test.dart
git commit -m "feat(spotify): add streaming playback via the existing extension pipeline"
```

---

### Task 11: Full end-to-end manual verification pass

**Files:** none (verification only).

- [ ] **Step 1:** Fresh install (`flutter clean && flutter pub get`), build with your real client ID: `flutter build apk --debug --dart-define=SPOTIFY_CLIENT_ID=<your_client_id>`.
- [ ] **Step 2:** In your Spotify Developer Dashboard app settings, add `spotiflac://spotify-login-callback` as a Redirect URI (required by Spotify or the authorize call will be rejected).
- [ ] **Step 3:** Install and open the app. Settings → Spotify Account → Connect Spotify. Complete login in the browser. Confirm you land back in the app as "Connected to Spotify".
- [ ] **Step 4:** Browse your library — confirm real playlists, liked songs, and followed artists appear (not placeholder data).
- [ ] **Step 5:** Tap a liked song. Confirm it resolves through your existing enabled extensions/provider-priority and plays audio.
- [ ] **Step 6:** Kill and reopen the app. Confirm you're still logged in (tokens persisted) without re-authenticating.
- [ ] **Step 7:** Disconnect via Settings, confirm you're logged out and stored tokens are cleared (re-tapping Connect should require a fresh browser login, not a silent reuse of the old session).
- [ ] **Step 8:** Run the full test suite: `flutter test`. Expected: all new tests plus the existing suite pass.
- [ ] **Step 9: Commit** (only if Step 3-8 surfaced fixes)

```bash
git add -A
git commit -m "fix(spotify): address issues found in end-to-end verification"
```

---

## Self-Review Notes

- **Spec coverage**: auth (Tasks 3-6), library sync (Tasks 7-9), streaming (Task 10) all covered. The design spec's "no Go backend changes" constraint is honored throughout — every new file is Dart or the two small native additions in Task 3. The "no client secret stored" constraint is enforced in Task 4's `buildTokenExchangeBody` test.
- **Deviation from the spec worth flagging**: the spec's Phase 1 section originally used softer language ("starts playback once buffered, continues reading as it grows") suggesting byte-range progressive streaming. Task 10 implements the more honest, currently-buildable version — full resolve-then-autoplay — because the Go backend's `DownloadRequest`/`DownloadResponse` contract has no partial-file signal to build true progressive playback on top of without renegotiating that contract with every extension author (which the spec explicitly ruled out). True progressive playback remains a fast-follow, not silently dropped — call this out to the user.
- **Type consistency check**: `Track`, `SpotifyApiTrack`, `SpotifyAuthTokens`, `SpotifyPlaylistSummary` field names are used identically across every task that references them (verified by re-reading Tasks 7-10 against Task 2/7/8's original definitions).
