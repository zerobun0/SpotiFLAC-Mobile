import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/models/spotify_library_models.dart';
import 'package:spotiflac_android/providers/spotify_auth_provider.dart';
import 'package:spotiflac_android/services/spotify_library_service.dart';
import 'package:spotiflac_android/utils/spotify_track_mapper.dart';
import 'package:spotiflac_android/providers/spotify_stream_player_provider.dart';

class SpotifyPlaylistDetailScreen extends ConsumerStatefulWidget {
  final String playlistId;
  final String playlistName;

  const SpotifyPlaylistDetailScreen({
    super.key,
    required this.playlistId,
    required this.playlistName,
  });

  @override
  ConsumerState<SpotifyPlaylistDetailScreen> createState() =>
      _SpotifyPlaylistDetailScreenState();
}

class _SpotifyPlaylistDetailScreenState
    extends ConsumerState<SpotifyPlaylistDetailScreen> {
  List<SpotifyApiTrack> _tracks = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = SpotifyLibraryService(
      getAccessToken: () =>
          ref.read(spotifyAuthProvider.notifier).accessToken(),
    );
    try {
      final all = <SpotifyApiTrack>[];
      final seenUrls = <String>{};
      String? nextUrl;
      do {
        final page = await service.getPlaylistTracks(
          widget.playlistId,
          pageUrl: nextUrl,
        );
        all.addAll(page.items);
        nextUrl = page.nextUrl;
        if (nextUrl != null && !seenUrls.add(nextUrl)) {
          break;
        }
      } while (nextUrl != null);
      setState(() {
        _tracks = all;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlistName)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : ListView.builder(
              itemCount: _tracks.length,
              itemBuilder: (context, index) {
                final track = _tracks[index];
                return ListTile(
                  title: Text(track.name),
                  subtitle: Text(track.artistNames),
                  onTap: () => ref
                      .read(spotifyStreamPlayerProvider.notifier)
                      .streamTrack(spotifyApiTrackToTrack(track)),
                );
              },
            ),
    );
  }
}
