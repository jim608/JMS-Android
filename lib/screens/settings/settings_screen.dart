import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/providers/arguments_provider.dart';
import 'package:fladder/providers/auth_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/settings/quick_connect_window.dart';
import 'package:fladder/screens/settings/settings_list_tile.dart';
import 'package:fladder/screens/settings/settings_scaffold.dart';
import 'package:fladder/screens/shared/default_alert_dialog.dart';
import 'package:fladder/screens/shared/fladder_icon.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/jms_smooth_scroll.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/theme_extensions.dart';
import 'package:fladder/util/window_actions.dart';
import 'package:fladder/widgets/shared/tab_back_gesture.dart';

@RoutePage()
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final scrollController = JmsSmoothScrollController();
  final minVerticalPadding = 20.0;
  late LayoutMode lastAdaptiveLayout = AdaptiveLayout.layoutModeOf(context);

  @override
  Widget build(BuildContext context) {
    final classic = ref.watch(classicInterfaceProvider);
    return AutoTabsRouter(
      builder: (context, content) {
        _selectDefaultDesktopTab(context);
        return PopScope(
          canPop: context.tabsRouter.activeIndex == 0 || AdaptiveLayout.layoutModeOf(context) == LayoutMode.dual,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              context.tabsRouter.setActiveIndex(0);
            }
          },
          child: AdaptiveLayout.layoutModeOf(context) == LayoutMode.single
              ? Card(
                  elevation: 0,
                  child: Stack(
                    children: [
                      _leftPane(context, classic),
                      TabBackGesture(
                        enabled: context.tabsRouter.activeIndex != 0,
                        onBack: () => context.tabsRouter.setActiveIndex(0),
                        child: content,
                      ),
                    ],
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final categoryWidth = constraints.maxWidth * 0.4;
                    return Row(
                      mainAxisSize: MainAxisSize.max,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: classic
                              ? categoryWidth
                              : categoryWidth.clamp(0.0, AdaptiveLayout.of(context).sideBarWidth + 336),
                          child: _leftPane(context, classic),
                        ),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(left: MediaQuery.paddingOf(context).left),
                            child: content,
                          ),
                        ),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }

  void _selectDefaultDesktopTab(BuildContext context) {
    if (AdaptiveLayout.layoutModeOf(context) != LayoutMode.dual || context.tabsRouter.activeIndex != 0) return;

    // Switch after the scheduler is idle so lazy tab loading and router notification stay in sync.
    WidgetsBinding.instance.endOfFrame.then((_) {
      if (context.mounted &&
          AdaptiveLayout.layoutModeOf(context) == LayoutMode.dual &&
          context.tabsRouter.activeIndex == 0) {
        context.tabsRouter.setActiveIndex(1);
      }
    });
  }

  IconData get deviceIcon {
    if (AdaptiveLayout.of(context).isDesktop) {
      return IconsaxPlusLinear.monitor;
    }
    switch (AdaptiveLayout.viewSizeOf(context)) {
      case ViewSize.phone:
        return IconsaxPlusLinear.mobile;
      case ViewSize.tablet:
        return IconsaxPlusLinear.monitor;
      case ViewSize.desktop:
        return IconsaxPlusLinear.monitor;
      case ViewSize.television:
        return IconsaxPlusLinear.mirroring_screen;
    }
  }

  Widget _leftPane(BuildContext context, bool classic) {
    void navigateTo(PageRouteInfo route) => context.tabsRouter.navigate(route);

    bool containsRoute(PageRouteInfo route) =>
        AdaptiveLayout.layoutModeOf(context) == LayoutMode.dual && context.tabsRouter.current.name == route.routeName;

    final quickConnectAvailable = ref.watch(
      userProvider.select((value) => value?.serverConfiguration?.quickConnectAvailable ?? false),
    );

    final newRelease = kIsWeb ? null : ref.watch(updateProvider.select((value) => value.latestRelease));

    final hasNewUpdate = ref.watch(hasNewUpdateProvider);

    final isAdmin = ref.watch(userProvider.select((value) => value?.policy?.isAdministrator ?? false));

    Widget? categoryIndicator(bool selected) => classic
        ? null
        : Icon(
            selected ? Icons.check_rounded : Icons.chevron_right,
            size: 20,
            color: selected ? context.colors.primary : context.colors.onSurfaceVariant,
          );

    Widget category(
      PageRouteInfo route,
      String label, {
      String? description,
      IconData? icon,
      Widget? leading,
      bool autoFocus = false,
    }) {
      final selected = containsRoute(route);
      final tile = SettingsListTile(
        label: Text(label),
        subLabel: classic || description == null
            ? null
            : Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
              ),
        icon: icon,
        leading: leading,
        trailing: categoryIndicator(selected),
        autoFocus: autoFocus,
        selected: selected,
        onTap: () => navigateTo(route),
      );
      return classic
          ? tile
          : MergeSemantics(
              child: Semantics(button: true, selected: selected, child: tile),
            );
    }

    final categories = [
      category(
        const ClientSettingsRoute(),
        context.localized.general,
        description: context.localized.settingsClientDesc,
        autoFocus: true,
        icon: deviceIcon,
      ),
      if (isAdmin)
        SettingsListTile(
          label: Text(context.localized.controlPanel),
          subLabel: Text(context.localized.controlPanelDesc),
          selected: containsRoute(const ControlPanelSelectionRoute()),
          icon: IconsaxPlusLinear.chart_3,
          trailing: categoryIndicator(containsRoute(const ControlPanelSelectionRoute())),
          onTap: () => const ControlPanelSelectionRoute().navigate(context),
        ),
      category(
        const ProfileSettingsRoute(),
        context.localized.settingsProfileTitle,
        description: context.localized.settingsProfileDesc,
        icon: IconsaxPlusLinear.security_user,
      ),
      category(
        const PlayerSettingsRoute(),
        context.localized.settingsPlayerTitle,
        description: context.localized.settingsPlayerDesc,
        icon: IconsaxPlusLinear.video_play,
      ),
      category(
        const AboutSettingsRoute(),
        context.localized.about,
        leading: FladderIconOutlined(size: 24, color: context.colors.onSurfaceVariant),
      ),
    ];

    return Padding(
      padding: EdgeInsetsDirectional.only(start: AdaptiveLayout.of(context).sideBarWidth),
      child: Container(
        color: context.colors.surface,
        child: SettingsScaffold(
          label: context.localized.settings,
          scrollController: scrollController,
          showBackButtonNested: AdaptiveLayout.inputDeviceOf(context) != InputDevice.dPad,
          showUserIcon: true,
          items: [
            if (hasNewUpdate && newRelease != null) ...[
              Card(
                color: context.colors.secondaryContainer,
                child: SettingsListTile(
                  label: Text(context.localized.newReleaseFoundTitle(newRelease.version)),
                  subLabel: Text(context.localized.newUpdateFoundOnGithub),
                  icon: IconsaxPlusLinear.information,
                  onTap: () => navigateTo(const AboutSettingsRoute()),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (classic) ...[
              ...categories,
              const FractionallySizedBox(widthFactor: 0.25, child: Divider()),
            ] else
              Card.filled(
                margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                clipBehavior: Clip.antiAlias,
                child: Column(children: categories),
              ),
            if (quickConnectAvailable)
              SettingsListTile(
                label: Text(context.localized.settingsQuickConnectTitle),
                icon: IconsaxPlusLinear.password_check,
                onTap: () => openQuickConnectDialog(context),
              ),
            if (ref.watch(argumentsStateProvider.select((value) => value.htpcMode)))
              SettingsListTile(
                label: Text(context.localized.exitFladderTitle),
                icon: IconsaxPlusLinear.close_square,
                onTap: () async {
                  showDefaultAlertDialog(
                    context,
                    context.localized.exitFladderTitle,
                    context.localized.exitFladderDesc,
                    (context) async {
                      if (AdaptiveLayout.of(context).isDesktop) {
                        await quitApplication(context);
                      } else {
                        SystemNavigator.pop();
                      }
                    },
                    context.localized.close,
                    (context) => context.pop(),
                    context.localized.cancel,
                  );
                },
              ),
            SettingsListTile(
              label: Text(context.localized.switchUser),
              icon: IconsaxPlusLinear.arrow_swap_horizontal,
              contentColor: classic ? Colors.greenAccent : context.colors.primary,
              onTap: () async {
                await ref.read(userProvider.notifier).logoutUser();
                context.router.replaceAll([LoginRoute()]);
              },
            ),
            SettingsListTile(
              label: Text(context.localized.logout),
              icon: IconsaxPlusLinear.logout,
              contentColor: Theme.of(context).colorScheme.error,
              onTap: () {
                final user = ref.read(userProvider);
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(context.localized.logoutUserPopupTitle(user?.name ?? "")),
                    scrollable: true,
                    content: Text(
                      context.localized.logoutUserPopupContent(user?.name ?? "", user?.credentials.url ?? ""),
                    ),
                    actions: [
                      ElevatedButton(onPressed: () => Navigator.pop(context), child: Text(context.localized.cancel)),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom().copyWith(
                          iconColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.onErrorContainer),
                          foregroundColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.onErrorContainer),
                          backgroundColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.errorContainer),
                        ),
                        onPressed: () async {
                          await ref.read(authProvider.notifier).logOutUser();
                          if (context.mounted) {
                            context.router.replaceAll([LoginRoute()]);
                          }
                        },
                        child: Text(context.localized.logout),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
