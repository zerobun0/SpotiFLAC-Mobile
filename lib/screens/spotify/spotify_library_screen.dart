import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/spotify_library_provider.dart';
import 'package:spotiflac_android/screens/spotify/spotify_playlist_detail_screen.dart';
import 'package:spotiflac_android/utils/spotify_track_mapper.dart';
import 'package:spotiflac_android/providers/spotify_stream_player_provider.dart';

class SpotifyLibraryScreen extends ConsumerStatefulWidget {
  const SpotifyLibraryScreen({super.key});

  @override
  ConsumerState<SpotifyLibraryScreen> createState() =>
      _SpotifyLibraryScreenState();
}

class _SpotifyLibraryScreenState extends ConsumerState<SpotifyLibraryScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(spotifyLibraryProvider.notifier).syncAll(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(spotifyLibraryProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Your Spotify Library'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Playlists'),
              Tab(text: 'Liked Songs'),
              Tab(text: 'Following'),
            ],
          ),
        ),
        body: library.isLoading
            ? const Center(child: CircularProgressIndicator())
            : library.error != null
            ? Center(child: Text(library.error!))
            : TabBarView(
                children: [
                  ListView.builder(
                    itemCount: library.playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = library.playlists[index];
                      return ListTile(
                        leading: playlist.imageUrl != null
                            ? Image.network(playlist.imageUrl!, width: 48)
                            : const Icon(Icons.queue_music),
                        title: Text(playlist.name),
                        subtitle: Text('${playlist.trackCount} tracks · ${playlist.ownerName}'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SpotifyPlaylistDetailScreen(
                              playlistId: playlist.id,
                              playlistName: playlist.name,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  ListView.builder(
                    itemCount: library.likedTracks.length,
                    itemBuilder: (context, index) {
                      final liked = library.likedTracks[index];
                      return ListTile(
                        title: Text(liked.track.name),
                        subtitle: Text(liked.track.artistNames),
                        onTap: () => ref
                            .read(spotifyStreamPlayerProvider.notifier)
                            .streamTrack(spotifyApiTrackToTrack(liked.track)),
                      );
                    },
                  ),
                  ListView.builder(
                    itemCount: library.followedArtists.length,
                    itemBuilder: (context, index) {
                      final artist = library.followedArtists[index];
                      return ListTile(
                        leading: artist.imageUrl != null
                            ? Image.network(artist.imageUrl!, width: 48)
                            : const Icon(Icons.person),
                        title: Text(artist.name),
                      );
                    },
                  ),
                ],
              ),
      ),
    );
  }
}
