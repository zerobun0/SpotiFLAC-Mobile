# Spotify Native Client v2: Design

**Status:** Approved for implementation. Supersedes nothing from `2026-07-30-spotify-streaming-client-design.md` (Phase 1's OAuth/library/streaming work stays — it gets relocated and hardened, not rebuilt).

## Background

Phase 1 (`planning/plans/2026-07-30-spotify-auth-library-streaming.md`, merged to `main`) added official Spotify OAuth login, playlist/liked-songs/followed-artist sync, and tap-to-stream — but tucked behind Settings, with streaming defaulting to a full LOSSLESS download before playback. After hands-on testing, the actual ask is broader: this should feel like a real Spotify client living in the app's existing Home/Library navigation, with a real personalized feed, fast streaming, and none of the app's extension ecosystem requiring manual setup.

Three things discovered during this round of investigation materially shaped this design:

1. **The Home tab already has a working "extension home feed" pipeline.** `lib/providers/explore_provider.dart` + `lib/screens/home_tab.dart` already detect any enabled extension with `hasHomeFeed` capability and render its feed via `PlatformBridge.getExtensionHomeFeed`. Nothing new needs to be built here structurally — it needs a feed source plugged in.
2. **A community `spotify-web` extension already exists** in the forked `SpotiFLAC-Extension` registry (`registry.json`, id `spotify-web`, capability `homeFeed: true`, `browseCategories: true`). Reading its code (legitimate interoperability inspection, same as this whole project already does for Tidal/Deezer/Qobuz's private APIs) shows it authenticates as an **anonymous** web visitor (TOTP-based client-token bootstrap, matching how a logged-out `open.spotify.com` visit works) — it has no mechanism to accept a real user's session. Its home feed is real and works today, just not personalized.
3. **Extension installation is entirely manual today.** `lib/providers/repo_provider.dart`'s `registryUrl` defaults to empty (`_registryUrlPrefKey`, unset until a user pastes one into Settings). Nothing is bundled, nothing auto-updates. This is the direct cause of "nothing plays" on a fresh install (zero enabled download sources) and of needing to manually track GitHub URLs for updates.

## Part 0: Phase 1 hardening

Five concrete fixes to already-merged Phase 1 code, identified from hands-on use. None change Phase 1's architecture — each is a targeted patch to an existing file.

1. **Dropped deep link on background resume.** `MainActivity.kt`'s OAuth redirect handling only fires from `onCreate`'s intent; if the app is already running in the background when the browser hands control back, the intent can arrive via `onNewIntent` instead and never reach `handleExtensionOAuthIntent`. Override `onNewIntent` to route through the same handler `onCreate` uses.
2. **Blocking pagination.** `SpotifyLibraryNotifier`'s liked-songs sync currently loops through every page with `do-while` before yielding to the UI. Yield the first page immediately; fetch subsequent pages in the background and append to state incrementally, so the Library tab is interactive as soon as page one lands instead of blocking on the full sync.
3. **No rate-limit handling.** `SpotifyLibraryService._get` has no handling for HTTP 429. Add a check that reads the `Retry-After` header, delays, and retries once (not an unbounded retry loop) instead of the sync surfacing a raw exception.
4. **Stuck "logging in" state.** `SpotifyAuthNotifier.login()`'s only escape from `loggingIn` today is a 5-minute timeout. Add a lifecycle observer (`WidgetsBindingObserver`/`AppLifecycleListener`): if the app resumes from background and `_pendingLogin` hasn't resolved within 1-2 seconds, reset to `loggedOut` instead of leaving the UI stuck for up to 5 minutes when the user backed out of the browser without completing login.
5. **Streaming race condition.** `SpotifyStreamPlayerNotifier.streamTrack` already has an in-flight guard for the *same* track (`isDuplicateStreamRequest`), but a tap on a *different* track while the first is still resolving has no generation token to invalidate the stale request — the first request's eventual completion can still call `_playFile` after a newer tap should have superseded it. Add a `_currentRequestId`/generation counter (matching the pattern `MusicPlayerHandler._playRequestGeneration` already uses) so a stale resolution is dropped instead of playing over the newer request. Part 5 below replaces this provider's playback path, so this fix should land in whichever of the two versions of the file exists first — implementation order between Part 0 item 5 and Part 5 matters and is left to the plan.

## Part 1: Extension auto-bundle + auto-update

**Change:** hardcode the registry URL to the community registry (`https://raw.githubusercontent.com/zarzet/SpotiFLAC-Extension/main/registry.json` — the actively-maintained upstream, not our fork, since the goal is riding their continuous updates, not maintaining a sync step ourselves) as the default, no longer requiring the user to set it. On app startup, and on a periodic background check (app-foreground interval, not a true background service — this is a foreground-only Flutter app), the app:

1. Fetches the registry (`PlatformBridge.getRepoExtensions`, already exists).
2. For each of the registry's extensions (currently 9: `spotify-web`, `amazon`, `apple-music`, `soundcloud`, `ytmusic-spotiflac`, `deezer`, `pandora`, `qobuz-web`, `tidal-web`) not yet installed, installs it (`RepoNotifier.installExtension`, already exists).
3. For each installed extension whose version is behind the registry's, upgrades it (`RepoNotifier.updateExtension`, already exists — this is the exact same call the manual "Update" button in the Store tab already makes).

All three primitives already exist and are already tested manually via the Store tab UI; this is new orchestration calling them automatically, not new download/install logic. The Store tab itself is unchanged and still useful for browsing/disabling individual extensions.

**Consequence:** a fresh install has every extension enabled and working with zero manual steps, directly fixing "songs can't be played" (no enabled sources) as a side effect.

## Part 2: Home tab — personalized feed

**Decision: do not modify the `spotify-web` extension to accept a real session.** Forking it to add cookie-acceptance would mean either permanently diverging from the auto-updated upstream (defeating Part 1) or re-patching it after every upstream update. Instead, build a **separate, first-party feed source**:

- A WebView screen (the one place in this whole effort a WebView is actually the right tool — capturing a real logged-in session's cookies is only possible by rendering Spotify's actual web login inside an embeddable browser control; an external Custom Tab/browser can't hand cookies back to the app) that loads Spotify's real web login, detects a successful login, and extracts the session cookie via the platform's cookie manager. This is the one new Flutter dependency this phase needs (`webview_flutter`), used for exactly this one screen — everything else (OAuth login, extension management) stays on the existing external-browser/no-WebView approach.
- A small first-party Go function (alongside this app's existing native, non-extension providers like the built-in Deezer support) that uses that cookie plus the same client-token bootstrap technique the `spotify-web` extension uses (read for protocol understanding, not copied file-for-file) to call Spotify's personalized home-feed endpoint.
- Plugged into the **existing** home-feed rendering pipeline in `home_tab.dart`/`explore_provider.dart` as an additional feed source alongside "any enabled extension with `hasHomeFeed`" — so no new feed UI needs to be built, only a new source feeding the one that exists.

This keeps the community extension pristine and freely auto-updatable, and keeps the personalized-session logic entirely first-party and under this project's own maintenance.

## Part 3: Library tab — real playlists/liked songs

Phase 1's OAuth login, `SpotifyLibraryNotifier`, and the playlist/liked-songs/followed-artists screens are functionally complete and already reviewed/hardened. This part is relocation, not rebuilding: move the entry point out of Settings and into the app's native Library tab (`_LibraryTabRoot`/`QueueTab` in `main_shell.dart`), alongside the app's existing local-library view, so "your Spotify library" is part of the same tab a user already goes to for their music — not a separate settings detour.

## Part 4: Real streaming, not download-then-play

Phase 1's stream player (`lib/providers/spotify_stream_player_provider.dart`) hardcodes `quality: 'LOSSLESS'` for every stream, so "streaming" a track currently means downloading a full lossless file before any audio plays — slow, and not what "stream" means to the user. Change the default streaming quality to a fast/lossy tier (small, quick-resolving file), while the existing, already-separate "Download" action in the app continues to fetch full quality on explicit request. This is a quality-default change to existing code, not new architecture.

## Part 5: Route Spotify streaming through the existing player (not a new UI)

**Discovery:** the app already has a fully-featured, polished music player for the local library — `music_player_service.dart`'s `MusicPlayerHandler` (an `audio_service` `BaseAudioHandler`) plus `mini_player.dart` and `now_playing_screen.dart`. It already provides everything a "build a Spotube/Namida/Musify-style player" task would ask for: a persistent mini-player with a Hero transition into a full-screen Now Playing view with live drag-to-dismiss, a Player/Lyrics tab bar with a synced-lyrics view (active-line highlighting), a drag-and-drop reorderable queue with swipe actions and a shuffle toggle, dynamic color (`dynamic_color` is already a dependency), and OS-level lock-screen/notification controls with audio-focus/interruption handling. None of this needs to be rebuilt, and it should not be — reimplementing it would be pure duplication and a maintenance burden with no user-visible benefit over what already exists.

**The actual gap:** `SpotifyStreamPlayerNotifier` (`lib/providers/spotify_stream_player_provider.dart`) never touches any of that. It creates its own second, bare `audioplayers.AudioPlayer` instance (`_player ??= AudioPlayer(playerId: 'spotify-stream-player')`) and plays the resolved file directly on it. Because `mini_player.dart`/`now_playing_screen.dart` only watch `musicPlayerHandler`'s streams (`currentMediaItemProvider`, `playbackPlayingProvider`, etc.), a Spotify stream is invisible to all of that UI — no mini-player, no lock-screen controls, no queue, no lyrics. This is very likely the dominant cause of streamed Spotify playback feeling broken or incomplete.

**Change:** retire the bespoke `AudioPlayer` in `SpotifyStreamPlayerNotifier`. Once `PlatformBridge.downloadByStrategy` resolves a track to a local file path (unchanged from Phase 1), convert it to the same `PlayableMedia` the local library already uses (`id`, `source: filePath`, `title`, `artist`, `album`, `artUri: track.coverUrl`) and hand it to `musicPlayerControllerProvider` (`playSingle`/`playAll`/`enqueue`, exactly as `playableFromLocal`/`playableFromHistory` already do in `music_player_provider.dart`). `StreamPlaybackState`/`StreamPlaybackStatus` and the re-entrancy/generation guards from Part 0 item 5 stay as the resolution-side state machine (resolving/buffering/error), but once a file is ready, playback itself flows through `musicPlayerHandler` — the one path, not two. Any screen currently reading `spotifyStreamPlayerProvider` for playback controls is updated to read the shared `musicPlayerProvider`/`musicPlayerControllerProvider` instead, matching how every other part of the app already plays audio.

**Consequence:** Spotify-streamed tracks get the mini-player, hero Now Playing screen, lyrics tab, reorderable queue, and lock-screen controls automatically, with no new player UI written — directly answering the "make it a real player, not just a library viewer" complaint.

## Out of scope / explicit non-goals

- **Not copying SpotUI (`com.music.spotui`) or any other third-party app's code or assets.** Its "1:1 Spotify UI" is native Android (Kotlin, no Flutter), independently built by its author; we build our own original Spotify-styled UI in Flutter. Any visual inspiration is layout-level (dark theme, home feed, bottom nav, big Now Playing), not code reuse.
- **Not modifying the `spotify-web` (or any other) community extension's code.** They stay exactly as published so Part 1's auto-update stays simple and conflict-free.
- **Not building a new music player UI from scratch.** Part 5 above is deliberately an integration, not a rebuild — the existing player (mini-player, Now Playing, lyrics, queue, lock-screen controls) already meets this bar for the local library; Spotify streaming needs to be plugged into it, not given a competing parallel implementation.
- True byte-range progressive streaming (starting audio mid-download) is still not in scope — Part 4's fast-quality-by-default is the pragmatic fix; the Go backend's download contract still has no partial-file signal to build true progressive playback on top of, unchanged from Phase 1's spec.
