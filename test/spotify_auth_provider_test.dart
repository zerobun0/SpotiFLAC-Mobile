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
