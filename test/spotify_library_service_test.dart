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
