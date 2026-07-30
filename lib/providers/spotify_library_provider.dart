import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/providers/spotify_auth_provider.dart';
import 'package:spotiflac_android/services/spotify_library_service.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyLibrary');

class SpotifyLibraryState {
  final List<SpotifyPlaylistSummary> playlists;
  final List<SpotifyLikedTrack> likedTracks;
  final List<SpotifyFollowedArtist> followedArtists;
  final bool isLoading;
  final String? error;

  const SpotifyLibraryState({
    this.playlists = const [],
    this.likedTracks = const [],
    this.followedArtists = const [],
    this.isLoading = false,
    this.error,
  });

  SpotifyLibraryState copyWith({
    List<SpotifyPlaylistSummary>? playlists,
    List<SpotifyLikedTrack>? likedTracks,
    List<SpotifyFollowedArtist>? followedArtists,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return SpotifyLibraryState(
      playlists: playlists ?? this.playlists,
      likedTracks: likedTracks ?? this.likedTracks,
      followedArtists: followedArtists ?? this.followedArtists,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SpotifyLibraryNotifier extends Notifier<SpotifyLibraryState> {
  late final SpotifyLibraryService _service;

  @override
  SpotifyLibraryState build() {
    _service = SpotifyLibraryService(
      getAccessToken: () => ref.read(spotifyAuthProvider.notifier).accessToken(),
    );
    return const SpotifyLibraryState();
  }

  Future<void> syncAll() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final playlists = await _collectAllPages(
        (pageUrl) => _service.getPlaylists(pageUrl: pageUrl),
      );
      final liked = await _collectAllPages(
        (pageUrl) => _service.getLikedTracks(pageUrl: pageUrl),
      );
      final followed = await _collectAllPages(
        (pageUrl) => _service.getFollowedArtists(pageUrl: pageUrl),
      );
      state = state.copyWith(
        playlists: playlists,
        likedTracks: liked,
        followedArtists: followed,
        isLoading: false,
      );
    } catch (e) {
      _log.e('Spotify library sync failed', e);
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<List<T>> _collectAllPages<T>(
    Future<SpotifyPage<T>> Function(String? pageUrl) fetchPage,
  ) async {
    final all = <T>[];
    // Tracks every `nextUrl` already fetched. Defends against a
    // malfunctioning/looping API response repeating a `nextUrl` it already
    // returned, which would otherwise spin this loop forever.
    final seenUrls = <String>{};
    String? nextUrl;
    do {
      final page = await fetchPage(nextUrl);
      all.addAll(page.items);
      nextUrl = page.nextUrl;
      if (nextUrl != null && !seenUrls.add(nextUrl)) {
        _log.w('Spotify pagination returned a repeated nextUrl; stopping');
        break;
      }
    } while (nextUrl != null);
    return all;
  }
}

final spotifyLibraryProvider =
    NotifierProvider<SpotifyLibraryNotifier, SpotifyLibraryState>(
      SpotifyLibraryNotifier.new,
    );
