import 'package:flutter/material.dart';

import 'package:chopper/chopper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/api_result.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/login_screen_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/dashboard_provider.dart';
import 'package:fladder/providers/favourites_provider.dart';
import 'package:fladder/providers/image_provider.dart';
import 'package:fladder/providers/jms_entry_provider.dart';
import 'package:fladder/providers/library_screen_provider.dart';
import 'package:fladder/providers/music_dashboard_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/seerr_dashboard_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:fladder/screens/login/lock_screen.dart';
import 'package:fladder/services/local_network_permission.dart';
import 'package:fladder/services/jms_entry_cache.dart';
import 'package:fladder/services/jms_entry_discovery.dart';
import 'package:fladder/util/fladder_config.dart';
import 'package:fladder/util/list_extensions.dart';
import 'package:fladder/util/localization_helper.dart';

final authProvider =
    StateNotifierProvider<AuthNotifier, LoginScreenModel>((ref) {
  return AuthNotifier(ref);
});

class JmsLoginConnection {
  const JmsLoginConnection(this.service, this.close);
  final JellyService service;
  final void Function() close;
}

final jmsLoginConnectionProvider =
    Provider<JmsLoginConnection Function(CredentialsModel)>((ref) {
  return (credentials) {
    final client = createJellyfinApiForAccount(
        ref, credentials.url, credentials.copyWith(token: '').header(ref),
        privateLink: true);
    return JmsLoginConnection(JellyService(ref, client), client.client.dispose);
  };
});

class AuthNotifier extends StateNotifier<LoginScreenModel> {
  AuthNotifier(this.ref) : super(LoginScreenModel());

  final Ref ref;

  int _serverAttempt = 0;
  String? entryInput;
  JmsEntryResolution? entryResolution;
  JmsEntryResolution? pendingEntryChange;
  bool _manualSeerr = false;
  JmsEntryResolution? _confirmedEntryForLogin;

  late final JellyService api = ref.read(jellyApiProvider);

  BuildContext? get localContext => ref.read(localizationContextProvider);

  Future<void> initModel() async {
    final initialization = ++_serverAttempt;
    final confirmedEntry = _confirmedEntryForLogin;
    _confirmedEntryForLogin = null;
    ref.read(userProvider.notifier).clear();
    try {
      await ref.read(sharedUtilityProvider).migrateJmsSeerrAccounts();
    } catch (error) {
      debugPrint('Seerr source migration will retry: ${error.runtimeType}');
    }
    if (initialization != _serverAttempt || ref.read(userProvider) != null) {
      return;
    }
    final currentAccounts = getSavedAccounts();
    ref.read(lockScreenActiveProvider.notifier).update((state) => true);
    state = state.copyWith(
      accounts: currentAccounts,
      screen: currentAccounts.isEmpty
          ? LoginScreenType.login
          : LoginScreenType.users,
    );
    if (confirmedEntry != null) {
      await connectEntryResolution(confirmedEntry);
    } else if (FladderConfig.baseUrl != null) {
      state = state.copyWith(hasBaseUrl: true);
      await setServer(FladderConfig.baseUrl!);
    }
  }

  Future<bool> _fetchServerInfo(String url,
      {int? attempt,
      JmsEntryResolution? resolution,
      bool servicesConfirmed = false}) async {
    final generation = attempt ?? _serverAttempt;
    bool current() =>
        generation == _serverAttempt && ref.read(userProvider) == null;
    JmsLoginConnection? connection;
    try {
      if (!current()) return false;
      final newCredentials =
          CredentialsModel.createNewCredentials().copyWith(url: url);
      final newLoginModel = ServerLoginModel(tempCredentials: newCredentials);
      state = state.copyWith(serverLoginModel: newLoginModel, loading: true);
      connection = ref.read(jmsLoginConnectionProvider)(newCredentials);
      final service = connection.service;
      final serverResponse = await service
          .systemInfoPublicGet()
          .timeout(const Duration(seconds: 8));
      if (!current()) return false;
      final serverId = serverResponse.body?.id ?? '';
      if (!serverResponse.isSuccessful ||
          serverId.isEmpty ||
          (resolution?.serverId != null &&
              resolution!.serverId!.replaceAll('-', '').toLowerCase() !=
                  serverId.replaceAll('-', '').toLowerCase())) {
        throw StateError('Public server identity differs');
      }
      final settings = ref.read(jmsEntrySettingsProvider);
      final previous = settings.forServer(url, serverId);
      if (resolution?.entry != null &&
          !servicesConfirmed &&
          previous != null &&
          previous.config.seerrBaseUrl != resolution!.config!.seerrBaseUrl) {
        pendingEntryChange = resolution;
        state = state.copyWith(
            serverLoginModel: null,
            loading: false,
            errorMessage: '入口提供的服務來源已變更。請查看並確認後重新登入。');
        return false;
      }
      if (resolution != null && !await settings.accept(resolution, serverId)) {
        throw StateError('Entry settings could not be saved');
      }
      if (!current()) return false;
      final publicUsers = (await service
                  .usersPublicGet(newCredentials)
                  .timeout(const Duration(seconds: 8)))
              .body ??
          [];
      if (!current()) return false;
      final quickConnectStatus = (await service
                  .quickConnectEnabled()
                  .timeout(const Duration(seconds: 8)))
              .body ??
          false;
      if (!current()) return false;
      final branding =
          await service.getBranding().timeout(const Duration(seconds: 8));
      if (!current()) return false;
      state = state.copyWith(
          errorMessage: null,
          screen:
              quickConnectStatus ? LoginScreenType.code : LoginScreenType.login,
          serverLoginModel: newLoginModel.copyWith(
              tempCredentials: newCredentials.copyWith(
                  serverName: serverResponse.body?.serverName ?? '',
                  serverId: serverId),
              accounts: publicUsers,
              hasQuickConnect: quickConnectStatus,
              serverMessage: branding.body?.loginDisclaimer),
          loading: false);
      setTempSeerrUrl(_findSeerrUrlForServer(serverId), serverProvided: true);
      return true;
    } catch (_) {
      if (current()) {
        state = state.copyWith(
            serverLoginModel: null,
            tempSeerrUrl: null,
            tempSeerrSessionCookie: null,
            errorMessage: localContext?.localized.invalidUrl ??
                'Unable to connect to Jellyfin',
            loading: false);
      }
      return false;
    } finally {
      connection?.close();
    }
  }

  Future<Response<List<AccountModel>>?> getPublicUsers() async {
    try {
      state = state.copyWith(loading: true);
      final credentials = state.serverLoginModel?.tempCredentials;
      if (credentials == null) return null;
      var response = await api.usersPublicGet(credentials);
      if (response.isSuccessful && response.body != null) {
        var models = response.body ?? [];
        return response.copyWith(body: models.toList());
      }
      state = state.copyWith(
        serverLoginModel: state.serverLoginModel?.copyWith(
          accounts: response.body ?? [],
        ),
      );
      return response.copyWith(body: []);
    } catch (e) {
      return null;
    } finally {
      state = state.copyWith(loading: false);
    }
  }

  Future<ApiResult<AccountModel>> authenticateUsingSecret(String secret) async {
    final credentials = state.serverLoginModel?.tempCredentials;
    if (credentials == null) {
      return ApiResult.failure(ApiError(message: 'Connect to a server first'));
    }
    final manualSeerr = _manualSeerr;
    final seerrSource = state.tempSeerrUrl;
    clearAllProviders();
    final attempt = _serverAttempt;
    final connection = ref.read(jmsLoginConnectionProvider)(credentials);
    try {
      final response = await connection.service
          .quickConnectAuthenticate(secret)
          .timeout(const Duration(seconds: 30));
      return (await _createAccountModel(response,
              credentials: credentials,
              attempt: attempt,
              manualSeerr: manualSeerr,
              seerrSource: seerrSource,
              service: connection.service))
          .apiResult;
    } catch (_) {
      return ApiResult.failure(
          ApiError(message: 'Unable to complete Jellyfin authentication'));
    } finally {
      connection.close();
    }
  }

  Future<Response<AccountModel>?> authenticateByName(
      String userName, String password) async {
    final credentials = state.serverLoginModel?.tempCredentials;
    if (credentials == null) return null;
    final manualSeerr = _manualSeerr;
    final seerrSource = state.tempSeerrUrl;
    clearAllProviders();
    final attempt = _serverAttempt;
    final connection = ref.read(jmsLoginConnectionProvider)(credentials);
    try {
      final response = await connection.service
          .usersAuthenticateByNamePost(userName: userName, password: password)
          .timeout(const Duration(seconds: 30));
      return await _createAccountModel(response,
          credentials: credentials,
          attempt: attempt,
          manualSeerr: manualSeerr,
          seerrSource: seerrSource,
          service: connection.service);
    } catch (_) {
      return null;
    } finally {
      connection.close();
    }
  }

  Future<void> beginSeerrSession({String? username, String? password, bool manual = false}) async {
    final account = ref.read(userProvider);
    if (account == null || account.credentials.serverId.isEmpty) return;
    final source = ref.read(jmsEntrySettingsProvider).effectiveSeerrCredentials(account,
        configuredSource: FladderConfig.seerrBaseUrl).serverUrl;
    if (source.isEmpty) return;
    final autoBind = account.seerrCredentials?.linkedServerId.isNotEmpty != true ||
        account.seerrCredentials?.serverUrl != source;
    if (autoBind) {
      await ref.read(userProvider.notifier).bindSeerrAccount(source);
    }
    final current = ref.read(userProvider);
    if (current == null || !current.sameIdentity(account) ||
        current.credentials.url != account.credentials.url ||
        current.seerrCredentials?.serverUrl != source) {
      return;
    }
    await ref.read(seerrLinkProvider.notifier).ensure(
        username: username, password: password, manual: manual,
        requireServerProof: autoBind || password != null,
        jellyfinAuthSuccess: password != null ? true : null);
  }

  Future<Response<AccountModel>> _createAccountModel(
      Response<AuthenticationResult> response,
      {required CredentialsModel credentials,
      required int attempt,
      required bool manualSeerr,
      required JellyService service,
      String? seerrSource}) async {
    bool current() =>
        attempt == _serverAttempt &&
        ref.read(userProvider) == null &&
        state.serverLoginModel?.tempCredentials.url == credentials.url &&
        state.serverLoginModel?.tempCredentials.serverId ==
            credentials.serverId;
    String id(String value) => value.replaceAll('-', '').toLowerCase();
    if (!current() ||
        !response.isSuccessful ||
        response.body?.accessToken?.isNotEmpty != true ||
        response.body?.user?.id?.isNotEmpty != true ||
        id(response.body?.serverId ?? '') != id(credentials.serverId)) {
      return Response(response.base, null);
    }
    final serverResponse =
        await service.systemInfoPublicGet().timeout(const Duration(seconds: 8));
    if (!current() ||
        !serverResponse.isSuccessful ||
        id(serverResponse.body?.id ?? '') != id(credentials.serverId)) {
      return Response(response.base, null);
    }
    final fixedCredentials = credentials.copyWith(
      token: response.body!.accessToken!,
      serverName: serverResponse.body?.serverName ?? '',
    );
    final imageUrl = ref
        .read(imageUtilityProvider)
        .getUserImageUrl(response.body!.user!.id!);
    var newUser = AccountModel(
      name: response.body!.user!.name ?? '',
      id: response.body!.user!.id!,
      avatar: imageUrl,
      credentials: fixedCredentials,
      lastUsed: DateTime.now(),
    );
    final settings = ref.read(jmsEntrySettingsProvider);
    final previous = state.accounts.where((account) =>
        account.sameIdentity(newUser) &&
        account.credentials.url == newUser.credentials.url);
    if (previous.isNotEmpty && settings.hasManualSeerr(previous.first)) {
      newUser =
          newUser.copyWith(seerrCredentials: previous.first.seerrCredentials);
    }
    newUser = await settings.configureNewAccount(newUser,
        manual: manualSeerr, manualSource: seerrSource);
    if (!current()) return Response(response.base, null);
    ref.read(sharedUtilityProvider).addAccount(newUser);
    ref.read(userProvider.notifier).userState = newUser;
    state = state.copyWith(accounts: getSavedAccounts());
    return Response(response.base, newUser);
  }

  Future<Response?> logOutUser() async {
    final currentUser = ref.read(userProvider);
    state = state.copyWith(serverLoginModel: null);
    try {
      if (currentUser != null &&
          ref.read(userProvider)?.sameIdentity(currentUser) == true &&
          currentUser.seerrCredentials?.serverUrl.isNotEmpty == true &&
          currentUser.seerrCredentials?.linkedServerId ==
              currentUser.credentials.serverId &&
          ref.read(seerrLinkProvider) == 'connected') {
        try {
          await ref.read(seerrApiProvider).logout();
        } catch (_) {}
      }
    } finally {
      if (currentUser != null) {
        await ref.read(seerrSessionStoreProvider).write(currentUser, null);
        if (ref.read(userProvider)?.sameIdentity(currentUser) == true) {
          await ref
              .read(userProvider.notifier)
              .setSeerrSessionCookie('', persist: false);
        }
      }
    }
    await ref.read(sharedUtilityProvider).removeAccount(currentUser);
    if (currentUser != null &&
        (ref.read(userProvider) == null ||
            ref.read(userProvider)?.sameIdentity(currentUser) == true)) {
      clearAllProviders();
    }
    return null;
  }

  Future<void> switchUser() async => clearAllProviders();

  void clearAllProviders() {
    ++_serverAttempt;
    ref.read(dashboardProvider.notifier).clear();
    ref.read(viewsProvider.notifier).clear();
    ref.read(favouritesProvider.notifier).clear();
    ref.read(userProvider.notifier).clear();
    ref.read(libraryScreenProvider.notifier).clear();
    ref.read(seerrDashboardProvider.notifier).clear();
    ref.read(musicDashboardProvider.notifier).clear();
  }

  Future<void> setServer(String server, {bool forceDirect = false}) async {
    final attempt = ++_serverAttempt;
    pendingEntryChange = null;
    entryResolution = null;
    _manualSeerr = false;
    if (state.hasBaseUrl) {
      if (!await _hasLocalNetworkPermission(FladderConfig.baseUrl!)) return;
      await _fetchServerInfo(FladderConfig.baseUrl!, attempt: attempt);
      return;
    }
    final trimmed = server.trim();
    if (trimmed.isEmpty) return;
    entryInput = trimmed;
    if (ref.read(userProvider) != null) {
      state = state.copyWith(errorMessage: '請先切換帳號，再連線其他伺服器。', loading: false);
      return;
    }
    state = state.copyWith(
        serverLoginModel: null,
        tempSeerrUrl: null,
        tempSeerrSessionCookie: null,
        loading: true,
        errorMessage: null);
    if (!await _hasLocalNetworkPermission(trimmed)) {
      if (attempt == _serverAttempt) state = state.copyWith(loading: false);
      return;
    }
    final result = await ref
        .read(jmsEntryDiscoveryProvider)
        .discover(trimmed, forceDirect: forceDirect);
    if (attempt != _serverAttempt) return;
    entryResolution = result;
    if (!result.isSuccess) {
      state = state.copyWith(
          loading: false, errorMessage: '無法讀取入口設定或確認 Jellyfin。請重試，或選擇直接連線。');
      return;
    }
    final entry = result.entry;
    if (entry != null && !result.fromCache) {
      final previous =
          await JmsEntryCache(ref.read(sharedPreferencesProvider)).read(entry);
      if (attempt != _serverAttempt) return;
      if (previous != null &&
          (previous.baseUrl != result.config!.baseUrl ||
              previous.seerrBaseUrl != result.config!.seerrBaseUrl)) {
        pendingEntryChange = result;
        state = state.copyWith(
            loading: false, errorMessage: '入口提供的服務來源已變更。請查看並確認後重新登入。');
        return;
      }
    }
    await _fetchServerInfo(result.config!.baseUrl,
        attempt: attempt, resolution: result);
  }

  Future<void> confirmEntryChange({JmsEntryResolution? expected}) async {
    final result = pendingEntryChange;
    if (expected != null && !identical(expected, result)) return;
    if (result == null || !result.isSuccess || ref.read(userProvider) != null) {
      return;
    }
    await connectEntryResolution(result);
  }

  Future<void> connectEntryResolution(JmsEntryResolution result) async {
    if (!result.isSuccess || ref.read(userProvider) != null) return;
    final attempt = ++_serverAttempt;
    pendingEntryChange = null;
    entryResolution = result;
    _manualSeerr = false;
    entryInput ??= result.entry?.toString() ?? result.config!.baseUrl;
    state = state.copyWith(
        serverLoginModel: null,
        tempSeerrUrl: null,
        tempSeerrSessionCookie: null,
        loading: true,
        errorMessage: null);
    await _fetchServerInfo(result.config!.baseUrl,
        attempt: attempt, resolution: result, servicesConfirmed: true);
  }

  Future<bool> prepareEntryLogin(JmsEntryResolution result) async {
    if (!result.isSuccess || result.entry == null) return false;
    await switchUser();
    if (ref.read(userProvider) != null) return false;
    _confirmedEntryForLogin = result;
    entryInput = result.entry!.toString();
    state = state.copyWith(
        serverLoginModel: null,
        tempSeerrUrl: null,
        tempSeerrSessionCookie: null,
        errorMessage: null,
        hasBaseUrl: false);
    return true;
  }

  Future<bool> _hasLocalNetworkPermission(String url) async {
    return ensureLocalNetworkPermission(url, localContext);
  }

  List<AccountModel> getSavedAccounts() {
    state =
        state.copyWith(accounts: ref.read(sharedUtilityProvider).getAccounts());
    return state.accounts;
  }

  void reOrderUsers(int oldIndex, int newIndex) {
    final accounts = state.accounts.toList();
    accounts.reorderInPlace(oldIndex, newIndex);
    state = state.copyWith(accounts: accounts);
    ref.read(sharedUtilityProvider).saveAccounts(accounts);
  }

  void addNewUser() {
    state = state.copyWith(
      screen: LoginScreenType.login,
    );
  }

  void goUserSelect() {
    ++_serverAttempt;
    pendingEntryChange = null;
    entryResolution = null;
    _confirmedEntryForLogin = null;
    _manualSeerr = false;
    state = state.copyWith(
      serverLoginModel: state.hasBaseUrl ? state.serverLoginModel : null,
      tempSeerrUrl: null,
      tempSeerrSessionCookie: null,
      errorMessage: null,
      screen: LoginScreenType.users,
      loading: false,
    );
  }

  String? _findSeerrUrlForServer(String? serverId) {
    final url = state.serverLoginModel?.tempCredentials.url;
    if (serverId != null && url != null) {
      final binding =
          ref.read(jmsEntrySettingsProvider).forServer(url, serverId);
      if (binding != null) return binding.config.seerrBaseUrl;
    }
    if (serverId == null || serverId.isEmpty) return FladderConfig.seerrBaseUrl;
    final matches = state.accounts.where(
      (account) =>
          account.credentials.serverId == serverId &&
          (account.seerrCredentials?.serverUrl.isNotEmpty ?? false),
    );

    if (matches.isEmpty) return FladderConfig.seerrBaseUrl;

    final sorted = matches.toList()
      ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));

    return effectiveJmsSeerrCredentials(sorted.first.seerrCredentials)
        .serverUrl;
  }

  void setTempSeerrUrl(String? url, {bool serverProvided = false}) {
    if (!serverProvided) _manualSeerr = true;
    state = state.copyWith(
        tempSeerrUrl: url?.trim().isEmpty == true ? null : url?.trim());
  }

  void setTempSeerrSessionCookie(String? cookie) {
    state = state.copyWith(
        tempSeerrSessionCookie:
            cookie?.trim().isEmpty == true ? null : cookie?.trim());
  }
}
