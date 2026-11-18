import 'package:flutter_riverpod/flutter_riverpod.dart';

final _refProvider = Provider<Ref>((ref) => ref);

Ref playbackTestRef([ProviderContainer? container]) =>
    (container ?? ProviderContainer.test()).read(_refProvider);
