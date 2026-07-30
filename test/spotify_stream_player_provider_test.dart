import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/spotify_stream_player_provider.dart';

void main() {
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
}
