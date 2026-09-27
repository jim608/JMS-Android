import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/seerr_credentials_model.dart';

const jmsSeerrSource = String.fromEnvironment('JMS_SEERR_SOURCE');
const legacyJmsSeerrSource = String.fromEnvironment('JMS_LEGACY_SEERR_SOURCE');

String? seerrSourceForLogin(AccountModel account,
    {String? loginSource, String? configuredSource}) {
  return normalizeConfiguredSeerrSource(account.seerrCredentials?.serverUrl) ??
      normalizeConfiguredSeerrSource(loginSource) ??
      normalizeConfiguredSeerrSource(configuredSource) ??
      normalizeConfiguredSeerrSource(jmsSeerrSource);
}

bool isLegacyJmsSeerrSource(String value) {
  final source = value.trim().replaceAll(RegExp(r'/+$'), '');
  return jmsSeerrSource.isNotEmpty &&
      legacyJmsSeerrSource.isNotEmpty &&
      source == legacyJmsSeerrSource;
}

String? normalizeConfiguredSeerrSource(String? value) {
  final source = value?.trim();
  if (source == null || source.isEmpty) return null;
  return isLegacyJmsSeerrSource(source) ? jmsSeerrSource : source;
}

bool needsJmsSeerrSourceMigration(AccountModel account) {
  final source = account.seerrCredentials?.serverUrl;
  return source != null && isLegacyJmsSeerrSource(source);
}

AccountModel migrateJmsSeerrSource(AccountModel account) {
  if (!needsJmsSeerrSourceMigration(account)) return account;
  return account.copyWith(
    seerrCredentials: effectiveJmsSeerrCredentials(account.seerrCredentials),
  );
}

SeerrCredentialsModel effectiveJmsSeerrCredentials(
    SeerrCredentialsModel? credentials,
    {String? configuredSource}) {
  if (credentials != null && isLegacyJmsSeerrSource(credentials.serverUrl)) {
    return const SeerrCredentialsModel(serverUrl: jmsSeerrSource);
  }
  if (credentials != null && credentials.serverUrl.trim().isNotEmpty) {
    return credentials;
  }
  return SeerrCredentialsModel(
      serverUrl:
          normalizeConfiguredSeerrSource(configuredSource) ?? jmsSeerrSource);
}
