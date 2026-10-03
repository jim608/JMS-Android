import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/ambient_interval.dart';
import 'package:fladder/widgets/shared/fladder_slider.dart';

class AmbientControls extends ConsumerStatefulWidget {
  const AmbientControls({super.key});

  @override
  ConsumerState<AmbientControls> createState() => _AmbientControlsState();
}

class _AmbientControlsState extends ConsumerState<AmbientControls> {
  AmbientAppearance? _pending;
  StateController<AmbientAppearance?>? _preview;
  double? _pendingInterval;
  StateController<double?>? _intervalPreview;

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

  void _changeInterval(double value) {
    _pendingInterval = boundedAmbientIntervalSeconds(value);
    _intervalPreview = ref.read(ambientIntervalPreviewProvider.notifier);
    _intervalPreview!.state = _pendingInterval;
  }

  void _saveInterval() {
    final pending = _pendingInterval;
    if (pending != null) ref.read(videoPlayerSettingsProvider.notifier).setAmbientIntervalSeconds(pending);
    _intervalPreview?.state = null;
    _pendingInterval = null;
  }

  Future<void> _editInterval(double value) async {
    final form = GlobalKey<FormState>();
    var text = value.toStringAsFixed(3);
    final labels = context.localized;
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(labels.jmsAmbientInterval),
        content: Form(
          key: form,
          child: TextFormField(
            key: const Key('ambient-interval-input'),
            initialValue: text,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: labels.jmsAmbientInterval),
            onChanged: (value) => text = value,
            validator: (value) {
              final normalized = value?.trim().replaceAll(',', '.') ?? '';
              final seconds = double.tryParse(normalized);
              return RegExp(r'^\d*(?:\.\d{1,3})?$').hasMatch(normalized) &&
                      seconds != null &&
                      seconds.isFinite &&
                      seconds >= ambientMinimumIntervalSeconds &&
                      seconds <= ambientMaximumIntervalSeconds
                  ? null
                  : labels.jmsAmbientIntervalInvalid;
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(labels.cancel)),
          FilledButton(
            key: const Key('ambient-interval-save'),
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(context, double.parse(text.trim().replaceAll(',', '.')));
            },
            child: Text(labels.save),
          ),
        ],
      ),
    );
    if (result != null && mounted) ref.read(videoPlayerSettingsProvider.notifier).setAmbientIntervalSeconds(result);
  }

  @override
  void dispose() {
    final controller = _preview;
    final pending = _pending;
    final intervalController = _intervalPreview;
    final pendingInterval = _pendingInterval;
    if (pending != null && controller != null) {
      Future.microtask(() {
        if (controller.mounted && controller.state == pending) controller.state = null;
      });
    }
    if (pendingInterval != null && intervalController != null) {
      Future.microtask(() {
        if (intervalController.mounted && intervalController.state == pendingInterval) intervalController.state = null;
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(ambientAppearanceProvider);
    final interval = ref.watch(ambientIntervalProvider);
    final synchronized = ref.watch(videoPlayerSettingsProvider.select((settings) => settings.ambientSyncToPlayback));
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
        SwitchListTile(
          key: const Key('ambient-sync-to-playback'),
          contentPadding: EdgeInsets.zero,
          title: Text(context.localized.jmsAmbientSync),
          subtitle: Text(context.localized.jmsAmbientSyncHelp),
          value: synchronized,
          onChanged: (value) {
            _saveInterval();
            ref.read(videoPlayerSettingsProvider.notifier).setAmbientSyncToPlayback(value);
          },
        ),
        ...[
          Row(children: [
            Expanded(child: Text(context.localized.jmsAmbientInterval)),
            TextButton(
              key: const Key('ambient-interval-edit'),
              onPressed: () => _editInterval(interval),
              child: Text(context.localized.jmsAmbientIntervalValue(interval.toStringAsFixed(3))),
            ),
          ]),
          FladderSlider(
            key: const Key('ambient-interval'),
            value: interval,
            min: ambientMinimumIntervalSeconds,
            max: ambientMaximumIntervalSeconds,
            divisions: 120,
            decimalPlaces: 3,
            onChanged: _changeInterval,
            onChangeEnd: (_) => _saveInterval(),
          ),
          Text(context.localized.jmsAmbientIntervalHelp, style: Theme.of(context).textTheme.bodySmall),
          if (interval < 0.5)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(context.localized.jmsAmbientFastWarning,
                  key: const Key('ambient-fast-warning'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ]),
    );
  }
}
