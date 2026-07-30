import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';

void main() {
  group('parsePlaylistsPage', () {
    test('parses items and next url', () {
      final page = parsePlaylistsPage({
        'items': [
          {
            'id': 'pl1',
            'name': 'My Playlist',
            'owner': {'display_name': 'Alice'},
            'tracks': {'total': 12},
            'images': [
              {'url': 'https://img/1.jpg'},
            ],
          },
        ],
        'next': 'https://api.spotify.com/v1/me/playlists?offset=50',
      });

      expect(page.items, hasLength(1));
      expect(page.items.first.id, 'pl1');
      expect(page.items.first.name, 'My Playlist');
      expect(page.items.first.ownerName, 'Alice');
      expect(page.items.first.trackCount, 12);
      expect(page.items.first.imageUrl, 'https://img/1.jpg');
      expect(page.nextUrl, 'https://api.spotify.com/v1/me/playlists?offset=50');
    });

    test('handles a playlist with no images', () {
      final page = parsePlaylistsPage({
        'items': [
          {
            'id': 'pl2',
            'name': 'Empty Art',
            'owner': {'display_name': 'Bob'},
            'tracks': {'total': 0},
            'images': <Map<String, String>>[],
          },
        ],
        'next': null,
      });
      expect(page.items.first.imageUrl, isNull);
      expect(page.nextUrl, isNull);
    });
  });

  group('SpotifyApiTrack.fromJson', () {
    test('joins multiple artist names and reads ISRC from external_ids', () {
      final track = SpotifyApiTrack.fromJson({
        'id': 'tr1',
        'name': 'Song Name',
        'artists': [
          {'name': 'Artist A'},
          {'name': 'Artist B'},
        ],
        'album': {
          'name': 'Album Name',
          'images': [
            {'url': 'https://img/album.jpg'},
          ],
        },
        'external_ids': {'isrc': 'US1234567890'},
        'duration_ms': 210000,
      });

      expect(track.artistNames, 'Artist A, Artist B');
      expect(track.albumName, 'Album Name');
      expect(track.albumImageUrl, 'https://img/album.jpg');
      expect(track.isrc, 'US1234567890');
      expect(track.durationMs, 210000);
    });
  });

  group('parseLikedTracksPage', () {
    test('unwraps the {added_at, track} envelope', () {
      final page = parseLikedTracksPage({
        'items': [
          {
            'added_at': '2026-01-01T00:00:00Z',
            'track': {
              'id': 'tr1',
              'name': 'Liked Song',
              'artists': [
                {'name': 'Someone'},
              ],
              'album': {'name': 'An Album', 'images': <Map<String, String>>[]},
              'external_ids': <String, String>{},
              'duration_ms': 180000,
            },
          },
        ],
        'next': null,
      });
      expect(page.items, hasLength(1));
      expect(page.items.first.addedAt, '2026-01-01T00:00:00Z');
      expect(page.items.first.track.name, 'Liked Song');
    });
  });

  group('parsePlaylistTracksPage', () {
    test('parses a normal item and skips removed/local tracks', () {
      final page = parsePlaylistTracksPage({
        'items': [
          {
            'track': {
              'id': 'tr1',
              'name': 'Real Song',
              'artists': [
                {'name': 'Artist A'},
              ],
              'album': {
                'name': 'Album',
                'images': <Map<String, String>>[],
              },
              'external_ids': <String, String>{},
              'duration_ms': 200000,
            },
          },
          // A track removed from Spotify's catalog: "track" itself is null.
          {'track': null},
          // A local (non-Spotify) file added to the playlist: "track" is
          // present but its id is null.
          {
            'track': {
              'id': null,
              'name': 'Local File.mp3',
              'artists': <Map<String, dynamic>>[],
              'album': {'name': '', 'images': <Map<String, String>>[]},
              'external_ids': <String, String>{},
              'duration_ms': 0,
            },
          },
        ],
        'next': null,
      });

      expect(page.items, hasLength(1));
      expect(page.items.first.id, 'tr1');
      expect(page.items.first.name, 'Real Song');
      expect(page.nextUrl, isNull);
    });

    test('handles an empty items list', () {
      final page = parsePlaylistTracksPage({'items': <dynamic>[], 'next': null});
      expect(page.items, isEmpty);
    });
  });
}
