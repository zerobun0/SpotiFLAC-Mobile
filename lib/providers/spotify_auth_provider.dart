import 'dart:async';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:spotiflac_android/constants/spotify_config.dart';
import 'package:spotiflac_android/services/spotify_auth_service.dart';
import 'package:spotiflac_android/services/spotify_pkce.dart';
import 'package:spotiflac_android/services/spotify_web_session.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyAuth');

enum SpotifyAuthStatus { unknown, loggedOut, loggingIn, loggedIn }

/// True when a Spotify login attempt is already in flight for [status].
///
/// [SpotifyAuthNotifier.login] uses this to reject re-entrant/concurrent
/// calls (e.g. a double-tap on "Connect Spotify" before the UI disables the
/// button). Without this guard, a second call would overwrite the first
/// call's pending PKCE verifier/OAuth `state`/callback `Completer` while the
/// first call's `await` is still bound to its own now-orphaned `Completer`;
/// when that first call's 5-minute timeout eventually fires, it would
/// unconditionally revert `state` to a "Login timed out" error even if the
/// second attempt already completed a real, successful login.
bool isSpotifyLoginInFlight(SpotifyAuthStatus status) =>
    status == SpotifyAuthStatus.loggingIn;

/// True when a login has been [isLoginInFlight] for longer than
/// [graceWindow] since the app resumed from the background. Used by
/// [SpotifyAuthNotifier] to escape a stuck `loggingIn` state when the user
/// backs out of the browser without completing login — without this, the
/// only escape is the 5-minute overall login timeout.
bool shouldResetStuckLogin({
  required bool isLoginInFlight,
  required Duration timeSinceResume,
  required Duration graceWindow,
}) {
  return isLoginInFlight && timeSinceResume >= graceWindow;
}

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

class SpotifyAuthNotifier extends Notifier<SpotifyAuthState>
    with WidgetsBindingObserver {
  static const _stuckLoginGraceWindow = Duration(seconds: 2);

  final SpotifyAuthService _service = SpotifyAuthService();
  StreamSubscription<Map<String, dynamic>>? _callbackSubscription;
  Completer<Map<String, dynamic>>? _pendingLogin;
  String? _pendingState;
  SpotifyPkcePair? _pendingPkce;
  DateTime? _resumedAt;

  @override
  SpotifyAuthState build() {
    _callbackSubscription = PlatformBridge.spotifyLoginCallbackEvents().listen(
      _handleCallback,
    );
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _callbackSubscription?.cancel();
      WidgetsBinding.instance.removeObserver(this);
    });
    unawaited(_loadInitialStatus());
    return const SpotifyAuthState();
  }

  // Deliberately not named `state`: that would shadow the Notifier's own
  // `state` field for the rest of this method (including the nested
  // closure below), which relies on unshadowed access to read/assign it.
  @override
  // ignore: avoid_renaming_method_parameters
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState != AppLifecycleState.resumed) return;
    _resumedAt = DateTime.now();
    Future.delayed(_stuckLoginGraceWindow, () {
      final resumedAt = _resumedAt;
      if (resumedAt == null) return;
      final timeSinceResume = DateTime.now().difference(resumedAt);
      if (shouldResetStuckLogin(
        isLoginInFlight: isSpotifyLoginInFlight(state.status),
        timeSinceResume: timeSinceResume,
        graceWindow: _stuckLoginGraceWindow,
      )) {
        _log.w('Spotify login stuck after resume; resetting to loggedOut');
        // Resolve the abandoned Completer *before* nulling it out, so
        // the original login() coroutine's own `await ...timeout(...)`
        // unblocks immediately and runs its normal cancelled-path
        // (the `error != null` branch) instead of sitting suspended
        // for up to 5 more minutes on its own independent timeout —
        // which would otherwise fire later and unconditionally log
        // the user out even if a subsequent login attempt succeeded
        // in the meantime. Guarded the same way _handleCallback guards
        // against completing an already-completed Completer.
        final pending = _pendingLogin;
        if (pending != null && !pending.isCompleted) {
          pending.complete({'error': 'cancelled'});
        }
        _pendingLogin = null;
        _pendingState = null;
        _pendingPkce = null;
        state = state.copyWith(
          status: SpotifyAuthStatus.loggedOut,
          error: 'Login was cancelled',
        );
      }
    });
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
    if (isSpotifyLoginInFlight(state.status)) return;

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

  /// Clears stored tokens and reverts to [SpotifyAuthStatus.loggedOut].
  ///
  /// [error], when set, surfaces why the session ended — e.g. a caller that
  /// caught a [SpotifyAuthException] from a failed token refresh (the user
  /// revoked access on Spotify's side) passes a "please reconnect" message
  /// so the UI doesn't keep claiming "Connected to Spotify" while every
  /// actual API call is failing.
  ///
  /// Also revokes the separately-captured `sp_dc` web session cookie and the
  /// WebView cookie jar behind it: that credential is a real user session
  /// too, so leaving it on-device after a logout would keep the personalized
  /// home feed authenticated as an account the user just disconnected.
  Future<void> logout({String? error}) async {
    await _service.clearStoredTokens();
    await clearSpotifyWebSession();
    state = SpotifyAuthState(status: SpotifyAuthStatus.loggedOut, error: error);
  }

  /// Used by the library/streaming services before every Spotify Web API call.
  Future<String> accessToken() => _service.ensureFreshAccessToken();
}

final spotifyAuthProvider =
    NotifierProvider<SpotifyAuthNotifier, SpotifyAuthState>(
      SpotifyAuthNotifier.new,
    );
