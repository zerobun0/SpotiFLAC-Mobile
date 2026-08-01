import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/constants/spotify_config.dart'
    show spotifySessionCookieStorageKey;
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';

final _log = AppLogger('ExploreProvider');

class ExploreItem {
  final String id;
  final String uri;
  final String type;
  final String name;
  final String artists;
  final String? description;
  final String? coverUrl;
  final String? providerId;
  final String? albumId;
  final String? albumName;
  final String? releaseDate;
  final int durationMs;

  const ExploreItem({
    required this.id,
    required this.uri,
    required this.type,
    required this.name,
    required this.artists,
    this.description,
    this.coverUrl,
    this.providerId,
    this.albumId,
    this.albumName,
    this.releaseDate,
    this.durationMs = 0,
  });

  factory ExploreItem.fromJson(Map<String, dynamic> json) {
    return ExploreItem(
      id: json['id'] as String? ?? '',
      uri: json['uri'] as String? ?? '',
      type: json['type'] as String? ?? 'track',
      name: json['name'] as String? ?? '',
      artists: json['artists'] as String? ?? '',
      description: json['description'] as String?,
      coverUrl: json['cover_url'] as String?,
      providerId: json['provider_id'] as String?,
      albumId: json['album_id'] as String?,
      albumName: json['album_name'] as String?,
      releaseDate: json['release_date']?.toString(),
      durationMs: json['duration_ms'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'uri': uri,
    'type': type,
    'name': name,
    'artists': artists,
    'description': description,
    'cover_url': coverUrl,
    'provider_id': providerId,
    'album_id': albumId,
    'album_name': albumName,
    'release_date': releaseDate,
    'duration_ms': durationMs,
  };
}

class ExploreSection {
  final String uri;
  final String title;
  final List<ExploreItem> items;
  final bool isYTMusicQuickPicks;

  const ExploreSection({
    required this.uri,
    required this.title,
    required this.items,
    this.isYTMusicQuickPicks = false,
  });

  factory ExploreSection.fromJson(Map<String, dynamic> json) {
    final itemsList = json['items'] as List<dynamic>? ?? [];
    final items = itemsList
        .map((item) => ExploreItem.fromJson(item as Map<String, dynamic>))
        .toList();
    final isQuickPicks = _isYTMusicQuickPicksItems(items);
    return ExploreSection(
      uri: json['uri'] as String? ?? '',
      title: json['title'] as String? ?? '',
      items: items,
      isYTMusicQuickPicks: isQuickPicks,
    );
  }

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'title': title,
    'items': items.map((i) => i.toJson()).toList(),
  };
}

class ExploreState {
  final bool isLoading;
  final String? error;
  final String? greeting;
  final String? providerId;
  final List<ExploreSection> sections;
  final DateTime? lastFetched;

  const ExploreState({
    this.isLoading = false,
    this.error,
    this.greeting,
    this.providerId,
    this.sections = const [],
    this.lastFetched,
  });

  bool get hasContent => sections.isNotEmpty;

  ExploreState copyWith({
    bool? isLoading,
    String? error,
    String? greeting,
    String? providerId,
    bool clearProviderId = false,
    List<ExploreSection>? sections,
    DateTime? lastFetched,
  }) {
    return ExploreState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      greeting: greeting ?? this.greeting,
      providerId: clearProviderId ? null : (providerId ?? this.providerId),
      sections: sections ?? this.sections,
      lastFetched: lastFetched ?? this.lastFetched,
    );
  }
}

String _getLocalGreeting() {
  final hour = DateTime.now().hour;
  if (hour >= 5 && hour < 12) {
    return 'Good morning';
  } else if (hour >= 12 && hour < 17) {
    return 'Good afternoon';
  } else if (hour >= 17 && hour < 21) {
    return 'Good evening';
  } else {
    return 'Good night';
  }
}

bool _isYTMusicQuickPicksItems(List<ExploreItem> items) {
  if (items.isEmpty) return false;
  if (items.first.providerId != 'ytmusic-spotiflac') return false;
  for (final item in items) {
    if (item.type != 'track') {
      return false;
    }
  }
  return true;
}

List<Map<String, Object?>> _normalizeExploreSectionsPayload(
  dynamic rawSections,
) {
  if (rawSections is! List) return const [];
  final sections = <Map<String, Object?>>[];
  for (final rawSection in rawSections) {
    if (rawSection is! Map) continue;
    final section = Map<Object?, Object?>.from(rawSection);
    final rawItems = section['items'];
    final items = <Map<String, Object?>>[];
    if (rawItems is List) {
      for (final rawItem in rawItems) {
        if (rawItem is! Map) continue;
        items.add(Map<String, Object?>.from(rawItem));
      }
    }
    sections.add({
      'uri': section['uri']?.toString() ?? '',
      'title': section['title']?.toString() ?? '',
      'items': items,
    });
  }
  return sections;
}

List<Map<String, Object?>> _withDefaultExploreProviderId(
  List<Map<String, Object?>> normalizedSections,
  String providerId,
) {
  final normalizedProviderId = providerId.trim();
  if (normalizedProviderId.isEmpty) return normalizedSections;

  return normalizedSections
      .map((section) {
        final rawItems = section['items'];
        if (rawItems is! List) return section;

        return <String, Object?>{
          ...section,
          'items': rawItems
              .map((rawItem) {
                if (rawItem is! Map) return rawItem;
                final item = Map<String, Object?>.from(rawItem);
                final itemProviderId =
                    item['provider_id']?.toString().trim() ?? '';
                if (itemProviderId.isEmpty) {
                  item['provider_id'] = normalizedProviderId;
                }
                return item;
              })
              .toList(growable: false),
        };
      })
      .toList(growable: false);
}

Map<String, Object?> _decodeExploreCache(String rawCache) {
  final decoded = jsonDecode(rawCache);
  if (decoded is! Map) {
    return const {'provider_id': null, 'sections': <Map<String, Object?>>[]};
  }

  final providerId = decoded['provider_id']?.toString().trim();
  var sections = _normalizeExploreSectionsPayload(decoded['sections']);
  if (providerId != null && providerId.isNotEmpty) {
    sections = _withDefaultExploreProviderId(sections, providerId);
  }

  return {'provider_id': providerId, 'sections': sections};
}

String _encodeExploreCache(Map<String, Object?> cachePayload) {
  return jsonEncode(cachePayload);
}

List<ExploreSection> _buildExploreSectionsFromNormalizedPayload(
  List<Map<String, Object?>> normalizedSections,
) {
  return normalizedSections
      .map(
        (section) =>
            ExploreSection.fromJson(Map<String, dynamic>.from(section)),
      )
      .toList(growable: false);
}

class ExploreNotifier extends Notifier<ExploreState> {
  static const _cacheKey = 'explore_home_feed_cache';
  static const _cacheTsKey = 'explore_home_feed_ts';
  int _homeFeedRequestId = 0;

  @override
  ExploreState build() {
    _restoreFromCache();
    return const ExploreState();
  }

  Future<void> _restoreFromCache() async {
    try {
      if (ref.read(settingsProvider).homeFeedProvider ==
          AppSettings.homeFeedProviderOff) {
        _log.d('Home feed disabled, skipping cache restore');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      final cachedTs = prefs.getInt(_cacheTsKey);
      if (cached == null || cached.isEmpty) return;

      final cachePayload = await compute(_decodeExploreCache, cached);
      final providerId = cachePayload['provider_id']?.toString().trim();
      final rawSections = cachePayload['sections'];
      var normalizedSections = rawSections is List
          ? rawSections
                .whereType<Map<Object?, Object?>>()
                .map((section) => Map<String, Object?>.from(section))
                .toList(growable: false)
          : const <Map<String, Object?>>[];
      final resolvedProviderId = providerId?.isNotEmpty == true
          ? providerId
          : _resolveHomeFeedExtension()?.id;
      if (resolvedProviderId != null && resolvedProviderId.isNotEmpty) {
        normalizedSections = _withDefaultExploreProviderId(
          normalizedSections,
          resolvedProviderId,
        );
      }
      final sections = _buildExploreSectionsFromNormalizedPayload(
        normalizedSections,
      );

      if (sections.isEmpty) return;

      final lastFetched = cachedTs != null
          ? DateTime.fromMillisecondsSinceEpoch(cachedTs)
          : null;

      _log.i('Restored ${sections.length} cached explore sections');
      state = ExploreState(
        greeting: _getLocalGreeting(),
        providerId: resolvedProviderId,
        sections: sections,
        lastFetched: lastFetched,
      );
    } catch (e) {
      _log.w('Failed to restore explore cache: $e');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_cacheKey);
        await prefs.remove(_cacheTsKey);
        _log.d('Removed invalid explore cache');
      } catch (clearError) {
        _log.w('Failed to remove invalid explore cache: $clearError');
      }
    }
  }

  Extension? _resolveHomeFeedExtension() {
    final settings = ref.read(settingsProvider);
    final preferredId = settings.homeFeedProvider;
    final enabledHomeFeedExtensions = ref
        .read(extensionProvider)
        .extensions
        .where((extension) => extension.enabled && extension.hasHomeFeed)
        .toList(growable: false);

    if (preferredId != null && preferredId.isNotEmpty) {
      return enabledHomeFeedExtensions
          .where((extension) => extension.id == preferredId)
          .firstOrNull;
    }

    return enabledHomeFeedExtensions.firstOrNull;
  }

  Future<void> _saveToCache(
    List<Map<String, Object?>> normalizedSections,
    String providerId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = await compute(_encodeExploreCache, {
        'provider_id': providerId,
        'sections': normalizedSections,
      });
      await prefs.setString(_cacheKey, encoded);
      await prefs.setInt(_cacheTsKey, DateTime.now().millisecondsSinceEpoch);
      _log.d('Saved ${normalizedSections.length} explore sections to cache');
    } catch (e) {
      _log.w('Failed to save explore cache: $e');
    }
  }

  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {
    _log.i('fetchHomeFeed called, forceRefresh=$forceRefresh');

    if (ref.read(settingsProvider).homeFeedProvider ==
        AppSettings.homeFeedProviderOff) {
      _log.d('Home feed disabled by user setting');
      _homeFeedRequestId++;
      PlatformBridge.cancelExtensionHomeFeedRequests();
      state = const ExploreState();
      return;
    }

    if (ref.read(settingsProvider).homeFeedProvider ==
        AppSettings.homeFeedProviderSpotifyPersonal) {
      await _fetchSpotifyPersonalHomeFeed(forceRefresh: forceRefresh);
      return;
    }

    if (!forceRefresh &&
        state.hasContent &&
        state.lastFetched != null &&
        DateTime.now().difference(state.lastFetched!).inMinutes < 5) {
      _log.d('Using cached home feed (fresh enough)');
      return;
    }

    if (state.isLoading && !forceRefresh) {
      _log.d('Home feed fetch already in progress');
      return;
    }

    final requestId = ++_homeFeedRequestId;
    final showLoading = !state.hasContent;
    state = state.copyWith(isLoading: showLoading, error: null);

    try {
      final extState = ref.read(extensionProvider);
      final settings = ref.read(settingsProvider);
      final preferredId = settings.homeFeedProvider;
      _log.d(
        'Extensions count: ${extState.extensions.length}, preferred home feed: $preferredId',
      );

      final targetExt = _resolveHomeFeedExtension();

      if (targetExt == null) {
        _log.w('No extension with homeFeed capability found');
        if (requestId != _homeFeedRequestId) return;
        state = state.copyWith(
          isLoading: false,
          error: 'No extension with home feed support enabled',
        );
        return;
      }

      _log.i('Fetching home feed from ${targetExt.id}...');
      final result = await PlatformBridge.getExtensionHomeFeed(
        targetExt.id,
        cancelPrevious: forceRefresh,
      );
      if (requestId != _homeFeedRequestId) return;

      if (result == null) {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to fetch home feed',
        );
        return;
      }

      final success = result['success'] as bool? ?? false;
      _log.d('getExtensionHomeFeed success=$success');
      if (!success) {
        final error = result['error'] as String? ?? 'Unknown error';
        state = state.copyWith(isLoading: false, error: error);
        return;
      }

      final greeting = result['greeting'] as String?;
      final sectionsData = result['sections'] as List<dynamic>? ?? [];
      final normalizedSectionsWithoutProvider = await compute(
        _normalizeExploreSectionsPayload,
        sectionsData,
      );
      final normalizedSections = _withDefaultExploreProviderId(
        normalizedSectionsWithoutProvider,
        targetExt.id,
      );
      if (requestId != _homeFeedRequestId) return;
      final sections = _buildExploreSectionsFromNormalizedPayload(
        normalizedSections,
      );

      _log.i('Fetched ${sections.length} sections');

      if (sections.isNotEmpty && sections.first.items.isNotEmpty) {
        final firstItem = sections.first.items.first;
        _log.d(
          'First item: name=${firstItem.name}, artists=${firstItem.artists}, type=${firstItem.type}',
        );
      }

      final localGreeting = _getLocalGreeting();
      _log.d('Greeting from extension: $greeting, using local: $localGreeting');

      state = ExploreState(
        isLoading: false,
        greeting: localGreeting,
        providerId: targetExt.id,
        sections: sections,
        lastFetched: DateTime.now(),
      );

      _saveToCache(normalizedSections, targetExt.id);
    } catch (e, stack) {
      _log.e('Error fetching home feed: $e', e, stack);
      if (requestId != _homeFeedRequestId) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> _fetchSpotifyPersonalHomeFeed({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        state.hasContent &&
        state.lastFetched != null &&
        DateTime.now().difference(state.lastFetched!).inMinutes < 5) {
      return;
    }

    if (state.isLoading && !forceRefresh) {
      _log.d('Personalized Spotify home feed fetch already in progress');
      return;
    }

    final requestId = ++_homeFeedRequestId;
    state = state.copyWith(isLoading: !state.hasContent, error: null);

    final cookie = await const FlutterSecureStorage().read(
      key: spotifySessionCookieStorageKey,
    );
    if (cookie == null || cookie.isEmpty) {
      if (requestId != _homeFeedRequestId) return;
      state = state.copyWith(
        isLoading: false,
        error: 'Log in to Spotify to see your personalized feed',
      );
      return;
    }

    try {
      final result = await PlatformBridge.getSpotifyPersonalHomeFeed(cookie);
      if (requestId != _homeFeedRequestId) return;

      if (result == null || result['success'] != true) {
        state = state.copyWith(
          isLoading: false,
          error:
              result?['error'] as String? ??
              'Failed to fetch personalized home feed',
        );
        return;
      }

      final greeting = result['greeting'] as String?;
      final sectionsData = result['sections'] as List<dynamic>? ?? [];
      final normalizedSections = await compute(
        _normalizeExploreSectionsPayload,
        sectionsData,
      );
      if (requestId != _homeFeedRequestId) return;
      final sections = _buildExploreSectionsFromNormalizedPayload(
        normalizedSections,
      );

      // providerId is deliberately left null (and cached as empty) rather
      // than set to the `spotify-personal` settings sentinel. Consumers —
      // notably home_tab's `_providerIdForExploreItem` — treat this field as
      // a real installed-extension id and hand it to
      // ExtensionAlbumScreen/ExtensionPlaylistScreen/`Track.source`. There is
      // no extension backing this first-party feed, so a null id is what
      // routes item taps to the existing graceful "no provider" message
      // instead of failing against a nonexistent extension.
      state = ExploreState(
        isLoading: false,
        greeting: greeting ?? _getLocalGreeting(),
        sections: sections,
        lastFetched: DateTime.now(),
      );
      _saveToCache(normalizedSections, '');
    } catch (e) {
      _log.e('Error fetching personalized Spotify home feed: $e');
      if (requestId != _homeFeedRequestId) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  void clear() {
    _homeFeedRequestId++;
    PlatformBridge.cancelExtensionHomeFeedRequests();
    state = const ExploreState();
  }

  Future<void> refresh() => fetchHomeFeed(forceRefresh: true);
}

final exploreProvider = NotifierProvider<ExploreNotifier, ExploreState>(() {
  return ExploreNotifier();
});
