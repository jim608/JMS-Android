import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/widgets/shared/fladder_slider.dart';

class AmbientControls extends ConsumerStatefulWidget {
  const AmbientControls({super.key});

  @override
  ConsumerState<AmbientControls> createState() => _AmbientControlsState();
}

class _AmbientControlsState extends ConsumerState<AmbientControls> {
  AmbientAppearance? _pending;
  StateController<AmbientAppearance?>? _preview;

  void _change(AmbientAppearance appearance) {
    _pending = appearance;
    _preview = ref.read(ambientPreviewProvider.notifier);
    _preview!.state = appearance;
  }

  void _save() {
    if (_pending != null) ref.read(videoPlayerSettingsProvider.notifier).setAmbientAppearance(_pending!);
    _preview?.state = null;
    _pending = null;
  }

  @override
  void dispose() {
    final controller = _preview;
    final pending = _pending;
    if (pending != null && controller != null) {
      Future.microtask(() {
        if (controller.mounted && controller.state == pending) controller.state = null;
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(ambientAppearanceProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${context.localized.jmsAmbientIntensity}: ${(appearance.intensity * 100).round()}%'),
        FladderSlider(
          key: const Key('ambient-intensity'),
          value: appearance.intensity,
          divisions: 20,
          onChanged: (value) => _change((intensity: value, spread: appearance.spread)),
          onChangeEnd: (_) => _save(),
        ),
        Text('${context.localized.jmsAmbientSpread}: ${(appearance.spread * 100).round()}%'),
        FladderSlider(
          key: const Key('ambient-spread'),
          value: appearance.spread,
          divisions: 20,
          onChanged: (value) => _change((intensity: appearance.intensity, spread: value)),
          onChangeEnd: (_) => _save(),
        ),
        Text(context.localized.jmsAmbientAppearanceHelp, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
