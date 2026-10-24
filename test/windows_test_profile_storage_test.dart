import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:background_downloader/background_downloader.dart';

import 'package:fladder/bootstrap/windows_test_profile.dart';
import 'package:fladder/models/settings/arguments_model.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';

class _ForbiddenPreferences extends InMemorySharedPreferencesStore {
  _ForbiddenPreferences() : super.empty();
  var reads = 0;
  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    throw StateError('Default preferences must not be read');
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
      GetAllParameters parameters) async {
    reads++;
    throw StateError('Default preferences must not be read');
  }
}

class _ForbiddenPaths extends PathProviderPlatform {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PathProviderPlatform originalPaths;
  late SharedPreferencesStorePlatform originalStore;
  late SharedPreferencesAsyncPlatform? originalAsync;
  late Directory fixture;
  late _ForbiddenPreferences forbiddenStore;

  setUp(() async {
    originalPaths = PathProviderPlatform.instance;
    originalStore = SharedPreferencesStorePlatform.instance;
    originalAsync = SharedPreferencesAsyncPlatform.instance;
    forbiddenStore = _ForbiddenPreferences();
    SharedPreferencesStorePlatform.instance = forbiddenStore;
    PathProviderPlatform.instance = _ForbiddenPaths();
    SharedPreferences.resetStatic();
    final parent = Directory(
        path.join(Directory.current.path, 'build', 'profile-fixtures'));
    await parent.create(recursive: true);
    fixture = await parent.createTemp('synthetic-');
  });

  tearDown(() async {
    FileDownloader.setDesktopDirectoryPaths(null);
    SharedPreferences.resetStatic();
    PathProviderPlatform.instance = originalPaths;
    SharedPreferencesStorePlatform.instance = originalStore;
    SharedPreferencesAsyncPlatform.instance = originalAsync;
    final fixtureParent = Directory(
        path.join(Directory.current.path, 'build', 'profile-fixtures'));
    if (!path.isWithin(await fixtureParent.resolveSymbolicLinks(),
        await fixture.resolveSymbolicLinks())) {
      throw StateError('Refusing to delete a fixture outside the workspace');
    }
    await fixture.delete(recursive: true);
  });

  Future<WindowsTestProfile> createProfile(String name) async {
    final root = Directory(path.join(fixture.path, name));
    await root.create();
    final profile = WindowsTestProfile(root.path);
    for (final directory in [
      'config',
      'support',
      'documents',
      'cache',
      'temp',
      'downloads',
      'seerr-sessions'
    ]) {
      await Directory(profile.directory(directory)).create();
    }
    await File(path.join(root.path, JmsTestProfilePolicy.markerName))
        .writeAsString(JmsTestProfilePolicy.markerContents);
    return profile;
  }

  Future<WindowsTestProfile?> initialize(WindowsTestProfile profile,
          {List<String>? arguments}) =>
      initializeWindowsTestProfile(
        arguments ?? ['--profile-dir', profile.root],
        testBuild: true,
        isWindows: true,
        configurationLoader: () async =>
            {'testBuild': true, 'root': profile.root},
      );

  test(
      'ordinary builds preserve registered stores and do not ask native configuration',
      () async {
    var nativeCalls = 0;
    final beforePaths = PathProviderPlatform.instance;
    final beforeStore = SharedPreferencesStorePlatform.instance;
    expect(
        await initializeWindowsTestProfile([], testBuild: false,
            configurationLoader: () async {
          nativeCalls++;
          throw StateError('Should not be queried');
        }),
        isNull);
    expect(PathProviderPlatform.instance, same(beforePaths));
    expect(SharedPreferencesStorePlatform.instance, same(beforeStore));
    expect(nativeCalls, 0);
    expect(forbiddenStore.reads, 0);
  });

  test('ordinary builds reject profile arguments before any preference read',
      () async {
    await expectLater(
      initializeWindowsTestProfile(['--profile-dir', fixture.path],
          testBuild: false),
      throwsStateError,
    );
    expect(forbiddenStore.reads, 0);
  });

  test('missing native profile and mismatched build fail closed', () async {
    for (final config in [
      <String, Object?>{'testBuild': true, 'root': null},
      <String, Object?>{'testBuild': false, 'root': fixture.path},
    ]) {
      await expectLater(
          initializeWindowsTestProfile([],
              testBuild: true,
              isWindows: true,
              configurationLoader: () async => config),
          throwsStateError);
    }
    expect(forbiddenStore.reads, 0);
  });

  test('a missing native bridge cannot fall back to a normal profile',
      () async {
    await expectLater(
        initializeWindowsTestProfile([],
            testBuild: true,
            isWindows: true,
            configurationLoader: () async => throw MissingPluginException()),
        throwsA(isA<MissingPluginException>()));
    expect(forbiddenStore.reads, 0);
  });

  test('mismatched directory is rejected before any configured store is opened',
      () async {
    final profileA = await createProfile('a');
    final profileB = await createProfile('b');
    await expectLater(
        initializeWindowsTestProfile(['--profile-dir', profileA.root],
            testBuild: true,
            isWindows: true,
            configurationLoader: () async =>
                {'testBuild': true, 'root': profileB.root}),
        throwsStateError);
    expect(forbiddenStore.reads, 0);
    expect(await File(profileA.preferencesFile).exists(), isFalse);
    expect(await File(profileB.preferencesFile).exists(), isFalse);
  });

  test('marker and complete directory namespace are required', () async {
    await expectLater(
        initializeWindowsTestProfile([],
            testBuild: true,
            isWindows: true,
            configurationLoader: () async =>
                {'testBuild': true, 'root': fixture.path}),
        throwsStateError);
    final profile = await createProfile('incomplete');
    await Directory(profile.cache).delete();
    await expectLater(initialize(profile), throwsStateError);
    expect(forbiddenStore.reads, 0);
  });

  test('all path-provider lookups stay inside the synthetic profile', () async {
    final profile = await createProfile('paths');
    await initialize(profile);
    expect((await getTemporaryDirectory()).path, profile.temporary);
    expect((await getApplicationSupportDirectory()).path, profile.support);
    expect((await getApplicationDocumentsDirectory()).path, profile.documents);
    expect((await getApplicationCacheDirectory()).path, profile.cache);
    expect((await getDownloadsDirectory())!.path, profile.downloads);
    expect((await getLibraryDirectory()).path, profile.support);
    expect(forbiddenStore.reads, 0);
  });

  test('secondary engines inherit the already validated native profile',
      () async {
    final profile = await createProfile('secondary');
    expect((await initialize(profile, arguments: ['multi_window', '1']))!.root,
        profile.root);
    expect((await getApplicationSupportDirectory()).path, profile.support);
  });

  test('legacy and async preferences persist only synthetic values in config',
      () async {
    final profile = await createProfile('preferences');
    await initialize(profile);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys(), isEmpty);
    await preferences.setString('fixture', 'FAKE-PROFILE-A');
    await preferences.setStringList('list', ['FAKE-1', 'FAKE-2']);
    final asynchronous = SharedPreferencesAsyncPlatform.instance!;
    await asynchronous.setInt(
        'async-fixture', 23, const SharedPreferencesOptions());
    final reopened =
        await TestProfilePreferences.open(File(profile.preferencesFile));
    final all = await reopened.getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: '')));
    expect(all['flutter.fixture'], 'FAKE-PROFILE-A');
    expect(all['flutter.list'], ['FAKE-1', 'FAKE-2']);
    expect(all['async-fixture'], 23);
    expect(forbiddenStore.reads, 0);
  });

  test('two new profile stores remain separate through reopen and clear',
      () async {
    final profileA = await createProfile('a');
    final profileB = await createProfile('b');
    final a = await TestProfilePreferences.open(File(profileA.preferencesFile));
    final b = await TestProfilePreferences.open(File(profileB.preferencesFile));
    await a.setValue('String', 'flutter.fixture', 'FAKE-A');
    await b.setValue('String', 'flutter.fixture', 'FAKE-B');
    await a.clear();
    final reopenedA =
        await TestProfilePreferences.open(File(profileA.preferencesFile));
    final reopenedB =
        await TestProfilePreferences.open(File(profileB.preferencesFile));
    expect(await reopenedA.getAll(), isEmpty);
    expect((await reopenedB.getAll())['flutter.fixture'], 'FAKE-B');
    expect(forbiddenStore.reads, 0);
  });

  test('unsafe and duplicate arguments are rejected without filesystem access',
      () {
    for (final arguments in [
      ['--profile-dir'],
      ['--profile-dir='],
      ['--profile-dir', 'relative'],
      ['--profile-dir', r'C:\'],
      ['--profile-dir', r'\\server\share\test'],
      ['--profile-dir', r'C:\test\..\other'],
      ['--profile-dir', r'C:\test', '--profile-dir', r'C:\other'],
    ]) {
      expect(() => WindowsTestProfile.requestedDirectory(arguments),
          throwsFormatException);
    }
    expect(
        WindowsTestProfile.requestedDirectory(
            ['--profile-dir=C:\\fixture\\test']),
        r'C:\fixture\test');
  });

  test(
      'test builds force notification skipping independently of saved settings',
      () {
    expect(ArgumentsModel.fromArguments([], '', false).skipNotifications,
        JmsTestProfilePolicy.enabled);
    expect(
        ArgumentsModel.fromArguments(['--skipNotifications'], '', false)
            .skipNotifications,
        isTrue);
  });
}
