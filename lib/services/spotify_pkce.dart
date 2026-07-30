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
