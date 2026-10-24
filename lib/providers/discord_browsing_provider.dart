import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/services/discord/discord_activity.dart';

final discordBrowsingProvider =
    StateNotifierProvider<DiscordBrowsingRoute, DiscordBrowsingRouteState>((ref) => DiscordBrowsingRoute());

class DiscordBrowsingRouteState {
  const DiscordBrowsingRouteState({this.routeId, this.scope, this.snapshot, this.blocked = false});

  final Object? routeId;
  final String? scope;
  final DiscordBrowsingSnapshot? snapshot;
  final bool blocked;
}

/// Route identity, rather than a maintained widget's disposal, owns presence.
class DiscordBrowsingRoute extends StateNotifier<DiscordBrowsingRouteState> {
  DiscordBrowsingRoute() : super(const DiscordBrowsingRouteState());

  final _resolved = <Object, DiscordBrowsingSnapshot>{};

  void activate({
    required Object? routeId,
    required String? scope,
    required DiscordBrowsingSnapshot? snapshot,
    bool blocked = false,
  }) {
    if (state.scope != scope) _resolved.clear();
    // URL rebuilds and returning to a maintained deep-link page preserve only
    // metadata resolved for that exact route and account.
    var resolved = snapshot;
    if (routeId != null && snapshot?.viewingDetails == true) {
      if (snapshot!.title.isEmpty) {
        resolved = _resolved[routeId] ?? snapshot;
      } else {
        _resolved[routeId] = snapshot;
      }
    }
    if (_resolved.length > 16) _resolved.remove(_resolved.keys.first);
    state = DiscordBrowsingRouteState(routeId: routeId, scope: scope, snapshot: resolved, blocked: blocked);
  }

  void resolveDetails({
    required Object routeId,
    required String? scope,
    required DiscordBrowsingSnapshot snapshot,
  }) {
    // Late requests from a previous page/account must never restore its title.
    if (state.routeId != routeId ||
        state.scope != scope ||
        state.snapshot?.viewingDetails != true ||
        !snapshot.viewingDetails) {
      return;
    }
    _resolved[routeId] = snapshot;
    if (_resolved.length > 16) _resolved.remove(_resolved.keys.first);
    state = DiscordBrowsingRouteState(routeId: routeId, scope: scope, snapshot: snapshot, blocked: state.blocked);
  }
}
