import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/last_seen_notifications_model.dart';
import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/settings/book_viewer_settings_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/settings/photo_view_settings_provider.dart';
import 'package:fladder/providers/settings/pigeon_player_settings_provider.dart';
import 'package:fladder/providers/settings/subtitle_settings_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/update_notifications_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:fladder/util/settings_backup.dart';

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError();
});

final sharedUtilityProvider = Provider<SharedUtility>((ref) {
  final sharedPrefs = ref.watch(sharedPreferencesProvider);

  ref.read(pigeonPlayerSettingsSyncProvider);

  return SharedUtility(ref: ref, sharedPreferences: sharedPrefs)..init();
});

SharedHelper get sharedHelper => SharedHelper(
    sharedPreferences: SharedPreferences.getInstance() as SharedPreferences);

class SharedUtility extends SharedHelper {
  SharedUtility({
    required Ref ref,
    required super.sharedPreferences,
  }) : _ref = ref;

  final Ref _ref;

  late final JellyService api = _ref.read(jellyApiProvider);

  void init() {
    SharedKeys.instance.onKeyChanged.listen((key) async {
      await Future.delayed(const Duration(milliseconds: 500));
      switch (key) {
        case SharedKeys.lastSeenNotificationsKey:
          _ref.read(notificationsProvider.notifier).state =
              lastSeenNotifications;
          break;
      }
    });
  }

  Future<bool?> loadSettings() async {
    try {
      _ref.read(clientSettingsProvider.notifier).initialize(clientSettings);
      _ref.read(homeSettingsProvider.notifier).state = homeSettings;
      _ref.read(videoPlayerSettingsProvider.notifier).state =
          videoPlayerSettings;
      _ref.read(subtitleSettingsProvider.notifier).state = subtitleSettings;
      _ref.read(bookViewerSettingsProvider.notifier).state = bookViewSettings;
      _ref.read(photoViewSettingsProvider.notifier).state = photoViewSettings;
      _ref.read(notificationsProvider.notifier).state = lastSeenNotifications;
      return true;
    } catch (e) {
      return false;
    }
  }
}

class SharedKeys {
  SharedKeys._();

  //Singleton
  static final SharedKeys instance = SharedKeys._();

  static const String _loginCredentialsKey = 'loginCredentialsKey';
  static const String _clientSettingsKey = 'clientSettings';
  static const String _homeSettingsKey = 'homeSettings';
  static const String _videoPlayerSettingsKey = 'videoPlayerSettings';
  static const String _subtitleSettingsKey = 'subtitleSettings';
  static const String _bookViewSettingsKey = 'bookViewSettings';
  static const String _photoViewSettingsKey = 'photoViewSettings';
  static const String lastSeenNotificationsKey = 'lastSeenNotifications';

  final _keyChanged = StreamController<String>.broadcast();

  Stream<String> get onKeyChanged => _keyChanged.stream;
}

class SharedHelper {
  final Ref? ref;
  final SharedPreferences sharedPreferences;

  const SharedHelper({this.ref, required this.sharedPreferences});

  Future<bool?> addAccount(AccountModel account) async {
    final newAccount = account.copyWith(
      lastUsed: DateTime.now(),
    );

    List<AccountModel> accounts = getAccounts().toList();
    if (accounts.any((element) => element.sameIdentity(newAccount))) {
      accounts = accounts
          .map(
            (e) => e.sameIdentity(newAccount)
                ? e.copyWith(
                    credentials: newAccount.credentials,
                    lastUsed: newAccount.lastUsed,
                  )
                : e,
          )
          .toList();
    } else {
      accounts = [
        ...accounts,
        newAccount,
      ];
    }

    return await saveAccounts(accounts);
  }

  Future<bool?> removeAccount(AccountModel? account) async {
    if (account == null) return null;
    if (ref != null) {
      await ref!.read(seerrSessionStoreProvider).write(account, null);
    }

    try {
      //Try to logout user
      await ref?.read(userProvider.notifier).forceLogoutUser(account);
    } catch (error) {
      log('Unable to log-out user forcing anyway ${error.runtimeType}');
    }

    //Remove from local database
    final savedAccounts = getAccounts();
    savedAccounts.removeWhere((element) {
      return element.sameIdentity(account);
    });
    return (await saveAccounts(savedAccounts));
  }

  List<AccountModel> getAccounts() {
    return _storedAccounts().map(migrateJmsSeerrSource).toList();
  }

  List<AccountModel> _storedAccounts() {
    final savedAccounts =
        sharedPreferences.getStringList(SharedKeys._loginCredentialsKey) ?? [];
    final accounts = <AccountModel>[];
    for (final entry in savedAccounts) {
      try {
        final account = AccountModel.fromJson(jsonDecode(entry));
        final credentials = account.seerrCredentials;
        accounts.add(credentials == null
            ? account
            : account.copyWith(
                seerrCredentials: credentials.copyWith(sessionCookie: '')));
      } catch (error) {
        log('Unable to read saved account: ${error.runtimeType}');
      }
    }
    return accounts;
  }

  Future<int> migrateJmsSeerrAccounts() async {
    final rawAccounts =
        sharedPreferences.getStringList(SharedKeys._loginCredentialsKey) ?? [];
    final scrubbedAccounts = <String>[];
    final savedAccounts = <String>[];
    final affected = <AccountModel>[];
    var changed = false;
    var hasPlaintextCookie = false;
    for (final entry in rawAccounts) {
      var scrubbedEntry = entry;
      var nextEntry = entry;
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map<String, dynamic>) {
          final seerr = decoded['seerrCredentials'];
          if (seerr is Map && seerr.containsKey('sessionCookie')) {
            seerr.remove('sessionCookie');
            scrubbedEntry = jsonEncode(decoded);
            nextEntry = scrubbedEntry;
            changed = true;
            hasPlaintextCookie = true;
          }
          try {
            final account = AccountModel.fromJson(decoded);
            if (needsJmsSeerrSourceMigration(account)) {
              affected.add(account);
              nextEntry = jsonEncode(migrateJmsSeerrSource(account));
              changed = true;
            }
          } catch (_) {}
        }
      } catch (_) {}
      scrubbedAccounts.add(scrubbedEntry);
      savedAccounts.add(nextEntry);
    }
    if (!changed) return 0;
    if (hasPlaintextCookie &&
        await sharedPreferences.setStringList(
                SharedKeys._loginCredentialsKey, scrubbedAccounts) !=
            true) {
      throw StateError('Unable to scrub legacy Seerr session');
    }
    if (affected.isEmpty) return 0;
    final store = SeerrSessionStore();
    for (final account in affected) {
      if (account.seerrCredentials != null) await store.write(account, null);
    }
    if (await sharedPreferences.setStringList(
            SharedKeys._loginCredentialsKey, savedAccounts) !=
        true) {
      throw StateError('Unable to save Seerr source migration');
    }
    return affected.length;
  }

  AccountModel? getActiveAccount() {
    try {
      final accounts = getAccounts();
      AccountModel recentUsedAccount = accounts.reduce((lastLoggedIn, element) {
        return (element.lastUsed.compareTo(lastLoggedIn.lastUsed)) > 0
            ? element
            : lastLoggedIn;
      });

      if (recentUsedAccount.authMethod == Authentication.autoLogin) {
        return recentUsedAccount;
      }
      return null;
    } catch (e) {
      log(e.toString());
      return null;
    }
  }

  Future<bool?> saveAccounts(List<AccountModel> accounts) async =>
      sharedPreferences.setStringList(SharedKeys._loginCredentialsKey,
          accounts.map((e) => jsonEncode(e)).toList());

  ClientSettingsModel get clientSettings {
    try {
      return ClientSettingsModel.fromJson(
          SettingsBundleStore(sharedPreferences).section('client') ??
              jsonDecode(
                  sharedPreferences.getString(SharedKeys._clientSettingsKey) ??
                      ""));
    } catch (e) {
      log('Unable to load client settings');
      return ClientSettingsModel.defaultModel();
    }
  }

  Future<bool> saveClientSettings(ClientSettingsModel settings) =>
      SettingsBundleStore(sharedPreferences).writeSection(
          'client', settings.toJson(), SharedKeys._clientSettingsKey);

  set clientSettings(ClientSettingsModel settings) =>
      unawaited(saveClientSettings(settings));

  HomeSettingsModel get homeSettings {
    try {
      return HomeSettingsModel.fromJson(jsonDecode(
          sharedPreferences.getString(SharedKeys._homeSettingsKey) ?? ""));
    } catch (e) {
      log(e.toString());
      return HomeSettingsModel.defaultModel();
    }
  }

  set homeSettings(HomeSettingsModel settings) => sharedPreferences.setString(
      SharedKeys._homeSettingsKey, jsonEncode(settings.toJson()));

  BookViewerSettingsModel get bookViewSettings {
    try {
      return BookViewerSettingsModel.fromJson(
          sharedPreferences.getString(SharedKeys._bookViewSettingsKey) ?? "");
    } catch (e) {
      log(e.toString());
      return BookViewerSettingsModel();
    }
  }

  set bookViewSettings(BookViewerSettingsModel settings) {
    sharedPreferences.setString(
        SharedKeys._bookViewSettingsKey, settings.toJson());
  }

  Future<void> updateAccountInfo(AccountModel account) async {
    final accounts = getAccounts();
    await Future.microtask(() async {
      await saveAccounts(accounts.map((e) {
        if (e.sameIdentity(account)) {
          return account.copyWith(
            lastUsed: DateTime.now(),
          );
        } else {
          return e;
        }
      }).toList());
    });
  }

  LastSeenNotificationsModel get lastSeenNotifications {
    try {
      return LastSeenNotificationsModel.fromJson(jsonDecode(
          sharedPreferences.getString(SharedKeys.lastSeenNotificationsKey) ??
              ""));
    } catch (e) {
      log(e.toString());
      return const LastSeenNotificationsModel();
    }
  }

  Future<void> setLastSeenNotifications(
      LastSeenNotificationsModel serverLastSeen) async {
    await sharedPreferences.setString(SharedKeys.lastSeenNotificationsKey,
        jsonEncode(serverLastSeen.toJson()));
    SharedKeys.instance._keyChanged.add(SharedKeys.lastSeenNotificationsKey);
  }

  SubtitleSettingsModel get subtitleSettings {
    try {
      return SubtitleSettingsModel.fromJson(
          sharedPreferences.getString(SharedKeys._subtitleSettingsKey) ?? "");
    } catch (e) {
      log(e.toString());
      return const SubtitleSettingsModel();
    }
  }

  set subtitleSettings(SubtitleSettingsModel settings) {
    sharedPreferences.setString(
        SharedKeys._subtitleSettingsKey, settings.toJson());
  }

  VideoPlayerSettingsModel get videoPlayerSettings {
    try {
      return VideoPlayerSettingsModel.fromJson(
          SettingsBundleStore(sharedPreferences).section('player') ??
              jsonDecode(sharedPreferences
                      .getString(SharedKeys._videoPlayerSettingsKey) ??
                  ""));
    } catch (e) {
      log('Unable to load player settings');
      return VideoPlayerSettingsModel();
    }
  }

  set videoPlayerSettings(VideoPlayerSettingsModel settings) {
    unawaited(SettingsBundleStore(sharedPreferences).writeSection(
        'player', settings.toJson(), SharedKeys._videoPlayerSettingsKey));
  }

  PhotoViewSettingsModel get photoViewSettings {
    try {
      return PhotoViewSettingsModel.fromJson(
          sharedPreferences.getString(SharedKeys._photoViewSettingsKey) ?? "");
    } catch (e) {
      log(e.toString());
      return PhotoViewSettingsModel();
    }
  }

  set photoViewSettings(PhotoViewSettingsModel settings) {
    sharedPreferences.setString(
        SharedKeys._photoViewSettingsKey, settings.toJson());
  }
}
