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
