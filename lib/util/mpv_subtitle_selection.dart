import 'package:fladder/util/mpv_subtitle_route.dart';

bool useExternalSubtitleSource({
  required bool isExternal,
  required bool transcoded,
  required bool supportsExternalStream,
  required String codec,
  required String? url,
}) =>
    isExternal || (transcoded && isStyledSubtitle(codec) && supportsExternalStream && url != null && url.isNotEmpty);
