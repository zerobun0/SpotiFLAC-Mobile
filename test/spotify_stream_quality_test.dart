// test/spotify_stream_quality_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/spotify_stream_player_provider.dart';

void main() {
  test('streaming defaults to a fast, non-lossless quality tier', () {
    expect(spotifyStreamQuality, isNot('LOSSLESS'));
  });
}
