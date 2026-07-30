// Reads a nested JSON object as Map<String, dynamic>, defaulting to an empty
// map when absent. Uses Map.cast rather than a direct `as Map<String,
// dynamic>?` cast because an *empty* Dart map literal (as used in hand-written
// test fixtures, e.g. `{}`) infers as `Map<dynamic, dynamic>` with no type
// context, which fails that direct cast even though real `jsonDecode` output
// is always `Map<String, dynamic>` regardless of emptiness.
Map<String, dynamic> _asStringMap(dynamic value) {
  if (value is Map) return value.cast<String, dynamic>();
  return const {};
}

class SpotifyPage<T> {
  final List<T> items;
  final String? nextUrl;
  const SpotifyPage({required this.items, this.nextUrl});
}

class SpotifyPlaylistSummary {
  final String id;
  final String name;
  final String? imageUrl;
  final int trackCount;
  final String ownerName;

  const SpotifyPlaylistSummary({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.trackCount,
    required this.ownerName,
  });
}

class SpotifyApiTrack {
  final String id;
  final String name;
  final String artistNames;
  final String albumName;
  final String? albumImageUrl;
  final String? isrc;
  final int durationMs;

  const SpotifyApiTrack({
    required this.id,
    required this.name,
    required this.artistNames,
    required this.albumName,
    required this.albumImageUrl,
    required this.isrc,
    required this.durationMs,
  });

  factory SpotifyApiTrack.fromJson(Map<String, dynamic> json) {
    final artists = (json['artists'] as List? ?? const [])
        .map((a) => (a as Map)['name'] as String)
        .join(', ');
    final album = _asStringMap(json['album']);
    final images = album['images'] as List? ?? const [];
    final externalIds = _asStringMap(json['external_ids']);
    return SpotifyApiTrack(
      id: json['id'] as String,
      name: json['name'] as String,
      artistNames: artists,
      albumName: album['name'] as String? ?? '',
      albumImageUrl: images.isNotEmpty
          ? (images.first as Map)['url'] as String?
          : null,
      isrc: externalIds['isrc'] as String?,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

class SpotifyLikedTrack {
  final String addedAt;
  final SpotifyApiTrack track;
  const SpotifyLikedTrack({required this.addedAt, required this.track});
}

class SpotifyFollowedArtist {
  final String id;
  final String name;
  final String? imageUrl;
  const SpotifyFollowedArtist({
    required this.id,
    required this.name,
    required this.imageUrl,
  });
}

SpotifyPage<SpotifyPlaylistSummary> parsePlaylistsPage(
  Map<String, dynamic> json,
) {
  final items = (json['items'] as List? ?? const [])
      .map((raw) {
        final map = raw as Map<String, dynamic>;
        final images = map['images'] as List? ?? const [];
        final owner = _asStringMap(map['owner']);
        final tracks = _asStringMap(map['tracks']);
        return SpotifyPlaylistSummary(
          id: map['id'] as String,
          name: map['name'] as String,
          imageUrl: images.isNotEmpty
              ? (images.first as Map)['url'] as String?
              : null,
          trackCount: (tracks['total'] as num?)?.toInt() ?? 0,
          ownerName: owner['display_name'] as String? ?? '',
        );
      })
      .toList();
  return SpotifyPage(items: items, nextUrl: json['next'] as String?);
}

SpotifyPage<SpotifyLikedTrack> parseLikedTracksPage(
  Map<String, dynamic> json,
) {
  final items = (json['items'] as List? ?? const [])
      .map(
        (raw) => SpotifyLikedTrack(
          addedAt: (raw as Map<String, dynamic>)['added_at'] as String,
          track: SpotifyApiTrack.fromJson(
            raw['track'] as Map<String, dynamic>,
          ),
        ),
      )
      .toList();
  return SpotifyPage(items: items, nextUrl: json['next'] as String?);
}

SpotifyPage<SpotifyFollowedArtist> parseFollowedArtistsPage(
  Map<String, dynamic> json,
) {
  final artistsBlock = json['artists'] is Map
      ? _asStringMap(json['artists'])
      : json;
  final items = (artistsBlock['items'] as List? ?? const [])
      .map((raw) {
        final map = raw as Map<String, dynamic>;
        final images = map['images'] as List? ?? const [];
        return SpotifyFollowedArtist(
          id: map['id'] as String,
          name: map['name'] as String,
          imageUrl: images.isNotEmpty
              ? (images.first as Map)['url'] as String?
              : null,
        );
      })
      .toList();
  return SpotifyPage(items: items, nextUrl: artistsBlock['next'] as String?);
}
