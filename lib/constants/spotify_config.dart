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
