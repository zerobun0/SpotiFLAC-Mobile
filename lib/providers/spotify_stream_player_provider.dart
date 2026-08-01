import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/download_request_payload.dart';
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia, musicPlayerHandler;
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

/// The narrow slice of the shared music player that
/// [SpotifyStreamPlayerNotifier] talks to.
///
/// Exists as a seam so the handoff ordering — which is where every bug in
/// this file has lived — can be exercised in a plain unit test. The real
/// `MusicPlayerHandler` is an `audio_service` `BaseAudioHandler` that cannot
/// be constructed in a test, so without this indirection the notifier's
/// interaction with the player is untestable and regressions here are
/// invisible to the suite. Production always uses the default instance,
/// which forwards straight to the global handler.
class StreamPlayerHandoff {
  const StreamPlayerHandoff();

  /// Media id the shared player is currently showing, or null when it is
  /// stopped / has nothing queued.
  String? currentMediaItemId() => musicPlayerHandler?.mediaItem.value?.id;

  /// Tells the shared player that [path] no longer exists, so it can drop
  /// any queue entry pointing at it.
  Future<void> onSourceDeleted(String path) async {
    await musicPlayerHandler?.onSourceDeleted(path);
  }

  /// True once the shared player is initialized and able to accept a handoff.
  Future<bool> ensureReady(MusicPlayerController controller) async {
    return await controller.ensureInitialized() != null;
  }

  /// Hands [media] to the shared player as its sole queue entry.
  Future<void> play(MusicPlayerController controller, PlayableMedia media) {
    return controller.playSingle(media);
  }
}

/// Injection point for [StreamPlayerHandoff] — overridden in tests, always
/// the real forwarding implementation in production.
final streamPlayerHandoffProvider = Provider<StreamPlayerHandoff>(
  (ref) => const StreamPlayerHandoff(),
);

class SpotifyStreamPlayerNotifier extends Notifier<StreamPlaybackState> {
  int _requestGeneration = 0;

  // Track id whose streamTrack() call is currently in flight (downloading
  // and about to hand off to the shared player). Guards against a double-tap
  // on the same track starting a second downloadByStrategy call against the
  // identical outputDir/filenameFormat path while the first is still writing
  // to it — whose stale-file cleanup could otherwise delete the file the
  // first call is actively writing, or delete the winner's file out from
  // under the shared player after handoff. A call for a *different* track is
  // not blocked; it legitimately supersedes the in-flight one via the
  // generation counter below instead.
  String? _inFlightTrackId;

  // Path of the file most recently handed off to the shared player — i.e.
  // the file the shared player is, as far as this notifier knows, still
  // holding as its sole queue entry.
  //
  // Deleted only once the *next* request has successfully replaced it via
  // playSingle, never earlier. Deleting it at the start of the next request
  // (as an earlier revision did) is wrong twice over: the shared player may
  // still be playing it, and notifying the player about that deletion empties
  // its one-entry queue, which stops playback and nulls out `mediaItem` —
  // the exact value the in-flight request's takeover-abort check compares
  // against, so every subsequent stream would abort itself.
  String? _lastHandedOffFilePath;

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
          // Same reasoning as _deleteFile: a leftover file from a previous
          // attempt at this same track id may still be sitting in the
          // shared player's queue.
          await _deleteFile(entity.path);
        }
      }
    } catch (_) {}
  }

  Future<void> streamTrack(Track track) async {
    if (isDuplicateStreamRequest(_inFlightTrackId, track.id)) {
      _log.d('Ignoring duplicate streamTrack call for in-flight track ${track.id}');
      return;
    }
    _inFlightTrackId = track.id;
    final generation = ++_requestGeneration;

    // The shared player's current media item id when this request started —
    // used below to detect whether something else (most notably, the local
    // library player) has taken the shared player over by the time this
    // request's download finishes, so a slow Spotify resolution can't
    // silently clobber playback the user has already moved on to.
    final handoff = ref.read(streamPlayerHandoffProvider);
    final baselineMediaItemId = handoff.currentMediaItemId();

    try {
      // NOTE: the previous handoff's file is deliberately *not* deleted here.
      // It is still what the shared player is playing, and touching it now
      // would both yank a playing file and (via onSourceDeleted) stop the
      // player, breaking this request's own takeover-abort check below. It
      // is cleaned up after this request's playSingle succeeds instead —
      // see _lastHandedOffFilePath.
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

        final currentMediaItemId = handoff.currentMediaItemId();
        if (currentMediaItemId != baselineMediaItemId) {
          // Something else (e.g. the user starting local library playback)
          // took over the shared player while this request was resolving —
          // don't clobber it with a stream the user has already moved past.
          unawaited(_deleteFile(filePath));
          return;
        }

        final controller = ref.read(musicPlayerControllerProvider);
        final playerReady = await handoff.ensureReady(controller);
        if (!playerReady) {
          // playSingle()/playAll() silently no-op when the shared player
          // failed to initialize — surface that as an error here instead of
          // leaving the UI stuck on "playing" with no audio.
          _log.e('Music player failed to initialize; cannot play "${track.name}"');
          unawaited(_deleteFile(filePath));
          state = state.copyWith(
            status: StreamPlaybackStatus.error,
            error: 'Failed to start playback: the player is unavailable.',
          );
          return;
        }

        final previousHandoffPath = _lastHandedOffFilePath;
        _lastHandedOffFilePath = filePath;
        state = state.copyWith(status: StreamPlaybackStatus.playing);
        await handoff.play(
          controller,
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

        // Safe only now: this request's file is the shared player's sole
        // queue entry, so the previous one is genuinely orphaned and
        // onSourceDeleted on it matches nothing (no stop, no null mediaItem).
        // Doing this here rather than at the start of the next request also
        // means an aborted request never deletes a file that is still
        // playing — the path stays in _lastHandedOffFilePath and is reaped by
        // whichever request next succeeds, so nothing leaks either.
        if (previousHandoffPath != null && previousHandoffPath != filePath) {
          unawaited(_deleteFile(previousHandoffPath));
        }
      } catch (e) {
        if (isStaleStreamRequest(currentGeneration: _requestGeneration, requestGeneration: generation)) {
          return;
        }
        _log.e('Stream resolution failed for "${track.name}"', e);
        await _cleanupStaleFilesForTrack(track.id);
        state = state.copyWith(status: StreamPlaybackStatus.error, error: '$e');
      }
    } finally {
      if (_inFlightTrackId == track.id) {
        _inFlightTrackId = null;
      }
    }
  }

  /// Deletes a stream cache file *and* tells the shared player about it, so
  /// a deleted file never lingers as a stale queue entry — mirroring
  /// `deleteFile()` in `utils/file_access.dart`, this codebase's convention
  /// for deleting something the player might be holding.
  ///
  /// The one case that must NOT be reported is a path that is still the
  /// player's current entry from this notifier's last handoff: removing it
  /// empties a one-entry queue, which stops playback and nulls out
  /// `mediaItem` — and `streamTrack`'s takeover-abort check compares against
  /// exactly that value, so reporting it mid-request makes the request
  /// conclude it was superseded and silently abort. Such a path is only ever
  /// deleted here as part of being replaced, and the replacement's
  /// `playSingle` resets the queue anyway.
  Future<void> _deleteFile(String path) async {
    if (path.isEmpty) return;
    final isPlayersCurrentSource = path == _lastHandedOffFilePath;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    if (isPlayersCurrentSource) return;
    try {
      await ref.read(streamPlayerHandoffProvider).onSourceDeleted(path);
    } catch (_) {}
  }
}

final spotifyStreamPlayerProvider =
    NotifierProvider<SpotifyStreamPlayerNotifier, StreamPlaybackState>(
      SpotifyStreamPlayerNotifier.new,
    );
