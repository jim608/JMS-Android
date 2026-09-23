import 'package:fladder/seerr/seerr_source.dart';

class FladderConfig {
  static FladderConfig _instance = FladderConfig._();
  FladderConfig._();

  static String? get baseUrl => _instance._baseUrl;
  static set baseUrl(String? value) => _instance._baseUrl = value;
  String? _baseUrl;

  static String? get seerrBaseUrl => _instance._seerrBaseUrl;
  static set seerrBaseUrl(String? value) => _instance._seerrBaseUrl = normalizeConfiguredSeerrSource(value);
  String? _seerrBaseUrl;

  static void fromJson(Map<String, dynamic> json) => _instance = FladderConfig._fromJson(json);

  factory FladderConfig._fromJson(Map<String, dynamic> json) {
    final config = FladderConfig._();
    final newUrl = json['baseUrl'] as String?;
    final newSeerrUrl = json['seerrBaseUrl'] as String?;

    config._baseUrl = newUrl?.isEmpty == true ? null : newUrl;
    config._seerrBaseUrl = normalizeConfiguredSeerrSource(newSeerrUrl);

    return config;
  }
}
