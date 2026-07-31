import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/download_request_payload.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/services/music_player_service.dart'
    show
        musicPlayerHandler,
        registerExclusiveAudioHook,
        stopOtherExclusiveAudio,
        unregisterExclusiveAudioHook;
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
  Future<void> Function()? _exclusiveHook;
  // Track id whose streamTrack() call is currently in flight (downloading
  // and about to play). Guards against a double-tap on the same track
  // starting a second downloadByStrategy call against the identical
  // outputDir/filenameFormat path while the first is still writing to it —
  // whose stale-file cleanup could then delete the file the first call is
  // actively writing. A call for a *different* track is not blocked; it
  // legitimately supersedes the in-flight one.
  String? _inFlightTrackId;

  @override
  StreamPlaybackState build() {
    // Registered/unregistered independently of any other owner (e.g. the
    // main preview player) via the shared multi-subscriber registry in
    // music_player_service.dart — no single-slot clobbering regardless of
    // build/dispose order between providers.
    Future<void> exclusiveHook() async {
      if (state.status != StreamPlaybackStatus.idle) await stop();
    }

    _exclusiveHook = exclusiveHook;
    registerExclusiveAudioHook(exclusiveHook);
    ref.onDispose(() {
      unregisterExclusiveAudioHook(exclusiveHook);
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

  /// Deletes any file in the cache dir whose name is exactly the
  /// deterministic prefix for [trackId], or that prefix followed by a `.ext`
  /// suffix, regardless of the extension the backend chose. Used to clean up
  /// orphaned partial/temp files from failed or in-progress downloads, since
  /// `_activeTempPath` only ever tracks the single most recent *successful*
  /// download's path, not the cache dir's real contents.
  ///
  /// Deliberately NOT an unguarded `name.startsWith(prefix)`: two different
  /// track ids can sanitize to strings where one is a literal prefix of the
  /// other (e.g. ids "123" and "1234" from a source with variable-length
  /// numeric ids), which would let this delete a *different* track's cache
  /// file. Requiring an exact match, or a match immediately followed by a
  /// `.` extension separator, rules that out.
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
    if (isDuplicateStreamRequest(_inFlightTrackId, track.id)) {
      _log.d(
        'Ignoring duplicate streamTrack call for in-flight track ${track.id}',
      );
      return;
    }
    _inFlightTrackId = track.id;

    try {
      try {
        await musicPlayerHandler?.pause();
      } catch (_) {}

      // Stop the sibling secondary player (e.g. a search-result preview)
      // too — musicPlayerHandler?.pause() above only reaches the MAIN
      // player; the two secondary players are otherwise never told about
      // each other and could both end up playing at once.
      final hook = _exclusiveHook;
      if (hook != null) {
        await stopOtherExclusiveAudio(except: hook);
      }

      // Stop the currently-playing AudioPlayer BEFORE unlinking its backing
      // file — deleting a file an active player still has open and only
      // relying on the next download's completion to implicitly stop it
      // (inside _playFile) would let the previous track keep playing from an
      // already-deleted file in the meantime.
      await _player?.stop();
      await _cleanupPreviousTempFile();
      await _cleanupStaleFilesForTrack(track.id);

      state = StreamPlaybackState(
        currentTrack: track,
        status: StreamPlaybackStatus.resolving,
      );

      // Mirrors download_queue_provider's derivation of the same flags from
      // app settings (see its runDownload/_buildDownloadRequestPayload):
      // extension providers must be enabled in Settings AND have at least
      // one enabled extension, or the Go backend rejects the request
      // outright — DownloadByStrategy in exports_download.go returns
      // "Extension providers are disabled; built-in download providers have
      // been retired" whenever UseExtensions is false, with no other path.
      final settings = ref.read(settingsProvider);
      final extensionState = ref.read(extensionProvider);
      final hasActiveExtensions = extensionState.extensions.any(
        (e) => e.enabled,
      );
      final useExtensions =
          settings.useExtensionProviders && hasActiveExtensions;
      final useFallback = settings.autoFallback;

      if (!useExtensions) {
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
        // DownloadRequestPayload has no `outputPath` field — the Go backend
        // derives the final path from `outputDir` + `filenameFormat` (+ the
        // extension it detects from the resolved source) and returns the
        // actual path it wrote to in the response's `file_path`.
        //
        // service/source are deliberately '', not track.source: for
        // library-synced tracks track.source is the 'spotify-library'
        // sentinel (see spotify_track_mapper.dart's spotifyLibrarySourceId),
        // which marks "no resolved audio source yet" — it is not a real
        // provider id. Passing it through as service/source would lock
        // strict-mode provider selection to that nonexistent provider (or,
        // in fallback mode, waste two lookup attempts on it). An empty
        // string is this app's existing signal for "auto-resolve across all
        // enabled providers by priority" (see _normalizeQueuedService in
        // download_queue_provider.dart).
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
        // Clean up whatever partial file this failed attempt may have left
        // behind, regardless of the extension/suffix the backend chose — a
        // thrown exception here means `_activeTempPath` was never (reliably)
        // set to the real on-disk path, so a prefix scan is the only way to
        // find it.
        _activeTempPath = null;
        await _cleanupStaleFilesForTrack(track.id);
        state = state.copyWith(
          status: StreamPlaybackStatus.error,
          error: '$e',
        );
      }
    } finally {
      if (_inFlightTrackId == track.id) {
        _inFlightTrackId = null;
      }
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
