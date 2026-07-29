# SpotiFLAC → Spotify Streaming Client: Design

**Status:** Phase 1 approved for implementation. Phases 2–4 are roadmap-level, to be spec'd individually when reached.

## Background

[SpotiFLAC-Mobile](https://github.com/spotiflacapp/SpotiFLAC-Mobile) (Flutter UI + Go backend, compiled in via gomobile) is a **downloader**: given a public Spotify link, it resolves track metadata (via Song.link/IDHS) and downloads lossless audio from third-party sources — Tidal, Deezer, Qobuz, Apple Music, Amazon Music, YT Music, SoundCloud — through swappable "extensions" (JS modules run in a Go JS runtime, `goja`) pulled from the [SpotiFLAC-Extension](https://github.com/spotiflacapp/SpotiFLAC-Extension) community registry. It never authenticates with Spotify and has no concept of "your account" — only pasted links.

This project turns it into an actual Spotify client: log in with your real Spotify account, browse your real library (playlists, liked songs, followed artists, saved albums), and play tracks in-app — streaming, not just downloading — while reusing SpotiFLAC's existing multi-source resolution pipeline to source the actual audio. A later phase adds real-time synced listening across devices ("Listen Together").

## Streaming model decision

Two fundamentally different ways to get "streaming" were considered:

1. **Real Spotify audio via [librespot](https://github.com/librespot-org/librespot)** (Rust, Spotify Connect protocol) — actually decrypts and streams Spotify's own catalog. Requires Premium, needs a new Rust↔Flutter FFI bridge with no existing Dart bindings, and sits in materially greyer ToS territory (emulates an unauthorized official client).
2. **Library sync + alt-source playback** — official OAuth pulls your real library; playback streams through the existing extension pipeline against Tidal/Deezer/Qobuz/etc. No Premium required, reuses ~all existing Go backend code, proven approach (this is what [Spotube](https://github.com/KRTirtho/spotube) does).

**Decision: option 2**, for Phase 1. Option 1 is left as a possible later pluggable playback backend — nothing in this design forecloses adding it, but it is not built now.

## Roadmap

| Phase | Scope | Depends on |
|---|---|---|
| **1** | Spotify OAuth login, library sync, in-app streaming | — (foundation) |
| 2 | Download flow wired to synced library items (not just pasted links) | 1 |
| 3 | Listen Together — real-time synced playback across devices | 1 |
| 4 (stretch) | librespot as an optional real-audio backend for Premium users | 1 |

Platform: **Android only** for now (matches most of SpotiFLAC's existing user base; avoids iOS background-audio/OAuth-redirect/App Store complications for a category of app that can't realistically ship on the App Store anyway).

## Phase 1: Auth + Library Sync + Streaming

### Key constraint driving the design

The Go backend's download contract (`go_backend/exports_download.go`, `DownloadRequest`/`DownloadResponse`) is **file-oriented**: it writes a complete file to `OutputDir`/`OutputPath`/`OutputFD` and returns only once finished. There is no byte-range/chunked interface in the extension contract, and adding one would mean touching every extension's (Tidal/Deezer/Qobuz/etc.) download logic — invasive, and extensions are third-party/community-maintained, not ours to unilaterally change the contract for.

**Design choice: progressive local buffering, not true HTTP streaming.** The existing download call runs unmodified against a temp file in the app cache dir; the player reads that growing file and starts audible playback once enough is buffered, continuing to read as it grows. This is the same technique most "streaming" apps built on top of a downloader use in practice.

Consequence: this phase requires **zero changes to the Go backend or the extension contract**. All new work is in the Flutter layer.

### New components

- **`lib/services/spotify_auth_service.dart`** — OAuth2 Authorization Code + PKCE flow. Opened in an in-app webview (new dependency: `webview_flutter`) pointed at `accounts.spotify.com/authorize`, redirecting to a custom URI scheme (`spotiflac://callback`) intercepted by the app. Scopes needed: `playlist-read-private`, `playlist-read-collaborative`, `user-library-read`, `user-follow-read`, `user-read-email`. Tokens stored via the already-present `flutter_secure_storage`; refresh handled transparently, falling back to a re-login prompt only if refresh itself fails.

- **`lib/services/spotify_library_service.dart`** — client for `api.spotify.com/v1/me/tracks`, `/me/playlists`, `/me/following`, `/me/albums`, with pagination. This is a **new, distinct concept from the existing `lib/services/library_database.dart`**, which indexes locally scanned/downloaded files — the two are merged at the UI layer (a track can be "in your Spotify library" and/or "downloaded locally") but remain separate data sources with separate sync logic.

- **`lib/services/stream_resolution_service.dart`** — given a Spotify track ID, reuses the existing metadata-resolution + provider-priority logic already in `go_backend/exports_extensions.go` / `extension_priority.go` to pick a source extension, then hands off to the new progressive-buffer player instead of a plain download call.

- **Progressive playback source** — add `just_audio` (new dependency) specifically for `LockCachingAudioSource`, which buffers a growing file and allows seeking/playback before it's complete. The existing `audioplayers`/`audio_service`/`audio_session` stack has no equivalent and stays in place for other playback needs (background controls, notification, media session) — `just_audio` is scoped narrowly to this one capability unless it proves better to consolidate later.

- **New UI**: `lib/screens/library/*` for playlists / liked songs / followed artists / saved albums, plus a "Now Playing" screen wired to the new streaming player.

### Data flow

```
User taps a track in synced library
  → stream_resolution_service resolves best source via existing
    extension_priority logic (Go, unchanged)
  → existing DownloadRequest fires against a temp cache file (Go, unchanged)
  → just_audio LockCachingAudioSource reads the growing temp file
  → playback starts once buffered; continues as file grows
  → on completion: file is either discarded (pure stream) or promoted
    into the permanent downloaded-library location (explicit download)
```

### Error handling

- Token refresh failure → silent retry once, then re-login prompt.
- No provider has the track → same "Song not found — enable more providers" UX the app already shows for downloads.
- Network loss mid-buffer → pause and resume from buffer position, not restart from zero.

### Testing

- Go backend: unchanged in Phase 1 by design; existing test suite stays green with no new coverage needed there.
- Dart: unit tests for OAuth token handling (mocked HTTP — refresh flow, expiry, failure fallback) and library pagination.
- Manual pass for the progressive playback path: start a stream, confirm audible playback begins before the underlying download completes, confirm seeking works within the buffered region, confirm a completed stream yields a valid, taggable downloaded file.

## Phase 3 sketch: Listen Together

Not spec'd in detail yet (separate design doc when Phase 1 ships), but the shape:

- **Host-authoritative sync**, modeled on Spotify's own Group Session UX and on reference implementations like [Jellyfin SyncPlay](https://jellyfin.org/docs/general/server/sync-play/) / [Plex SyncPlay](https://support.plex.tv) / [listentogether-app](https://github.com/jofr/listentogether-app): one device owns playback state (track, position, play/pause), others receive events and periodic position pings, with client-side drift correction rather than frame-perfect lockstep.
- Needs a **relay server** — new component, not present in SpotiFLAC today. Likely Go (matches existing backend skill investment), WebSocket-based, minimal state (room code → host + guest connections + current playback state), self-hosted (Fly.io/Render/VPS — hosting choice deferred to that phase's design).
- Depends on Phase 1's stream resolution being deterministic enough that "the same track" resolves to playable audio for every participant, even if they end up pulling from different source extensions/providers.

## Out of scope for now

- iOS.
- True HTTP range-streaming through the extension contract (would require renegotiating the contract with every extension author).
- librespot / real Spotify audio (Phase 4, stretch, not designed in detail).
