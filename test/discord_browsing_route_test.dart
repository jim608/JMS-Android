import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/providers/discord_browsing_provider.dart';
import 'package:fladder/services/discord/discord_activity.dart';

const _resolved = DiscordBrowsingSnapshot.details(
  title: 'Synthetic resolved movie',
  artworkItemId: 'synthetic-item',
  artworkUrl: 'https://image.tmdb.org/t/p/w500/Synthetic.jpg',
);
const _blank = DiscordBrowsingSnapshot.details(title: '');

void main() {
  late DiscordBrowsingRoute route;
  setUp(() => route = DiscordBrowsingRoute());
  tearDown(() => route.dispose());

  void activate(Object? id, DiscordBrowsingSnapshot? snapshot,
          {String? scope = 'synthetic-account', bool blocked = false}) =>
      route.activate(
          routeId: id, scope: scope, snapshot: snapshot, blocked: blocked);

  void resolve(Object id, DiscordBrowsingSnapshot snapshot,
          {String? scope = 'synthetic-account'}) =>
      route.resolveDetails(routeId: id, scope: scope, snapshot: snapshot);

  test(
      'selection and route blocking are explicit and blocking survives resolve',
      () {
    expect(route.state.snapshot, isNull);
    expect(route.state.blocked, isFalse);
    final id = Object();
    activate(id, const DiscordBrowsingSnapshot.selecting());
    expect(route.state.snapshot!.viewingDetails, isFalse);
    activate(id, _blank, blocked: true);
    resolve(id, _resolved);
    expect(route.state.blocked, isTrue);
    expect(route.state.snapshot, same(_resolved));
    activate(Object(), const DiscordBrowsingSnapshot.selecting());
    expect(route.state.blocked, isFalse);
  });

  test('separate route IDs cannot share metadata even for the same page key',
      () {
    // Two visits can use the same widget/page key but have different route.id.
    final firstId = Object();
    final secondId = Object();
    activate(firstId, _blank);
    resolve(firstId, _resolved);
    activate(secondId, _blank);
    expect(route.state.routeId, same(secondId));
    expect(route.state.snapshot!.title, isEmpty);
    resolve(firstId, _resolved);
    expect(route.state.routeId, same(secondId));
    expect(route.state.snapshot!.title, isEmpty);
  });

  test(
      'leaving details prevents delayed resolution from restoring its activity',
      () {
    final detailsId = Object();
    final homeId = Object();
    activate(detailsId, _blank);
    activate(homeId, const DiscordBrowsingSnapshot.selecting());
    resolve(detailsId, _resolved);
    expect(route.state.routeId, same(homeId));
    expect(route.state.snapshot!.viewingDetails, isFalse);
    expect(route.state.snapshot!.title, isEmpty);
    // A stale details callback also cannot change a selecting route with its ID.
    resolve(homeId, _resolved);
    expect(route.state.snapshot!.viewingDetails, isFalse);
  });

  test('same route URL rebuild retains resolved title and artwork', () {
    final id = Object();
    activate(id, _blank);
    resolve(id, _resolved);
    activate(id, _blank);
    expect(route.state.snapshot, same(_resolved));
    expect(route.state.snapshot!.artworkItemId, _resolved.artworkItemId);
    expect(route.state.snapshot!.artworkUrl, _resolved.artworkUrl);
  });

  test(
      'returning to a maintained details route restores only its cached metadata',
      () {
    final firstId = Object();
    final secondId = Object();
    activate(firstId, _blank);
    resolve(firstId, _resolved);
    activate(Object(), const DiscordBrowsingSnapshot.selecting());
    activate(secondId,
        const DiscordBrowsingSnapshot.details(title: 'Synthetic other'));
    activate(firstId, _blank);
    expect(route.state.snapshot, same(_resolved));
  });

  test('account scope changes clear cache and ignore old account callbacks',
      () {
    final id = Object();
    activate(id, _blank);
    resolve(id, _resolved);
    activate(id, _blank, scope: 'synthetic-next-account');
    expect(route.state.snapshot!.title, isEmpty);
    resolve(id, _resolved);
    expect(route.state.snapshot!.title, isEmpty);
    activate(id, _blank);
    expect(route.state.snapshot!.title, isEmpty);
  });

  test('resolved route cache evicts the oldest after seventeen resolutions',
      () {
    final ids = List.generate(17, (_) => Object());
    for (var index = 0; index < ids.length; index++) {
      activate(ids[index], _blank);
      resolve(ids[index],
          DiscordBrowsingSnapshot.details(title: 'Synthetic $index'));
    }
    activate(ids.first, _blank);
    expect(route.state.snapshot!.title, isEmpty);
    activate(ids.last, _blank);
    expect(route.state.snapshot!.title, 'Synthetic 16');
  });

  test('cleared route cannot be resurrected by delayed details', () {
    final id = Object();
    activate(id, _blank);
    activate(null, null, scope: null, blocked: true);
    resolve(id, _resolved);
    expect(route.state.routeId, isNull);
    expect(route.state.snapshot, isNull);
    expect(route.state.blocked, isTrue);
  });
}
