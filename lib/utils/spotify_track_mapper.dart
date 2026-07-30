import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/models/track.dart';

/// Marks tracks that came from the user's own Spotify library sync, as
/// opposed to `source` values naming a resolving extension (e.g. `deezer`).
/// [stream_resolution_service] (Task 10) uses this to know a track has no
/// resolved audio source yet and must go through provider-priority resolution.
const spotifyLibrarySourceId = 'spotify-library';

Track spotifyApiTrackToTrack(SpotifyApiTrack apiTrack) {
  return Track(
    id: apiTrack.id,
    name: apiTrack.name,
    artistName: apiTrack.artistNames,
    albumName: apiTrack.albumName,
    coverUrl: apiTrack.albumImageUrl,
    isrc: apiTrack.isrc,
    duration: (apiTrack.durationMs / 1000).round(),
    source: spotifyLibrarySourceId,
  );
}
