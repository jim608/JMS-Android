import 'dart:convert';
import 'dart:io';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'Traditional Chinese defines every message without inheriting Simplified Chinese',
      () {
    final english = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    final traditional =
        jsonDecode(File('lib/l10n/app_zh_Hant.arb').readAsStringSync())
            as Map<String, dynamic>;
    final messages = english.keys.where((key) => !key.startsWith('@'));
    expect(messages.where((key) => !traditional.containsKey(key)), isEmpty,
        reason:
            'Missing Hant messages inherit Simplified Chinese from the zh parent.');
  });

  test('Traditional Chinese UI and parameterized messages stay Traditional',
      () async {
    final traditional = await AppLocalizations.delegate.load(
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    );
    expect(traditional.settingsProfileTitle, '個人資料');
    expect(traditional.controlPanel, '控制面板');
    expect(traditional.pictureInPictureTitle, '子母畫面');
    expect(traditional.posterColorsTitle, '產生海報配色');
    expect(traditional.incognitoModeLocal, '無痕模式（個人資料）');
    expect(traditional.showInSideBar, '顯示於側邊欄');
    expect(traditional.addedToQueue(2), '已將 2 首曲目加入播放佇列');
    expect(traditional.queueItemCount(3), '3 個項目');
    expect(traditional.personAge(28), '年齡：28');
  });
}
