import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/providers/spotify_library_provider.dart';

void main() {
  test('copyWith merges playlists/likedTracks/followedArtists independently', () {
    const initial = SpotifyLibraryState();
    final withPlaylists = initial.copyWith(
      playlists: const [
        SpotifyPlaylistSummary(
          id: 'p1',
          name: 'P',
          imageUrl: null,
          trackCount: 1,
          ownerName: 'Me',
        ),
      ],
    );
    expect(withPlaylists.playlists, hasLength(1));
    expect(withPlaylists.likedTracks, isEmpty);

    final withError = withPlaylists.copyWith(
      isLoading: false,
      error: 'network error',
    );
    expect(withError.playlists, hasLength(1)); // unrelated field preserved
    expect(withError.error, 'network error');
  });
}
