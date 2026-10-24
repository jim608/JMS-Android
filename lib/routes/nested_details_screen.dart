import 'package:flutter/material.dart';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/items/item_details_provider.dart';
import 'package:fladder/providers/discord_browsing_provider.dart';
import 'package:fladder/providers/discord_presence_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/services/discord/discord_activity.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/shared/detail_load_state.dart';
import 'package:fladder/util/fladder_image.dart';
import 'package:fladder/util/router_extension.dart';

@RoutePage()
class DetailsScreen extends ConsumerStatefulWidget {
  final String id;
  final ItemBaseModel? item;
  final Object? tag;
  const DetailsScreen({
    @QueryParam() this.id = '',
    this.item,
    this.tag,
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  late Widget currentWidget = _loadState(loading: true);
  int _requestGeneration = 0;
  bool _loading = false;

  Widget _loadState({required bool loading}) => DetailLoadState(
        key: ValueKey(loading),
        loading: loading,
        onBack: _back,
        onRetry: () => _loadDetails(probe: true),
      );

  Future<void> _back() async {
    if (!await context.router.popBack() && mounted) {
      const DashboardRoute().navigate(context);
    }
  }

  @override
  void didUpdateWidget(covariant DetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id || oldWidget.item != widget.item) {
      Future.microtask(() => _loadDetails(restart: true));
    }
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadDetails);
  }

  Future<void> _loadDetails({bool restart = false, bool probe = false}) async {
    if (!mounted || (_loading && !restart)) return;
    final generation = ++_requestGeneration;
    _loading = true;
    setState(() => currentWidget = _loadState(loading: true));
    try {
      var response = widget.item;
      if (response == null) {
        if (widget.id.trim().isEmpty) throw StateError('Missing item ID');
        if (probe) {
          final connectivity = ref.read(connectivityStatusProvider.notifier);
          await connectivity.checkConnectivity(immediate: true);
          await connectivity.waitForProbe();
          if (!mounted || generation != _requestGeneration) return;
        }
        final routeId = context.routeData.route.id;
        final scope = discordAccountScope(ref.read(userProvider));
        response = await ref
            .read(itemDetailsProvider.notifier)
            .fetchDetails(widget.id);
        if (!mounted || generation != _requestGeneration) return;
        if (response != null) {
          ref.read(discordBrowsingProvider.notifier).resolveDetails(
                routeId: routeId,
                scope: scope,
                snapshot: DiscordBrowsingSnapshot.details(
                  title: response.title,
                  artworkItemId: discordArtworkItemId(response),
                ),
              );
        }
      }
      if (!mounted || generation != _requestGeneration) return;
      final next = response?.detailScreenWidget ?? _loadState(loading: false);
      setState(() => currentWidget = next);
    } catch (_) {
      if (!mounted || generation != _requestGeneration) return;
      // Do not expose transport errors, which can include authenticated URLs.
      setState(() => currentWidget = _loadState(loading: false));
    } finally {
      if (mounted && generation == _requestGeneration) _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: Key(widget.id),
      children: [
        Hero(
          tag: widget.tag ?? UniqueKey(),
          child: Container(
            decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: 1.0),
            ),
            child: Transform.translate(
                offset: const Offset(0, -5),
                child: FladderImage(image: widget.item?.getPosters?.primary)),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(seconds: 1),
          child: currentWidget,
        )
      ],
    );
  }
}
