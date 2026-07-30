import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/providers/spotify_library_provider.dart';

SpotifyLikedTrack _track(String id) => SpotifyLikedTrack(
  addedAt: '2026-01-01T00:00:00Z',
  track: SpotifyApiTrack(
    id: id,
    name: 'Track $id',
    artistNames: 'Artist',
    albumName: 'Album',
    albumImageUrl: null,
    isrc: null,
    durationMs: 180000,
  ),
);

void main() {
  group('appendLikedTracksPage', () {
    test('appends a page onto an empty accumulation', () {
      const acc = LikedTracksAccumulation(items: [], seenUrls: {});
      final page = SpotifyPage<SpotifyLikedTrack>(
        items: [_track('1'), _track('2')],
        nextUrl: 'https://api.spotify.com/v1/me/tracks?offset=50',
      );

      final result = appendLikedTracksPage(acc, page)!;

      expect(result.items, hasLength(2));
      expect(result.seenUrls, contains('https://api.spotify.com/v1/me/tracks?offset=50'));
    });

    test('appends onto an existing accumulation without dropping prior items', () {
      final acc = LikedTracksAccumulation(items: [_track('1')], seenUrls: {});
      final page = SpotifyPage<SpotifyLikedTrack>(items: [_track('2')], nextUrl: null);

      final result = appendLikedTracksPage(acc, page)!;

      expect(result.items.map((t) => t.track.id), ['1', '2']);
    });

    test('returns null when nextUrl repeats an already-seen URL', () {
      const acc = LikedTracksAccumulation(
        items: [],
        seenUrls: {'https://api.spotify.com/v1/me/tracks?offset=50'},
      );
      final page = SpotifyPage<SpotifyLikedTrack>(
        items: [_track('1')],
        nextUrl: 'https://api.spotify.com/v1/me/tracks?offset=50',
      );

      expect(appendLikedTracksPage(acc, page), isNull);
    });
  });
}
