import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:spotiflac_android/constants/spotify_config.dart'
    show spotifySessionCookieStorageKey;
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyWebLogin');

/// Host whose `onPageFinished` signals a completed login — a successful
/// sign-in redirects from `accounts.spotify.com` to the logged-in web player.
const _spotifyWebPlayerHost = 'open.spotify.com';
const _spotifyWebPlayerUrl = 'https://open.spotify.com';

/// Extracts the `sp_dc` cookie (Spotify's long-lived web-player session
/// token — the same cookie community tools like spotify-lyrics-api use for
/// authenticated, non-OAuth access) from a raw cookie header string like
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

/// True when a finished page load is the logged-in Spotify web player.
///
/// Compares the parsed *host* rather than doing a `startsWith` on the URL —
/// `https://open.spotify.com.evil.com/` starts with the expected prefix but
/// is a different origin entirely, and must never trigger a cookie read.
bool isSpotifyWebPlayerUrl(String url) {
  return Uri.tryParse(url)?.host == _spotifyWebPlayerHost;
}

class SpotifyWebLoginScreen extends StatefulWidget {
  const SpotifyWebLoginScreen({super.key});

  @override
  State<SpotifyWebLoginScreen> createState() => _SpotifyWebLoginScreenState();
}

class _SpotifyWebLoginScreenState extends State<SpotifyWebLoginScreen> {
  late final WebViewController _controller;
  bool _capturing = false;

  /// Set once the WebView has reached the logged-in web player, so the
  /// manual retry affordance knows a capture is actually meaningful.
  bool _reachedWebPlayer = false;

  /// Last successfully-loaded web-player URL, reused by the manual retry —
  /// `onPageFinished` does not fire again for an already-loaded page, so
  /// without this the user would be stuck staring at a logged-in page that
  /// never pops.
  String _lastWebPlayerUrl = _spotifyWebPlayerUrl;

  String? _captureError;

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
    if (!isSpotifyWebPlayerUrl(url)) return;

    _lastWebPlayerUrl = url;
    if (!_reachedWebPlayer && mounted) {
      setState(() => _reachedWebPlayer = true);
    } else {
      _reachedWebPlayer = true;
    }

    await _captureSessionCookie();
  }

  Future<void> _captureSessionCookie() async {
    if (_capturing) return;
    if (mounted) {
      setState(() {
        _capturing = true;
        _captureError = null;
      });
    } else {
      _capturing = true;
    }

    try {
      // Read the cookie jar through Android's native CookieManager rather
      // than JavaScript's `document.cookie`: Spotify sets `sp_dc` with the
      // HttpOnly flag specifically to hide it from page scripts, so
      // `document.cookie` can never contain it. HttpOnly only restricts JS
      // access — the native platform API still sees it.
      final rawCookieHeader = await PlatformBridge.getWebViewCookie(
        _lastWebPlayerUrl,
      );
      if (rawCookieHeader == null || rawCookieHeader.isEmpty) {
        _failCapture(
          'Could not read the Spotify session cookie from this page. '
          'Make sure you are fully signed in, then try again.',
        );
        return;
      }

      final cookie = extractSpotifySessionCookie(rawCookieHeader);
      if (cookie == null || cookie.isEmpty) {
        _log.w('Reached open.spotify.com but found no sp_dc cookie');
        _failCapture(
          'No Spotify session cookie found. Finish signing in to Spotify '
          'in this window, then tap Retry.',
        );
        return;
      }

      await const FlutterSecureStorage().write(
        key: spotifySessionCookieStorageKey,
        value: cookie,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _log.e('Failed to capture Spotify session cookie', e);
      _failCapture('Failed to capture the Spotify session: $e');
    }
  }

  void _failCapture(String message) {
    if (!mounted) {
      _capturing = false;
      return;
    }
    setState(() {
      _capturing = false;
      _captureError = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log in to Spotify'),
        actions: [
          if (_reachedWebPlayer && !_capturing)
            IconButton(
              tooltip: 'Retry capturing the session',
              icon: const Icon(Icons.refresh),
              onPressed: _captureSessionCookie,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_capturing) const LinearProgressIndicator(minHeight: 2),
          if (_captureError != null)
            Material(
              color: colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _captureError!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _capturing ? null : _captureSessionCookie,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
