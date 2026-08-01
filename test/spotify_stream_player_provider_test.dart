import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/spotify_stream_player_provider.dart';
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('streamCacheFileName', () {
    test('is stable and filesystem-safe for a given track id', () {
      final name = streamCacheFileName('abc123');
      expect(name, 'stream_abc123');
      expect(RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(name), isTrue);
    });

    test('sanitizes ids containing path separators', () {
      final name = streamCacheFileName('a/b:c');
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(':')));
    });
  });

  group('StreamPlaybackState', () {
    test('copyWith clearTrack removes the current track', () {
      const track = null; // placeholder to keep import list minimal below
      const initial = StreamPlaybackState(
        status: StreamPlaybackStatus.playing,
      );
      final cleared = initial.copyWith(
        clearTrack: true,
        status: StreamPlaybackStatus.idle,
      );
      expect(cleared.currentTrack, track);
      expect(cleared.status, StreamPlaybackStatus.idle);
    });
  });

  group('isDuplicateStreamRequest', () {
    test('is false when nothing is in flight', () {
      expect(isDuplicateStreamRequest(null, 'track-1'), isFalse);
    });

    test('is true for a second call for the same in-flight track', () {
      expect(isDuplicateStreamRequest('track-1', 'track-1'), isTrue);
    });

    test('is false for a different track superseding the in-flight one', () {
      expect(isDuplicateStreamRequest('track-1', 'track-2'), isFalse);
    });
  });

  group('isStaleStreamRequest', () {
    test('a request is stale once a newer generation has started', () {
      expect(isStaleStreamRequest(currentGeneration: 2, requestGeneration: 1), isTrue);
    });

    test('the current generation is not stale', () {
      expect(isStaleStreamRequest(currentGeneration: 2, requestGeneration: 2), isFalse);
    });
  });

  group('streamTrack handoff sequencing', () {
    late Directory tempDir;
    late _FakeStreamPlayerHandoff fakeHandoff;
    late List<String> downloadedTrackIds;
    // Runs while a download is "in flight", i.e. after the request captured
    // its baseline media id but before it reaches the takeover check.
    void Function()? duringDownload;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('spotiflac_stream_test');
      fakeHandoff = _FakeStreamPlayerHandoff();
      downloadedTrackIds = <String>[];
      duringDownload = null;
      SharedPreferences.setMockInitialValues({});

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_pathProviderChannel, (call) async {
        return tempDir.path;
      });
      messenger.setMockMethodCallHandler(_secureStorageChannel, (call) async {
        if (call.method == 'readAll') return <String, String>{};
        return null;
      });
      messenger.setMockMethodCallHandler(_backendChannel, (call) async {
        switch (call.method) {
          case 'getInstalledExtensions':
            // streamTrack refuses to run without at least one *enabled*
            // extension provider.
            return <Map<String, dynamic>>[
              {
                'id': 'ext-a',
                'name': 'ext-a',
                'version': '1.0.0',
                'enabled': true,
                'status': 'loaded',
              },
            ];
          case 'downloadByStrategy':
            final payload =
                jsonDecode(call.arguments as String) as Map<String, dynamic>;
            final trackId = payload['item_id'] as String;
            downloadedTrackIds.add(trackId);
            duringDownload?.call();
            // The real backend writes to outputDir/filenameFormat; mirror
            // that deterministic path so the cache-cleanup logic sees a
            // realistic file layout.
            final path =
                '${tempDir.path}/spotify_stream_cache/'
                '${streamCacheFileName(trackId)}.m4a';
            await File(path).writeAsString('audio');
            return <String, dynamic>{'success': true, 'file_path': path};
          default:
            return null;
        }
      });
    });

    tearDown(() async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_pathProviderChannel, null);
      messenger.setMockMethodCallHandler(_secureStorageChannel, null);
      messenger.setMockMethodCallHandler(_backendChannel, null);
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    Future<ProviderContainer> buildContainer() async {
      final container = ProviderContainer(
        overrides: [streamPlayerHandoffProvider.overrideWithValue(fakeHandoff)],
      );
      addTearDown(container.dispose);
      await container.read(extensionProvider.notifier).refreshExtensions();
      return container;
    }

    // Regression test for the handoff-ordering bug: deleting the previous
    // request's file (and reporting it to the shared player) at the *start*
    // of the next request emptied the player's one-entry queue, which
    // stopped playback and nulled mediaItem — so the takeover-abort check
    // later in that same request saw a mismatch, concluded something else
    // had grabbed the player, and silently returned while the UI stayed on
    // the buffering spinner forever. It reproduced on the second stream tap
    // of any session.
    test('a second sequential stream still reaches the player', () async {
      final container = await buildContainer();
      final notifier = container.read(spotifyStreamPlayerProvider.notifier);

      await notifier.streamTrack(_track('track-1'));
      expect(
        container.read(spotifyStreamPlayerProvider).status,
        StreamPlaybackStatus.playing,
        reason: 'the first stream should hand off normally',
      );
      expect(fakeHandoff.playedSources, hasLength(1));

      await notifier.streamTrack(_track('track-2'));

      expect(
        container.read(spotifyStreamPlayerProvider).status,
        StreamPlaybackStatus.playing,
        reason: 'the second stream must not abort itself; it was getting '
            'stuck on buffering with no audio and no error',
      );
      expect(fakeHandoff.playedSources, hasLength(2));
      expect(fakeHandoff.currentMediaItemId(), 'spotify-stream-track-2');
      expect(downloadedTrackIds, ['track-1', 'track-2']);
    });

    test('a third stream keeps working too', () async {
      final container = await buildContainer();
      final notifier = container.read(spotifyStreamPlayerProvider.notifier);

      await notifier.streamTrack(_track('track-1'));
      await notifier.streamTrack(_track('track-2'));
      await notifier.streamTrack(_track('track-3'));

      expect(
        container.read(spotifyStreamPlayerProvider).status,
        StreamPlaybackStatus.playing,
      );
      expect(fakeHandoff.playedSources, hasLength(3));
      expect(fakeHandoff.currentMediaItemId(), 'spotify-stream-track-3');
    });

    test(
      'the previous stream file is reaped once its replacement is playing',
      () async {
        final container = await buildContainer();
        final notifier = container.read(spotifyStreamPlayerProvider.notifier);

        await notifier.streamTrack(_track('track-1'));
        final firstPath = fakeHandoff.playedSources.single;
        expect(File(firstPath).existsSync(), isTrue);

        await notifier.streamTrack(_track('track-2'));
        // Deletion is fire-and-forget; let the microtask/IO settle.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          File(firstPath).existsSync(),
          isFalse,
          reason: 'the superseded file must still be cleaned up — this is '
              'the cache leak the deferred delete exists to prevent',
        );
        // ...and reporting that deletion must not have disturbed the player,
        // which by then is holding the *new* file.
        expect(fakeHandoff.currentMediaItemId(), 'spotify-stream-track-2');
      },
    );

    test('the takeover-abort check still fires when something else grabs '
        'the player mid-resolution', () async {
      final container = await buildContainer();
      final notifier = container.read(spotifyStreamPlayerProvider.notifier);

      // Simulate the local library player taking the shared player over
      // while the Spotify download is still resolving.
      duringDownload = () =>
          fakeHandoff.forceCurrentMediaItemId('local-library-item');

      await notifier.streamTrack(_track('track-1'));

      expect(
        fakeHandoff.playedSources,
        isEmpty,
        reason: 'a takeover must abort the handoff rather than clobber '
            'whatever the user moved on to',
      );
    });
  });
}

const _backendChannel = MethodChannel('com.zarz.spotiflac/backend');
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

Track _track(String id) => Track(
  id: id,
  name: 'Track $id',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

/// Models the shared player closely enough to reproduce the regression:
/// `playSingle` replaces the queue with exactly one entry, and
/// `onSourceDeleted` on that entry empties the queue, which stops playback
/// and clears `mediaItem` — the cascade that broke the takeover-abort check.
class _FakeStreamPlayerHandoff implements StreamPlayerHandoff {
  final List<String> playedSources = <String>[];
  final List<String> deletedSources = <String>[];

  String? _currentMediaItemId;
  String? _currentSource;

  void forceCurrentMediaItemId(String id) => _currentMediaItemId = id;

  @override
  String? currentMediaItemId() => _currentMediaItemId;

  @override
  Future<void> onSourceDeleted(String path) async {
    deletedSources.add(path);
    if (_currentSource != path) return; // not queued — no-op, as in the real handler
    _currentSource = null;
    _currentMediaItemId = null; // queue emptied -> stop()
  }

  @override
  Future<bool> ensureReady(MusicPlayerController controller) async => true;

  @override
  Future<void> play(MusicPlayerController controller, PlayableMedia media) async {
    playedSources.add(media.source);
    _currentSource = media.source;
    _currentMediaItemId = media.id;
  }
}
