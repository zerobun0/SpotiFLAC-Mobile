import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:spotiflac_android/models/spotify_library_models.dart';

class SpotifyApiException implements Exception {
  final int statusCode;
  final String body;
  const SpotifyApiException(this.statusCode, this.body);
  @override
  String toString() => 'SpotifyApiException($statusCode): $body';
}

class SpotifyLibraryService {
  final Future<String> Function() _getAccessToken;
  final http.Client _httpClient;

  SpotifyLibraryService({
    required Future<String> Function() getAccessToken,
    http.Client? httpClient,
  }) : _getAccessToken = getAccessToken,
       _httpClient = httpClient ?? http.Client();

  Future<Map<String, dynamic>> _get(String url) async {
    final token = await _getAccessToken();
    final response = await _httpClient.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw SpotifyApiException(response.statusCode, response.body);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<SpotifyPage<SpotifyPlaylistSummary>> getPlaylists({
    String? pageUrl,
  }) async {
    final url =
        pageUrl ?? 'https://api.spotify.com/v1/me/playlists?limit=50';
    return parsePlaylistsPage(await _get(url));
  }

  Future<SpotifyPage<SpotifyLikedTrack>> getLikedTracks({
    String? pageUrl,
  }) async {
    final url = pageUrl ?? 'https://api.spotify.com/v1/me/tracks?limit=50';
    return parseLikedTracksPage(await _get(url));
  }

  Future<SpotifyPage<SpotifyFollowedArtist>> getFollowedArtists({
    String? pageUrl,
  }) async {
    final url =
        pageUrl ?? 'https://api.spotify.com/v1/me/following?type=artist&limit=50';
    return parseFollowedArtistsPage(await _get(url));
  }

  Future<SpotifyPage<SpotifyApiTrack>> getPlaylistTracks(
    String playlistId, {
    String? pageUrl,
  }) async {
    final url =
        pageUrl ??
        'https://api.spotify.com/v1/playlists/$playlistId/tracks?limit=100';
    return parsePlaylistTracksPage(await _get(url));
  }
}
