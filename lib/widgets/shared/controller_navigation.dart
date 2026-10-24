import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Extends Flutter's existing focus/activation model to controller buttons.
/// Child controls (including the player) can handle a key before this fallback.
class ControllerNavigation extends StatelessWidget {
  const ControllerNavigation({
    required this.onBack,
    required this.child,
    super.key,
  });

  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ButtonStyle focusedStyle(ButtonStyle? style) => (style ?? const ButtonStyle()).copyWith(
          side: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused)
              ? BorderSide(color: theme.colorScheme.primary, width: 2.5)
              : style?.side?.resolve(states)),
        );
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.gameButtonA, includeRepeats: false): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select, includeRepeats: false): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonB, includeRepeats: false): _ControllerBackIntent(),
        SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): _ControllerBackIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ControllerBackIntent: CallbackAction<_ControllerBackIntent>(onInvoke: (_) {
            onBack();
            return null;
          }),
        },
        child: Theme(
          data: theme.copyWith(
            iconButtonTheme: IconButtonThemeData(style: focusedStyle(theme.iconButtonTheme.style)),
            textButtonTheme: TextButtonThemeData(style: focusedStyle(theme.textButtonTheme.style)),
            filledButtonTheme: FilledButtonThemeData(style: focusedStyle(theme.filledButtonTheme.style)),
            elevatedButtonTheme: ElevatedButtonThemeData(style: focusedStyle(theme.elevatedButtonTheme.style)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ControllerBackIntent extends Intent {
  const _ControllerBackIntent();
}

/// Keep the invoking card/control selected when a route or dialog closes.
/// A removed or no-longer-visible opener is deliberately left to Flutter's
/// own focus scope restoration.
class ControllerFocusObserver extends NavigatorObserver {
  ControllerFocusObserver({required this.enabled});

  final bool Function() enabled;
  final Map<Route<dynamic>, FocusNode> _openers = {};

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final opener = FocusManager.instance.primaryFocus;
    if (previousRoute != null && opener != null && opener is! FocusScopeNode) {
      _openers[route] = opener;
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final opener = _openers.remove(route);
    if (opener == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (enabled() && previousRoute?.isCurrent == true && opener.context?.mounted == true && opener.canRequestFocus) {
        opener.requestFocus();
        final context = opener.context!;
        Scrollable.ensureVisible(context, duration: Duration.zero);
      }
    });
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _openers.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final opener = _openers.remove(oldRoute);
    if (newRoute != null && opener != null) _openers[newRoute] = opener;
  }
}
