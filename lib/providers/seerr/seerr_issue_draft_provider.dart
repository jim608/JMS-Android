import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/providers/user_provider.dart';

final seerrIssueDraftProvider = StateProvider<Map<String, String>>((ref) {
  ref.watch(userProvider.select((account) => (account?.id, account?.credentials.serverId, account?.seerrCredentials?.serverUrl)));
  return const {};
});
