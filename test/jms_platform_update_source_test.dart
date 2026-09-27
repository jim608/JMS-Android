import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/util/update_source.dart';
import 'package:fladder/util/linux_update_bridge_io.dart';
import 'package:fladder/util/windows_update_bridge_io.dart';

void main() {
  test('platform feeds and downloader trust have independent repositories', () {
    expect(UpdateSource.forPlatform('windows').identity, 'jim608/JMS-Desktop');
    expect(UpdateSource.forPlatform('linux').identity, 'jim608/JMS-Linux');
    expect(UpdateSource.forPlatform('android').identity,
        const UpdateSource().identity);
    final windows = WindowsUpdateBridge().source;
    final linux = LinuxUpdateBridge().source;
    final windowsAsset = Uri.parse(
        'https://github.com/jim608/JMS-Desktop/releases/download/v20/setup.exe');
    final linuxAsset = Uri.parse(
        'https://github.com/jim608/JMS-Linux/releases/download/v20/package.pkg.tar.xz');
    expect(windows.ownsAsset(windowsAsset), isTrue);
    expect(linux.ownsAsset(linuxAsset), isTrue);
    expect(windows.ownsAsset(linuxAsset), isFalse);
    expect(linux.ownsAsset(windowsAsset), isFalse);
  });
}
