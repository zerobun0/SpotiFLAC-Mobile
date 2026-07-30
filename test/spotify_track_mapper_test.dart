import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/utils/spotify_track_mapper.dart';

void main() {
  test('maps a SpotifyApiTrack onto the app Track model', () {
    const apiTrack = SpotifyApiTrack(
      id: 'tr1',
      name: 'Song Name',
      artistNames: 'Artist A, Artist B',
      albumName: 'Album Name',
      albumImageUrl: 'https://img/album.jpg',
      isrc: 'US1234567890',
      durationMs: 210000,
    );

    final track = spotifyApiTrackToTrack(apiTrack);

    expect(track.id, 'tr1');
    expect(track.name, 'Song Name');
    expect(track.artistName, 'Artist A, Artist B');
    expect(track.albumName, 'Album Name');
    expect(track.coverUrl, 'https://img/album.jpg');
    expect(track.isrc, 'US1234567890');
    expect(track.duration, 210); // seconds, not ms
    expect(track.source, 'spotify-library');
  });
}
