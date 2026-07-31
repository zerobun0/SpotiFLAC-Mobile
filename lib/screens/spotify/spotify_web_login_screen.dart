import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyWebLogin');

const spotifySessionCookieStorageKey = 'spotify_web_session_cookie_v1';

/// Extracts the `sp_dc` cookie (Spotify's long-lived web-player session
/// token — the same cookie community tools like spotify-lyrics-api use for
/// authenticated, non-OAuth access) from a raw `document.cookie` string like
/// `a=1; sp_dc=AQabc123; b=2`.
String? extractSpotifySessionCookie(String rawCookieHeader) {
  for (final part in rawCookieHeader.split(';')) {
    final trimmed = part.trim();
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    if (trimmed.substring(0, eq) == 'sp_dc') {
      return trimmed.substring(eq + 1).trim();
    }
  }
  return null;
}

class SpotifyWebLoginScreen extends StatefulWidget {
  const SpotifyWebLoginScreen({super.key});

  @override
  State<SpotifyWebLoginScreen> createState() => _SpotifyWebLoginScreenState();
}

class _SpotifyWebLoginScreenState extends State<SpotifyWebLoginScreen> {
  late final WebViewController _controller;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: _onPageFinished),
      )
      ..loadRequest(Uri.parse('https://accounts.spotify.com/login'));
  }

  Future<void> _onPageFinished(String url) async {
    if (_capturing) return;
    // A successful login redirects from accounts.spotify.com to the logged-in
    // web player at open.spotify.com — that's the signal to capture cookies.
    if (!url.startsWith('https://open.spotify.com')) return;

    _capturing = true;
    try {
      final rawResult = await _controller.runJavaScriptReturningResult(
        'document.cookie',
      );
      // runJavaScriptReturningResult wraps string results in quotes on some
      // platforms.
      final rawCookieHeader = rawResult.toString().replaceAll('"', '');
      final cookie = extractSpotifySessionCookie(rawCookieHeader);
      if (cookie == null || cookie.isEmpty) {
        _log.w('Reached open.spotify.com but found no sp_dc cookie');
        _capturing = false;
        return;
      }
      await const FlutterSecureStorage().write(
        key: spotifySessionCookieStorageKey,
        value: cookie,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _log.e('Failed to capture Spotify session cookie', e);
      _capturing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log in to Spotify')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
