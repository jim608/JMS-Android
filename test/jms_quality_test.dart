import 'dart:async';

import 'package:chopper/chopper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/search_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

class PendingSearch implements JellyService {
  int requests = 0;
  final pending = <String, Completer<Response<ServerQueryResult>>>{};
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #itemsGet) {
      requests++;
      final query = invocation.namedArguments[#searchTerm] as String;
      return (pending[query] = Completer<Response<ServerQueryResult>>()).future;
    }
    return super.noSuchMethod(invocation);
  }

  void complete(String query, int count) =>
      pending[query]!.complete(Response(http.Response('', 200), ServerQueryResult(items: [], totalRecordCount: count)));
}

class TestJellyApi extends JellyApi {
  final JellyService service;
  TestJellyApi(this.service);
  @override
  JellyService build() => service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PendingSearch service;
  late ProviderContainer container;
  setUp(() {
    service = PendingSearch();
    container = ProviderContainer(overrides: [jellyApiProvider.overrideWith(() => TestJellyApi(service))]);
  });
  tearDown(() => container.dispose());

  test('Q1 older search cannot replace the latest result', () async {
    final notifier = container.read(searchProvider.notifier);
    notifier.setQuery('older');
    final older = notifier.searchQuery();
    notifier.setQuery('latest');
    final latest = notifier.searchQuery();
    service.complete('latest', 2);
    await latest;
    service.complete('older', 99);
    await older;
    expect(container.read(searchProvider).resultCount, 2);
  });
  test('Q1 clearing search invalidates an in-flight response', () async {
    final notifier = container.read(searchProvider.notifier)..setQuery('old');
    final request = notifier.searchQuery();
    notifier.clear();
    service.complete('old', 99);
    await request;
    expect(container.read(searchProvider).resultCount, 0);
    expect(container.read(searchProvider).searchQuery, isEmpty);
  });
  test('Q1 duplicate submissions share the active request, with explicit retry after failure', () async {
    final notifier = container.read(searchProvider.notifier)..setQuery('same');
    final first = notifier.searchQuery();
    await notifier.searchQuery();
    expect(service.requests, 1);
    service.pending['same']!.completeError(TimeoutException('fixture'));
    await first;
    expect(container.read(searchProvider).hasError, true);
    final retry = notifier.searchQuery();
    expect(service.requests, 2);
    service.complete('same', 1);
    await retry;
    expect(container.read(searchProvider).hasError, false);
  });
  test('Q1 failed request does not leave a perpetual loading indicator', () async {
    final notifier = container.read(searchProvider.notifier)..setQuery('offline');
    final request = notifier.searchQuery();
    final observed = request.catchError((_) => null);
    service.pending['offline']!.completeError(TimeoutException('fixture'));
    await observed;
    expect(container.read(searchProvider).loading, false);
  });
  test('Q1 completion after provider disposal does not mutate dead state', () async {
    final notifier = container.read(searchProvider.notifier)..setQuery('leaving');
    final request = notifier.searchQuery();
    container.invalidate(searchProvider);
    service.complete('leaving', 1);
    await expectLater(request, completes);
  });
  test('Q2 wrapper disposal cancels its retained stream subscriptions', () async {
    final wrapperProvider = Provider((ref) => MediaControlsWrapper(ref: ref));
    final wrapper = container.read(wrapperProvider);
    final stream = StreamController<int>.broadcast();
    wrapper.subscriptions.add(stream.stream.listen((_) {}));
    expect(stream.hasListener, true);
    await wrapper.dispose();
    expect(stream.hasListener, false);
    expect(wrapper.subscriptions, isEmpty);
    await stream.close();
  });
}
