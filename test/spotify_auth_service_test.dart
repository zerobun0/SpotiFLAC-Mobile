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
