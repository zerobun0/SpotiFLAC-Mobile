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
