import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/download_request_payload.dart';
import 'package:spotiflac_android/services/music_player_service.dart' show PlayableMedia;
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotifyStreamPlayer');

/// Streaming plays back as soon as a track resolves, so it defaults to a
/// fast/lossy tier rather than Download's full-LOSSLESS tier — "stream" means
/// fast-start here, not archival quality. Use the app's existing explicit
/// "Download" action (unchanged, still LOSSLESS-capable) for full quality.
const spotifyStreamQuality = 'HIGH';

String streamCacheFileName(String trackId) {
  final sanitized = trackId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
  return 'stream_$sanitized';
}

/// True when [requestedTrackId] is already being resolved by an in-flight
/// `streamTrack` call. Extracted as a pure predicate so the re-entrancy guard
/// can be exercised in a plain unit test without a widget/mocking harness.
/// A call for a *different* track while one is in flight is not a duplicate
/// — it legitimately supersedes the in-flight one.
bool isDuplicateStreamRequest(String? inFlightTrackId, String requestedTrackId) {
  return inFlightTrackId != null && inFlightTrackId == requestedTrackId;
}

/// True when [requestGeneration] is no longer the latest request —
/// [SpotifyStreamPlayerNotifier] increments a counter on every `streamTrack`
/// call; a resolution completing under an older generation means a newer tap
/// has already superseded it and must not hand its result off to the player.
bool isStaleStreamRequest({
  required int currentGeneration,
  required int requestGeneration,
}) {
  return requestGeneration != currentGeneration;
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
  int _requestGeneration = 0;

  @override
  StreamPlaybackState build() => const StreamPlaybackState();

  Future<Directory> _cacheDir() async {
    final tempDir = await getTemporaryDirectory();
    final streamDir = Directory('${tempDir.path}/spotify_stream_cache');
    if (!await streamDir.exists()) {
      await streamDir.create(recursive: true);
    }
    return streamDir;
  }

  /// Deletes any file in the cache dir whose name is exactly the
  /// deterministic prefix for [trackId], or that prefix followed by a `.ext`
  /// suffix — not an unguarded startsWith, which could match a different
  /// track id that happens to be a literal prefix of this one.
  Future<void> _cleanupStaleFilesForTrack(String trackId) async {
    try {
      final dir = await _cacheDir();
      final prefix = streamCacheFileName(trackId);
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final segments = entity.uri.pathSegments;
        final name = segments.isNotEmpty ? segments.last : entity.path;
        if (name == prefix || name.startsWith('$prefix.')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> streamTrack(Track track) async {
    final generation = ++_requestGeneration;

    await _cleanupStaleFilesForTrack(track.id);

    state = StreamPlaybackState(
      currentTrack: track,
      status: StreamPlaybackStatus.resolving,
    );

    final settings = ref.read(settingsProvider);
    final extensionState = ref.read(extensionProvider);
    final hasActiveExtensions = extensionState.extensions.any((e) => e.enabled);
    final useExtensions = settings.useExtensionProviders && hasActiveExtensions;
    final useFallback = settings.autoFallback;

    if (!useExtensions) {
      if (isStaleStreamRequest(currentGeneration: _requestGeneration, requestGeneration: generation)) {
        return;
      }
      state = state.copyWith(
        status: StreamPlaybackStatus.error,
        error:
            'Streaming requires at least one enabled extension provider. '
            'Enable one in Settings > Extensions to stream tracks.',
      );
      return;
    }

    final dir = await _cacheDir();
    state = state.copyWith(status: StreamPlaybackStatus.buffering);

    try {
      final response = await PlatformBridge.downloadByStrategy(
        payload: DownloadRequestPayload(
          isrc: track.isrc ?? '',
          service: '',
          spotifyId: track.id,
          trackName: track.name,
          artistName: track.artistName,
          albumName: track.albumName,
          albumArtist: track.albumArtist ?? '',
          coverUrl: track.coverUrl ?? '',
          outputDir: dir.path,
          filenameFormat: streamCacheFileName(track.id),
          quality: spotifyStreamQuality,
          embedMetadata: false,
          embedLyrics: false,
          embedMaxQualityCover: false,
          trackNumber: track.trackNumber ?? 0,
          discNumber: track.discNumber ?? 0,
          totalTracks: track.totalTracks ?? 1,
          releaseDate: track.releaseDate ?? '',
          itemId: track.id,
          durationMs: track.duration * 1000,
          source: '',
        ),
        useExtensions: useExtensions,
        useFallback: useFallback,
      );

      if (isStaleStreamRequest(currentGeneration: _requestGeneration, requestGeneration: generation)) {
        // A newer tap superseded this one while it was resolving; drop the
        // result instead of handing a stale file off to the player.
        final filePath = response['file_path'] as String?;
        if (filePath != null && filePath.isNotEmpty) {
          unawaited(_deleteFile(filePath));
        }
        return;
      }

      if (response['success'] != true) {
        throw Exception(response['error'] ?? 'Resolution failed');
      }

      final filePath = response['file_path'] as String?;
      if (filePath == null || filePath.isEmpty) {
        throw Exception('Download succeeded but returned no file_path');
      }

      state = state.copyWith(status: StreamPlaybackStatus.playing);
      await ref.read(musicPlayerControllerProvider).playSingle(
        PlayableMedia(
          id: 'spotify-stream-${track.id}',
          source: filePath,
          title: track.name,
          artist: track.artistName,
          album: track.albumName,
          artUri: track.coverUrl,
          duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
        ),
      );
    } catch (e) {
      if (isStaleStreamRequest(currentGeneration: _requestGeneration, requestGeneration: generation)) {
        return;
      }
      _log.e('Stream resolution failed for "${track.name}"', e);
      await _cleanupStaleFilesForTrack(track.id);
      state = state.copyWith(status: StreamPlaybackStatus.error, error: '$e');
    }
  }

  Future<void> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

final spotifyStreamPlayerProvider =
    NotifierProvider<SpotifyStreamPlayerNotifier, StreamPlaybackState>(
      SpotifyStreamPlayerNotifier.new,
    );
