import 'dart:convert';

import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/util/handheld_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const deckRelease = 'ID=steamos\nVARIANT_ID=steamdeck\n';

  test('auto detects a Steam Deck Gaming Mode session', () {
    expect(
      isSteamDeckGamingMode(
        hostOsRelease: deckRelease,
        environment: {
          'XDG_CURRENT_DESKTOP': 'gamescope',
          'XDG_SESSION_DESKTOP': 'gamescope',
        },
      ),
      isTrue,
    );
    expect(
      isSteamDeckGamingMode(
        hostOsRelease: 'ID="steamos"\nVARIANT_ID="steamdeck"\n',
        environment: {'XDG_CURRENT_DESKTOP': 'gamescope'},
      ),
      isTrue,
    );
  });

  test('auto keeps the desktop UI on a Deck desktop session', () {
    expect(
      isSteamDeckGamingMode(
        hostOsRelease: deckRelease,
        environment: {
          'XDG_CURRENT_DESKTOP': 'KDE',
          'XDG_SESSION_DESKTOP': 'plasma',
        },
      ),
      isFalse,
    );
  });

  test('auto does not treat gamescope on another Linux distro as a Deck', () {
    expect(
      isSteamDeckGamingMode(
        hostOsRelease: 'ID=arch\nVARIANT_ID=steamdeck\n',
        environment: {'XDG_CURRENT_DESKTOP': 'gamescope'},
      ),
      isFalse,
    );
    expect(
      isSteamDeckGamingMode(
        hostOsRelease: 'ID=steamos\nVARIANT_ID=generic\n',
        environment: {'XDG_CURRENT_DESKTOP': 'gamescope'},
      ),
      isFalse,
    );
  });

  test('auto falls back to desktop on incomplete or conflicting evidence', () {
    for (final environment in <Map<String, String>>[
      {},
      {'XDG_SESSION_DESKTOP': 'gamescope'},
      {'XDG_CURRENT_DESKTOP': 'gamescope', 'XDG_SESSION_DESKTOP': 'plasma'},
      {'XDG_CURRENT_DESKTOP': 'gamescope:KDE'},
    ]) {
      expect(
        isSteamDeckGamingMode(hostOsRelease: deckRelease, environment: environment),
        isFalse,
      );
    }
    expect(
      isSteamDeckGamingMode(
        hostOsRelease: '',
        environment: {'XDG_CURRENT_DESKTOP': 'gamescope'},
      ),
      isFalse,
    );
  });

  test('controller and Steam environment flags do not prove Gaming Mode', () {
    expect(
      isSteamDeckGamingMode(
        hostOsRelease: 'ID=ubuntu\n',
        environment: {
          'XDG_CURRENT_DESKTOP': 'GNOME',
          'SteamGameId': '1234',
          'SDL_GAMECONTROLLER_IGNORE_DEVICES': '1',
        },
      ),
      isFalse,
    );
  });

  test('explicit launch flag takes priority over a desktop preference', () {
    expect(
      resolveHandheldMode(
        preference: HandheldModePreference.desktop,
        explicitHandheldFlag: true,
        automaticGamingMode: false,
      ),
      isTrue,
    );
  });

  test('persistent desktop and handheld overrides take priority over auto', () {
    expect(
      resolveHandheldMode(
        preference: HandheldModePreference.desktop,
        explicitHandheldFlag: false,
        automaticGamingMode: true,
      ),
      isFalse,
    );
    expect(
      resolveHandheldMode(
        preference: HandheldModePreference.handheld,
        explicitHandheldFlag: false,
        automaticGamingMode: false,
      ),
      isTrue,
    );
  });

  test('auto uses only the conservative Gaming Mode decision', () {
    expect(
      resolveHandheldMode(
        preference: HandheldModePreference.auto,
        explicitHandheldFlag: false,
        automaticGamingMode: true,
      ),
      isTrue,
    );
    expect(
      resolveHandheldMode(
        preference: HandheldModePreference.auto,
        explicitHandheldFlag: false,
        automaticGamingMode: false,
      ),
      isFalse,
    );
  });

  test('existing saved settings default to auto and an override survives JSON', () {
    final original = jsonDecode(jsonEncode(ClientSettingsModel.defaultModel())) as Map<String, dynamic>;
    final legacy = Map<String, dynamic>.from(original)..remove('handheldModePreference');
    expect(
      ClientSettingsModel.fromJson(legacy).handheldModePreference,
      HandheldModePreference.auto,
    );

    final overridden = ClientSettingsModel.defaultModel().copyWith(
      handheldModePreference: HandheldModePreference.handheld,
    );
    expect(
      ClientSettingsModel.fromJson(
        jsonDecode(jsonEncode(overridden)) as Map<String, dynamic>,
      ).handheldModePreference,
      HandheldModePreference.handheld,
    );
  });
}
