import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/seerr/seerr_report_dialog.dart';
import 'package:fladder/screens/seerr/seerr_support_text.dart';
import 'package:fladder/util/item_base_model/play_item_helpers.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart' as jelly;

final _playableProvider = FutureProvider.autoDispose
    .family<ItemBaseModel?, (int, bool)>((ref, target) async {
  final service = ref.watch(seerrApiProvider);
  final account = ref.watch(userProvider);
  if (account?.policy?.enableMediaPlayback != true) return null;
  try {
    final media = target.$2
        ? (await service.tvDetails(tvId: target.$1)).body?.mediaInfo
        : (await service.movieDetails(tmdbId: target.$1)).body?.mediaInfo;
    if (media?.tmdbId != target.$1 || !{4, 5}.contains(media?.status)) {
      return null;
    }
    final id = media?.primaryJellyfinMediaId;
    if (id == null || id.isEmpty) return null;
    final response = await ref
        .read(jellyApiProvider)
        .usersUserIdItemsItemIdGetBaseItem(itemId: id);
    final item = response.body;
    if (response.statusCode != 200 ||
        item?.id != id ||
        item?.type !=
            (target.$2 ? jelly.BaseItemKind.series : jelly.BaseItemKind.movie)) {
      return null;
    }
    final providerId = item?.providerIds?.entries
        .where((entry) => entry.key.toLowerCase() == 'tmdb')
        .firstOrNull
        ?.value;
    if (int.tryParse(providerId ?? '') != target.$1) return null;
    return ItemBaseModel.fromBaseDto(item!, ref);
  } catch (_) {
    return null;
  }
});

class SeerrMediaActions extends ConsumerWidget {
  final int tmdbId;
  final bool isTv;
  const SeerrMediaActions(
      {super.key, required this.tmdbId, required this.isTv});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playable = ref.watch(_playableProvider((tmdbId, isTv))).valueOrNull;
    return Wrap(spacing: 8, children: [
      OutlinedButton.icon(
          icon: const Icon(Icons.report_problem_outlined),
          onPressed: () =>
              openSeerrReport(context, ref, tmdbId: tmdbId, isTv: isTv),
          label: Text(seerrText(context, 'Report a problem', '回報問題'))),
      if (playable != null)
        FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            onPressed: () => isTv
                ? playable.navigateTo(context)
                : playable.play(context, ref),
            label: Text(isTv
                ? seerrText(
                    context, 'Choose an episode in Jellyfin', '前往 Jellyfin 選集')
                : seerrText(context, 'Play now', '立即播放'))),
    ]);
  }
}
