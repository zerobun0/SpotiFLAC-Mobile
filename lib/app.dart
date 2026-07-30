import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:spotiflac_android/constants/app_info.dart';
import 'package:spotiflac_android/screens/main_shell.dart';
import 'package:spotiflac_android/screens/setup_screen.dart';
import 'package:spotiflac_android/screens/spotify/spotify_login_screen.dart';
import 'package:spotiflac_android/screens/tutorial_screen.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/app_navigation_service.dart';
import 'package:spotiflac_android/theme/dynamic_color_wrapper.dart';
import 'package:spotiflac_android/l10n/app_localizations.dart';

String initialLocationForAppState({
  required bool isFirstLaunch,
  required bool hasCompletedTutorial,
}) {
  if (isFirstLaunch) return '/setup';
  if (!hasCompletedTutorial) return '/tutorial';
  return '/';
}

final _routerProvider = Provider<GoRouter>((ref) {
  final routingSettings = ref.watch(
    settingsProvider.select(
      (settings) => (
        isFirstLaunch: settings.isFirstLaunch,
        hasCompletedTutorial: settings.hasCompletedTutorial,
      ),
    ),
  );

  final initialLocation = initialLocationForAppState(
    isFirstLaunch: routingSettings.isFirstLaunch,
    hasCompletedTutorial: routingSettings.hasCompletedTutorial,
  );

  return GoRouter(
    navigatorKey: AppNavigationService.rootNavigatorKey,
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (context, state) => const MainShell()),
      GoRoute(path: '/setup', builder: (context, state) => const SetupScreen()),
      GoRoute(
        path: '/tutorial',
        builder: (context, state) => const TutorialScreen(),
      ),
      GoRoute(
        path: '/spotify',
        builder: (context, state) => const SpotifyLoginScreen(),
      ),
    ],
    // Safety net: if a deep link URL (e.g. Spotify/Deezer) somehow reaches
    // GoRouter, redirect to home instead of showing "Page Not Found".
    errorBuilder: (context, state) => const MainShell(),
  );
});

Locale _fallbackLocale(Iterable<Locale> supportedLocales) {
  for (final supportedLocale in supportedLocales) {
    if (supportedLocale.languageCode == 'en') {
      return supportedLocale;
    }
  }
  return supportedLocales.first;
}

Locale _resolveSupportedLocale(
  Locale? requestedLocale,
  Iterable<Locale> supportedLocales,
) {
  if (requestedLocale == null) {
    return _fallbackLocale(supportedLocales);
  }

  for (final supportedLocale in supportedLocales) {
    if (supportedLocale.languageCode == requestedLocale.languageCode &&
        supportedLocale.countryCode == requestedLocale.countryCode) {
      return supportedLocale;
    }
  }

  for (final supportedLocale in supportedLocales) {
    if (supportedLocale.languageCode == requestedLocale.languageCode) {
      return supportedLocale;
    }
  }

  return _fallbackLocale(supportedLocales);
}

/// iOS-style fluid scroll everywhere: momentum glide + bounce instead of the
/// Android clamping stop. Widgets that set explicit physics (queue filter
/// PageView, bottom sheets) are unaffected.
class _FluidScrollBehavior extends MaterialScrollBehavior {
  const _FluidScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}

/// Fades the app content in after an orientation change or a width change
/// across the shell's rail breakpoint (fold/unfold, split-screen resize) —
/// Flutter reflows the layout in a single frame, so without this the new
/// layout pops in.
class _OrientationFade extends StatefulWidget {
  final Widget child;

  const _OrientationFade({required this.child});

  @override
  State<_OrientationFade> createState() => _OrientationFadeState();
}

class _OrientationFadeState extends State<_OrientationFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: 1,
  );
  // Matches the shell's NavigationRail breakpoint.
  static const double _railBreakpoint = 600;

  Orientation? _lastOrientation;
  double? _lastWidth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final orientation = MediaQuery.orientationOf(context);
    final width = MediaQuery.sizeOf(context).width;
    final orientationChanged =
        _lastOrientation != null && orientation != _lastOrientation;
    final crossedRailBreakpoint =
        _lastWidth != null &&
        (_lastWidth! < _railBreakpoint) != (width < _railBreakpoint);
    if (orientationChanged || crossedRailBreakpoint) {
      _controller.forward(from: 0);
    }
    _lastOrientation = orientation;
    _lastWidth = width;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
      child: widget.child,
    );
  }
}

class SpotiFLACApp extends ConsumerWidget {
  final bool disableOverscrollEffects;

  const SpotiFLACApp({super.key, this.disableOverscrollEffects = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    final localeString = ref.watch(settingsProvider.select((s) => s.locale));
    final heroAnimationsEnabled = ref.watch(
      settingsProvider.select((s) => s.heroAnimationsEnabled),
    );
    final scrollBehavior = disableOverscrollEffects
        ? const MaterialScrollBehavior().copyWith(overscroll: false)
        : const _FluidScrollBehavior();

    Locale? locale;
    if (localeString != 'system' && localeString.isNotEmpty) {
      if (localeString.contains('_')) {
        final parts = localeString.split('_');
        if (parts.length == 2) {
          locale = Locale(parts[0], parts[1]);
        } else {
          locale = Locale(parts[0]);
        }
      } else {
        locale = Locale(localeString);
      }
    }

    return DynamicColorWrapper(
      builder: (lightTheme, darkTheme, themeMode) {
        return MaterialApp.router(
          title: AppInfo.appName,
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          scrollBehavior: scrollBehavior,
          themeAnimationDuration: const Duration(milliseconds: 300),
          themeAnimationCurve: Curves.easeInOut,
          // Treat the display as one continuous surface so bottom sheets and
          // dialogs stay centered on large/foldable devices.
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            final appContent = _OrientationFade(
              child: child ?? const SizedBox.shrink(),
            );
            return MediaQuery(
              data: mediaQuery.copyWith(displayFeatures: const []),
              // HeroMode only affects heroes below a *route* subtree. At this
              // level it sits above the router's Navigator, so the controller
              // never encounters it while collecting heroes. Removing the
              // inherited controller disables flights on the root Navigator.
              child: heroAnimationsEnabled
                  ? appContent
                  : HeroControllerScope.none(child: appContent),
            );
          },
          routerConfig: router,
          locale: locale,
          localeResolutionCallback: (deviceLocale, supportedLocales) {
            return _resolveSupportedLocale(
              locale ?? deviceLocale,
              supportedLocales,
            );
          },
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
        );
      },
    );
  }
}
