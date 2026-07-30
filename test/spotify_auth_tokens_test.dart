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
