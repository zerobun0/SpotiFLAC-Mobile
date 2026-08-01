import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:spotiflac_android/constants/spotify_config.dart'
    show spotifySessionCookieStorageKey;
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyWebSession');

/// Revokes the `sp_dc` web session credential captured by
/// `SpotifyWebLoginScreen`.
///
/// This is a *different* credential from the PKCE OAuth tokens
/// `SpotifyAuthService` manages, so disconnecting the account has to clear
/// both: the secure-storage copy the personalized home feed reads, and the
/// WebView's own cookie jar (otherwise re-opening the login screen would
/// silently re-authenticate as the same user, making "disconnect" a no-op).
///
/// Both steps are best-effort — a failure to clear one must not prevent the
/// other, and neither should ever propagate out of a logout path.
Future<void> clearSpotifyWebSession() async {
  try {
    await const FlutterSecureStorage().delete(
      key: spotifySessionCookieStorageKey,
    );
  } catch (e) {
    _log.w('Failed to delete the stored Spotify session cookie: $e');
  }
  try {
    await WebViewCookieManager().clearCookies();
  } catch (e) {
    _log.w('Failed to clear WebView cookies: $e');
  }
}
