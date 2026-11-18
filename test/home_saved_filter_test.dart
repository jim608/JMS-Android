import 'dart:async';

import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/library_filter_model.dart';
import 'package:fladder/models/library_filters_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/home_saved_filters_provider.dart';
import 'package:fladder/providers/library_search_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _User extends User {
  _User(this.initial);
  final AccountModel initial;

  @override
  AccountModel? build() => initial;

  @override
  set userState(AccountModel? account) => state = account;
}

class _Api extends JellyApi {
  _Api(this.service);
  final JellyService service;

  @override
  JellyService build() => service;
}

class _Service implements JellyService {
  final requests = <Map<Symbol, dynamic>>[];
  final replies = <Completer<Response<ServerQueryResult>>>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #usersUserIdViewsGet:
        return Future.value(Response(http.Response('', 200), const BaseItemDtoQueryResult()));
      case #itemsGet:
        requests.add(invocation.namedArguments);
        final reply = Completer<Response<ServerQueryResult>>();
        replies.add(reply);
        return reply.future;
      default:
        throw UnsupportedError('Unexpected operation ${invocation.memberName}');
    }
  }

  void respond(int index, List<String> ids, {int status = 200}) {
    replies[index].complete(Response(
      http.Response('', status),
      ServerQueryResult(
        items: [
          for (final id in ids) MovieModel.fromBaseDto(BaseItemDto(id: id, name: id), null),
        ],
      ),
    ));
  }
}

const _filter = LibraryFilterModel(
  itemFilters: {ItemFilter.isunplayed: true},
  officialRatings: {'PG': true},
  tags: {'Animation': true},
);

LibraryFiltersModel _preset({String id = 'animation', List<String> parents = const [], bool pinned = true}) =>
    LibraryFiltersModel(
      id: id,
      name: id,
      ids: parents,
      isFavourite: true,
      showInSideBar: true,
      showOnHome: pinned,
      filter: _filter,
    );

AccountModel _account(String id, List<LibraryFiltersModel> filters) => AccountModel(
      name: id,
      id: id,
      avatar: '',
      lastUsed: DateTime(2026),
      credentials: CredentialsModel(token: id, url: 'https://fixture.invalid'),
      libraryFilters: filters,
    );

ProviderContainer _container(_Service service, List<LibraryFiltersModel> presets) => ProviderContainer(overrides: [
      jellyApiProvider.overrideWith(() => _Api(service)),
      offlineStateProvider.overrideWithValue(false),
      serverUrlProvider.overrideWith((_) => 'https://fixture.invalid'),
      userProvider.overrideWith(() => _User(_account('account-a', presets))),
    ]);

Future<void> _nextTurn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a saved filter persists its home pin separately from sidebar visibility', () {
    final legacy = <String, dynamic>{
      'id': 'synthetic-preset',
      'name': 'Unfinished animation',
      'isFavourite': true,
      'showInSideBar': true,
      'ids': ['animation'],
    };

    final pinned = LibraryFiltersModel.fromJson({...legacy, 'showOnHome': true});
    expect(pinned.toJson()['showOnHome'], isTrue);
    expect(pinned.showInSideBar, isTrue);
    expect(pinned.isFavourite, isTrue);
    expect(LibraryFiltersModel.fromJson(legacy).toJson()['showOnHome'], isFalse);
  });

  test('legacy local pins and server placements resolve together in the requested order', () {
    final legacy = _preset().copyWith(id: 'legacy', showInSideBar: true);
    final server = _preset(pinned: false).copyWith(
      id: 'server',
      showInSideBar: false,
      sortKeys: {FilterSortKey.dashboard: true},
    );
    final user = _account('account-a', [legacy]).copyWith(
      userSettings: UserSettings(
        libraryFilters: [server],
        filterSortOrder: {
          FilterSortKey.dashboard: ['legacy', 'server'],
        },
      ),
    );
    final filters = user.userSettings!.copyWith(libraryFilters: user.savedLibraryFilters);
    expect(filters.getFilterSortOrder(FilterSortKey.dashboard).map((item) => item.id), ['legacy', 'server']);
    expect(filters.getFilterSortOrder(FilterSortKey.sideBar).single.id, 'legacy');
    final unpinned = legacy.copyWith(sortKeys: {FilterSortKey.dashboard: false});
    expect(unpinned.placements[FilterSortKey.dashboard], isFalse);
    expect(unpinned.placements[FilterSortKey.sideBar], isTrue);
  });

  test('home preview keeps the saved predicates, parent, and display limit', () async {
    final service = _Service();
    final container = _container(service, [_preset(parents: ['saved-library'])]);
    addTearDown(container.dispose);
    final provider = homeSavedFilterPreviewProvider('animation');
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);

    final preview = container.read(provider.future);
    expect(service.requests.single[#parentId], 'saved-library');
    expect(service.requests.single[#limit], homeSavedFilterPreviewLimit);
    expect(service.requests.single[#enableTotalRecordCount], false);
    expect(service.requests.single[#officialRatings], ['PG']);
    expect(service.requests.single[#tags], ['Animation']);
    expect(service.requests.single[#filters], [ItemFilter.isunplayed]);
    service.respond(0, List.generate(20, (index) => 'movie-$index'));
    expect(await preview, hasLength(homeSavedFilterPreviewLimit));

    final user = container.read(userProvider.notifier);
    user.setFilterOnHome('animation', showOnHome: false);
    await container.pump();
    expect(await container.read(provider.future), isEmpty);
    expect(service.requests, hasLength(1));
    final saved = container.read(userProvider)!.libraryFilters.single;
    expect(saved.showInSideBar, isTrue);
    expect(saved.isFavourite, isTrue);
    expect(saved.filter, _filter);
  });

  test('an inaccessible parent does not widen the preview to all libraries', () async {
    final service = _Service();
    final container = _container(service, [_preset(parents: ['gone'])]);
    addTearDown(container.dispose);
    final provider = homeSavedFilterPreviewProvider('animation');
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);

    final preview = container.read(provider.future);
    final error = expectLater(preview, throwsStateError);
    service.respond(0, [], status: 403);
    await error;
    expect(service.requests.map((request) => request[#parentId]), ['gone']);
  });

  test('preview ignores an older response after an account switch', () async {
    final service = _Service();
    final container = _container(service, [_preset()]);
    addTearDown(container.dispose);
    final provider = homeSavedFilterPreviewProvider('animation');
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    final old = container.read(provider.future);
    unawaited(old.then<void>((_) {}, onError: (Object _) {}));

    (container.read(userProvider.notifier) as _User).userState = _account('account-b', [_preset()]);
    await container.pump();
    final newPreview = container.read(provider.future);
    service.respond(1, ['account-b-item']);
    expect((await newPreview).single.id, 'account-b-item');
    service.respond(0, ['account-a-item']);
    await _nextTurn();

    expect(container.read(provider).requireValue.single.id, 'account-b-item');
  });

  test('opening a global saved filter preserves its rules with an empty keyword', () async {
    final service = _Service();
    final container = _container(service, [_preset()]);
    addTearDown(container.dispose);
    final provider = librarySearchProvider(const ValueKey('explicit-saved-filter'));
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);

    final load = container.read(provider.notifier).initRefresh(parentIds: [], filters: _filter, savedFilter: true);
    await _nextTurn();
    expect(service.requests.single[#parentId], isNull);
    expect(service.requests.single[#officialRatings], ['PG']);
    expect(service.requests.single[#tags], ['Animation']);
    expect(service.requests.single[#filters], [ItemFilter.isunplayed]);
    service.respond(0, ['matched']);
    await load;

    expect(container.read(provider).posters.single.id, 'matched');
  });
}
