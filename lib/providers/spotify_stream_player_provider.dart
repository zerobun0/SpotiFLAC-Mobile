import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/download_request_payload.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/services/music_player_service.dart'
    show musicPlayerHandler, musicPlayerExclusiveAudioHook;
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyStreamPlayer');

String streamCacheFileName(String trackId) {
  final sanitized = trackId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
  return 'stream_$sanitized';
}

enum StreamPlaybackStatus { idle, resolving, buffering, playing, paused, error }

class StreamPlaybackState {
  final Track? currentTrack;
  final StreamPlaybackStatus status;
  final String? error;

  const StreamPlaybackState({
    this.currentTrack,
    this.status = StreamPlaybackStatus.idle,
    this.error,
  });

  StreamPlaybackState copyWith({
    Track? currentTrack,
    bool clearTrack = false,
    StreamPlaybackStatus? status,
    String? error,
    bool clearError = false,
  }) {
    return StreamPlaybackState(
      currentTrack: clearTrack ? null : (currentTrack ?? this.currentTrack),
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SpotifyStreamPlayerNotifier extends Notifier<StreamPlaybackState> {
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String? _activeTempPath;

  @override
  StreamPlaybackState build() {
    musicPlayerExclusiveAudioHook = () async {
      if (state.status != StreamPlaybackStatus.idle) await stop();
    };
    ref.onDispose(() {
      musicPlayerExclusiveAudioHook = null;
      _discardPlayer();
    });
    return const StreamPlaybackState();
  }

  Future<Directory> _cacheDir() async {
    final tempDir = await getTemporaryDirectory();
    final streamDir = Directory('${tempDir.path}/spotify_stream_cache');
    if (!await streamDir.exists()) {
      await streamDir.create(recursive: true);
    }
    return streamDir;
  }

  Future<void> streamTrack(Track track) async {
    try {
      await musicPlayerHandler?.pause();
    } catch (_) {}

    await _cleanupPreviousTempFile();

    state = StreamPlaybackState(
      currentTrack: track,
      status: StreamPlaybackStatus.resolving,
    );

    final dir = await _cacheDir();

    state = state.copyWith(status: StreamPlaybackStatus.buffering);

    try {
      // DownloadRequestPayload has no `outputPath` field — the Go backend
      // derives the final path from `outputDir` + `filenameFormat` (+ the
      // extension it detects from the resolved source) and returns the
      // actual path it wrote to in the response's `file_path`.
      final response = await PlatformBridge.downloadByStrategy(
        payload: DownloadRequestPayload(
          isrc: track.isrc ?? '',
          service: track.source ?? '',
          spotifyId: track.id,
          trackName: track.name,
          artistName: track.artistName,
          albumName: track.albumName,
          albumArtist: track.albumArtist ?? '',
          coverUrl: track.coverUrl ?? '',
          outputDir: dir.path,
          filenameFormat: streamCacheFileName(track.id),
          quality: 'LOSSLESS',
          embedMetadata: false,
          embedLyrics: false,
          embedMaxQualityCover: false,
          trackNumber: track.trackNumber ?? 0,
          discNumber: track.discNumber ?? 0,
          totalTracks: track.totalTracks ?? 1,
          releaseDate: track.releaseDate ?? '',
          itemId: track.id,
          durationMs: track.duration * 1000,
          source: track.source ?? '',
        ),
      );

      if (response['success'] != true) {
        throw Exception(response['error'] ?? 'Resolution failed');
      }

      final filePath = response['file_path'] as String?;
      if (filePath == null || filePath.isEmpty) {
        throw Exception('Download succeeded but returned no file_path');
      }
      _activeTempPath = filePath;
      await _playFile(filePath);
    } catch (e) {
      _log.e('Stream resolution failed for "${track.name}"', e);
      state = state.copyWith(
        status: StreamPlaybackStatus.error,
        error: '$e',
      );
    }
  }

  Future<void> _playFile(String path) async {
    final player = _player ??= AudioPlayer(playerId: 'spotify-stream-player');
    _attachListeners(player);
    await player.play(DeviceFileSource(path));
    state = state.copyWith(status: StreamPlaybackStatus.playing);
  }

  void _attachListeners(AudioPlayer player) {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions
      ..clear()
      ..add(
        player.onPlayerComplete.listen((_) {
          state = state.copyWith(status: StreamPlaybackStatus.idle);
        }),
      );
  }

  Future<void> pause() async {
    await _player?.pause();
    state = state.copyWith(status: StreamPlaybackStatus.paused);
  }

  Future<void> resume() async {
    await _player?.resume();
    state = state.copyWith(status: StreamPlaybackStatus.playing);
  }

  Future<void> stop() async {
    await _player?.stop();
    await _cleanupPreviousTempFile();
    state = const StreamPlaybackState();
  }

  Future<void> _cleanupPreviousTempFile() async {
    final path = _activeTempPath;
    _activeTempPath = null;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _discardPlayer() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _player?.dispose();
    _player = null;
  }
}

final spotifyStreamPlayerProvider =
    NotifierProvider<SpotifyStreamPlayerNotifier, StreamPlaybackState>(
      SpotifyStreamPlayerNotifier.new,
    );
