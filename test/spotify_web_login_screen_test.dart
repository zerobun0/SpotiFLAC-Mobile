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

  group('isSpotifyWebPlayerUrl', () {
    test('matches the real logged-in web player', () {
      expect(isSpotifyWebPlayerUrl('https://open.spotify.com/'), isTrue);
      expect(
        isSpotifyWebPlayerUrl('https://open.spotify.com/collection/tracks'),
        isTrue,
      );
    });

    test('rejects a lookalike host that merely starts with the prefix', () {
      // The old `url.startsWith('https://open.spotify.com')` check accepted
      // this, which would have leaked a cookie read to an attacker origin.
      expect(
        isSpotifyWebPlayerUrl('https://open.spotify.com.evil.com/'),
        isFalse,
      );
      expect(
        isSpotifyWebPlayerUrl('https://open.spotify.com.evil.com/collection'),
        isFalse,
      );
    });

    test('rejects unrelated hosts and the login page itself', () {
      expect(
        isSpotifyWebPlayerUrl('https://accounts.spotify.com/login'),
        isFalse,
      );
      expect(isSpotifyWebPlayerUrl('https://example.com'), isFalse);
      expect(isSpotifyWebPlayerUrl('not a url at all'), isFalse);
    });
  });
}
