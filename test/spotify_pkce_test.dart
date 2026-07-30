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
