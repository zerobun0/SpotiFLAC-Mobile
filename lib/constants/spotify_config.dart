/// Secure-storage key holding the captured `sp_dc` Spotify web session
/// cookie (see `SpotifyWebLoginScreen`).
///
/// Lives here rather than next to the login screen so provider-layer code
/// (`explore_provider.dart`) can read it without importing a screen file —
/// which would drag `webview_flutter` and the widget layer into a provider
/// and invert this codebase's screens-depend-on-providers direction.
const spotifySessionCookieStorageKey = 'spotify_web_session_cookie_v1';

class SpotifyConfig {
  /// Client ID from your app at https://developer.spotify.com/dashboard.
  /// Fill this in with your own app's Client ID before building — it is not
  /// checked in with a real value since it's specific to your Spotify
  /// Developer account's redirect URI registration.
  static const clientId = String.fromEnvironment(
    'SPOTIFY_CLIENT_ID',
    defaultValue: '',
  );

  static const redirectUri = 'spotiflac://spotify-login-callback';

  static const scopes = [
    'playlist-read-private',
    'playlist-read-collaborative',
    'user-library-read',
    'user-follow-read',
    'user-read-email',
  ];
}
