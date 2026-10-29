import 'dart:async';

import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/home_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/view_model.dart';
import 'package:fladder/models/views_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/dashboard_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _PendingService implements JellyService {
  final resumes = <Completer<Response<BaseItemDtoQueryResult>>>[];
  final next = <Completer<Response<BaseItemDtoQueryResult>>>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final List<Completer<Response<BaseItemDtoQueryResult>>> queue;
    switch (invocation.memberName) {
      case #usersUserIdItemsResumeGet:
        queue = resumes;
      case #showsNextUpGet:
        queue = next;
      default:
        throw UnsupportedError('Unexpected service operation ${invocation.memberName}');
    }
    final request = Completer<Response<BaseItemDtoQueryResult>>();
    queue.add(request);
    return request.future;
  }
}

class _Api extends JellyApi {
  _Api(this.service);
  final JellyService service;

  @override
  JellyService build() => service;
}

class _Views extends ViewsNotifier {
  _Views(super.ref) {
    state = ViewsModel(dashboardViews: [
      ViewModel(
        name: 'Synthetic movies',
        id: 'movies',
        serverId: 'synthetic-server',
        dateCreated: DateTime.utc(2026),
        canDelete: false,
        canDownload: false,
        parentId: '',
        collectionType: CollectionType.movies,
        playAccess: PlayAccess.full,
        recentlyAdded: const [],
        imageData: null,
        childCount: 0,
        path: null,
      ),
    ]);
  }
}

class _SeededDashboard extends DashboardNotifier {
  _SeededDashboard(super.ref, HomeModel initial) {
    state = initial;
  }
}

MovieModel _item(String id) => MovieModel.fromBaseDto(BaseItemDto(id: id, name: id, type: BaseItemKind.movie), null);

Response<BaseItemDtoQueryResult> _response(String id) => Response(
      http.Response('', 200),
      BaseItemDtoQueryResult(items: [BaseItemDto(id: id, name: id, type: BaseItemKind.movie)]),
    );

Future<void> _nextTurn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PendingService service;
  late ProviderContainer container;
  late HomeModel initial;

  setUp(() {
    service = _PendingService();
    initial = HomeModel(
      resumeVideo: [_item('old-video')],
      resumeAudio: [_item('old-audio')],
      resumeBooks: [_item('old-book')],
      activePrograms: [_item('old-program')],
      nextUp: [_item('old-next')],
    );
    container = ProviderContainer(overrides: [
      jellyApiProvider.overrideWith(() => _Api(service)),
      viewsProvider.overrideWith((ref) => _Views(ref)),
      dashboardProvider.overrideWith((ref) => _SeededDashboard(ref, initial)),
    ]);
    addTearDown(container.dispose);
  });

  test('late-stage failure releases loading, preserves every old row and allows retry', () async {
    final notifier = container.read(dashboardProvider.notifier);
    final request = notifier.fetchNextUpAndResume();
    expect(container.read(dashboardProvider).loading, isTrue);
    service.resumes.single.complete(_response('partial-video'));
    await _nextTurn();
    final failure = StateError('synthetic next-up failure');
    final failed = expectLater(request, throwsA(same(failure)));
    service.next.single.completeError(failure);
    await failed;

    final retained = container.read(dashboardProvider);
    expect(retained.loading, isFalse);
    expect(retained.resumeVideo, same(initial.resumeVideo));
    expect(retained.resumeAudio, same(initial.resumeAudio));
    expect(retained.resumeBooks, same(initial.resumeBooks));
    expect(retained.activePrograms, same(initial.activePrograms));
    expect(retained.nextUp, same(initial.nextUp));

    final retry = notifier.fetchNextUpAndResume();
    expect(service.resumes, hasLength(2));
    service.resumes.last.complete(_response('fresh-video'));
    await _nextTurn();
    service.next.last.complete(_response('fresh-next'));
    await retry;
    expect(container.read(dashboardProvider).loading, isFalse);
    expect(container.read(dashboardProvider).resumeVideo.single.id, 'fresh-video');
    expect(container.read(dashboardProvider).nextUp.single.id, 'fresh-next');
  });

  test('concurrent refresh is suppressed and a first-request failure permits retry', () async {
    final notifier = container.read(dashboardProvider.notifier);
    final request = notifier.fetchNextUpAndResume();
    await notifier.fetchNextUpAndResume();
    expect(service.resumes, hasLength(1));
    final failure = StateError('synthetic resume failure');
    final failed = expectLater(request, throwsA(same(failure)));
    service.resumes.single.completeError(failure);
    await failed;
    expect(container.read(dashboardProvider).loading, isFalse);

    final retry = notifier.fetchNextUpAndResume();
    expect(service.resumes, hasLength(2));
    service.resumes.last.complete(_response('retry-video'));
    await _nextTurn();
    service.next.single.complete(_response('retry-next'));
    await retry;
    expect(container.read(dashboardProvider).loading, isFalse);
  });

  test('clear invalidates an old success without publishing rows or unlocking a newer refresh', () async {
    final notifier = container.read(dashboardProvider.notifier);
    final older = notifier.fetchNextUpAndResume();
    notifier.clear();
    final newer = notifier.fetchNextUpAndResume();
    expect(service.resumes, hasLength(2));
    service.resumes.first.complete(_response('old-account-video'));
    await _nextTurn();
    expect(service.next, isEmpty);
    await older;
    expect(container.read(dashboardProvider).resumeVideo, isEmpty);
    expect(container.read(dashboardProvider).loading, isTrue);
    await notifier.fetchNextUpAndResume();
    expect(service.resumes, hasLength(2));

    service.resumes.last.complete(_response('new-account-video'));
    await _nextTurn();
    service.next.single.complete(_response('new-account-next'));
    await newer;
    expect(container.read(dashboardProvider).resumeVideo.single.id, 'new-account-video');
    expect(container.read(dashboardProvider).nextUp.single.id, 'new-account-next');
    expect(container.read(dashboardProvider).loading, isFalse);
  });

  test('failure from before clear cannot release a newer refresh loading flag', () async {
    final notifier = container.read(dashboardProvider.notifier);
    final older = notifier.fetchNextUpAndResume();
    notifier.clear();
    final newer = notifier.fetchNextUpAndResume();
    final failure = StateError('synthetic retired request failure');
    final failed = expectLater(older, throwsA(same(failure)));
    service.resumes.first.completeError(failure);
    await failed;
    expect(container.read(dashboardProvider).loading, isTrue);
    await notifier.fetchNextUpAndResume();
    expect(service.resumes, hasLength(2));

    service.resumes.last.complete(_response('current-video'));
    await _nextTurn();
    service.next.single.complete(_response('current-next'));
    await newer;
    expect(container.read(dashboardProvider).loading, isFalse);
  });

  test('clear during final request leaves cleared rows empty when it completes', () async {
    final notifier = container.read(dashboardProvider.notifier);
    final request = notifier.fetchNextUpAndResume();
    service.resumes.single.complete(_response('retired-video'));
    await _nextTurn();
    notifier.clear();
    service.next.single.complete(_response('retired-next'));
    await request;
    expect(container.read(dashboardProvider).resumeVideo, isEmpty);
    expect(container.read(dashboardProvider).nextUp, isEmpty);
    expect(container.read(dashboardProvider).loading, isFalse);
  });

  test('disposing the provider while pending starts no follow-up requests or state writes', () async {
    final request = container.read(dashboardProvider.notifier).fetchNextUpAndResume();
    container.dispose();
    service.resumes.single.complete(_response('disposed-video'));
    await expectLater(request, completes);
    expect(service.next, isEmpty);
  });

  test('clear from a loading observer retires refresh before any request starts', () async {
    final notifier = container.read(dashboardProvider.notifier);
    final subscription = container.listen(dashboardProvider, (previous, next) {
      if (next.loading) notifier.clear();
    });
    addTearDown(subscription.close);
    final request = notifier.fetchNextUpAndResume();
    expect(service.resumes, isEmpty);
    expect(service.next, isEmpty);
    await request;
    expect(container.read(dashboardProvider).loading, isFalse);
    expect(container.read(dashboardProvider).resumeVideo, isEmpty);
  });

  test('a dependency exception before the first await also releases loading', () async {
    final failure = StateError('synthetic unavailable views');
    final failingContainer = ProviderContainer(overrides: [
      jellyApiProvider.overrideWith(() => _Api(service)),
      viewsProvider.overrideWith((ref) => throw failure),
    ]);
    addTearDown(failingContainer.dispose);
    await expectLater(
      failingContainer.read(dashboardProvider.notifier).fetchNextUpAndResume(),
      throwsA(same(failure)),
    );
    expect(failingContainer.read(dashboardProvider).loading, isFalse);
    expect(service.resumes, isEmpty);
    expect(service.next, isEmpty);
  });
}
