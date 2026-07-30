import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:spotiflac_android/constants/spotify_config.dart';
import 'package:spotiflac_android/services/spotify_auth_service.dart';
import 'package:spotiflac_android/services/spotify_pkce.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyAuth');

enum SpotifyAuthStatus { unknown, loggedOut, loggingIn, loggedIn }

class SpotifyAuthState {
  final SpotifyAuthStatus status;
  final String? error;

  const SpotifyAuthState({
    this.status = SpotifyAuthStatus.unknown,
    this.error,
  });

  SpotifyAuthState copyWith({
    SpotifyAuthStatus? status,
    String? error,
    bool clearError = false,
  }) {
    return SpotifyAuthState(
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SpotifyAuthNotifier extends Notifier<SpotifyAuthState> {
  final SpotifyAuthService _service = SpotifyAuthService();
  StreamSubscription<Map<String, dynamic>>? _callbackSubscription;
  Completer<Map<String, dynamic>>? _pendingLogin;
  String? _pendingState;
  SpotifyPkcePair? _pendingPkce;

  @override
  SpotifyAuthState build() {
    _callbackSubscription = PlatformBridge.spotifyLoginCallbackEvents().listen(
      _handleCallback,
    );
    ref.onDispose(() => _callbackSubscription?.cancel());
    unawaited(_loadInitialStatus());
    return const SpotifyAuthState();
  }

  Future<void> _loadInitialStatus() async {
    final tokens = await _service.loadStoredTokens();
    state = state.copyWith(
      status: tokens != null
          ? SpotifyAuthStatus.loggedIn
          : SpotifyAuthStatus.loggedOut,
    );
  }

  void _handleCallback(Map<String, dynamic> args) {
    final pending = _pendingLogin;
    if (pending == null || pending.isCompleted) return;
    if (args['state'] != _pendingState) {
      _log.w('Ignoring Spotify callback with mismatched state');
      return;
    }
    pending.complete(args);
  }

  Future<void> login() async {
    if (SpotifyConfig.clientId.isEmpty) {
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedOut,
        error: 'SpotifyConfig.clientId is not set',
      );
      return;
    }

    state = state.copyWith(
      status: SpotifyAuthStatus.loggingIn,
      clearError: true,
    );

    final pkce = generateSpotifyPkcePair();
    final oauthState = DateTime.now().microsecondsSinceEpoch.toString();
    _pendingPkce = pkce;
    _pendingState = oauthState;
    _pendingLogin = Completer<Map<String, dynamic>>();

    final authorizeUrl = buildSpotifyAuthorizeUrl(
      clientId: SpotifyConfig.clientId,
      redirectUri: SpotifyConfig.redirectUri,
      codeChallenge: pkce.challenge,
      scopes: SpotifyConfig.scopes,
      state: oauthState,
    );

    final launched = await launchUrl(
      Uri.parse(authorizeUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedOut,
        error: 'Could not open the browser for Spotify login',
      );
      return;
    }

    try {
      final result = await _pendingLogin!.future.timeout(
        const Duration(minutes: 5),
      );
      final error = result['error'] as String?;
      final code = result['code'] as String?;
      if (error != null || code == null) {
        state = state.copyWith(
          status: SpotifyAuthStatus.loggedOut,
          error: error ?? 'Login was cancelled',
        );
        return;
      }
      await _service.exchangeCodeForTokens(
        code: code,
        verifier: _pendingPkce!.verifier,
      );
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedIn,
        clearError: true,
      );
    } on TimeoutException {
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedOut,
        error: 'Login timed out',
      );
    } catch (e) {
      _log.e('Spotify login failed', e);
      state = state.copyWith(
        status: SpotifyAuthStatus.loggedOut,
        error: 'Login failed: $e',
      );
    } finally {
      _pendingLogin = null;
      _pendingState = null;
      _pendingPkce = null;
    }
  }

  Future<void> logout() async {
    await _service.clearStoredTokens();
    state = const SpotifyAuthState(status: SpotifyAuthStatus.loggedOut);
  }

  /// Used by the library/streaming services before every Spotify Web API call.
  Future<String> accessToken() => _service.ensureFreshAccessToken();
}

final spotifyAuthProvider =
    NotifierProvider<SpotifyAuthNotifier, SpotifyAuthState>(
      SpotifyAuthNotifier.new,
    );
