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
