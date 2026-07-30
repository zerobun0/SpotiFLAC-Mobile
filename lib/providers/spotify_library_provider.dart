import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/providers/spotify_auth_provider.dart';
import 'package:spotiflac_android/services/spotify_auth_service.dart';
import 'package:spotiflac_android/services/spotify_library_service.dart';
import 'package:spotiflac_android/utils/logger.dart';

const _spotifySessionExpiredMessage =
    'Your Spotify session expired — please reconnect.';

final _log = AppLogger('SpotifyLibrary');

class LikedTracksAccumulation {
  final List<SpotifyLikedTrack> items;
  final Set<String> seenUrls;

  const LikedTracksAccumulation({required this.items, required this.seenUrls});
}

/// Pure reducer for incrementally accumulating liked-tracks pages. Returns
/// null when [page.nextUrl] repeats a URL already in [acc.seenUrls] — signals
/// the caller to stop, guarding against a malfunctioning/looping API response
/// that would otherwise keep this fetch running forever.
LikedTracksAccumulation? appendLikedTracksPage(
  LikedTracksAccumulation acc,
  SpotifyPage<SpotifyLikedTrack> page,
) {
  final nextUrl = page.nextUrl;
  if (nextUrl != null && acc.seenUrls.contains(nextUrl)) return null;
  return LikedTracksAccumulation(
    items: [...acc.items, ...page.items],
    seenUrls: nextUrl != null ? {...acc.seenUrls, nextUrl} : acc.seenUrls,
  );
}

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
      final followed = await _collectAllPages(
        (pageUrl) => _service.getFollowedArtists(pageUrl: pageUrl),
      );

      // Liked tracks: yield the first page immediately so the Library tab is
      // interactive right away, then keep fetching subsequent pages in the
      // background instead of blocking syncAll() on the full paginated list —
      // this list is the one most likely to run into the hundreds of items.
      final firstPage = await _service.getLikedTracks();
      state = state.copyWith(
        playlists: playlists,
        followedArtists: followed,
        likedTracks: firstPage.items,
        isLoading: false,
      );
      unawaited(
        _syncRemainingLikedTracks(
          LikedTracksAccumulation(items: firstPage.items, seenUrls: {}),
          firstPage.nextUrl,
        ),
      );
    } catch (e) {
      _log.e('Spotify library sync failed', e);
      if (e is SpotifyAuthException) {
        await ref
            .read(spotifyAuthProvider.notifier)
            .logout(error: _spotifySessionExpiredMessage);
        state = state.copyWith(
          isLoading: false,
          error: _spotifySessionExpiredMessage,
        );
        return;
      }
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<void> _syncRemainingLikedTracks(
    LikedTracksAccumulation acc,
    String? nextUrl,
  ) async {
    var current = acc;
    var url = nextUrl;
    while (url != null) {
      try {
        final page = await _service.getLikedTracks(pageUrl: url);
        final next = appendLikedTracksPage(current, page);
        if (next == null) {
          _log.w('Spotify liked-tracks pagination returned a repeated nextUrl; stopping');
          return;
        }
        current = next;
        state = state.copyWith(likedTracks: current.items);
        url = page.nextUrl;
      } catch (e) {
        _log.w('Background liked-tracks page fetch failed: $e');
        return;
      }
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
