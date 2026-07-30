import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/spotify_auth_provider.dart';
import 'package:spotiflac_android/screens/spotify/spotify_library_screen.dart';

class SpotifyLoginScreen extends ConsumerWidget {
  const SpotifyLoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(spotifyAuthProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Spotify Account')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.podcasts, size: 64),
              const SizedBox(height: 16),
              switch (authState.status) {
                SpotifyAuthStatus.loggedIn => Column(
                  children: [
                    const Text('Connected to Spotify'),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SpotifyLibraryScreen(),
                        ),
                      ),
                      child: const Text('Browse your library'),
                    ),
                    TextButton(
                      onPressed: () =>
                          ref.read(spotifyAuthProvider.notifier).logout(),
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
                SpotifyAuthStatus.loggingIn => const Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Waiting for Spotify login...'),
                  ],
                ),
                _ => Column(
                  children: [
                    const Text('Connect your Spotify account to stream your library'),
                    if (authState.error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        authState.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () =>
                          ref.read(spotifyAuthProvider.notifier).login(),
                      child: const Text('Connect Spotify'),
                    ),
                  ],
                ),
              },
            ],
          ),
        ),
      ),
    );
  }
}
