import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/sleep_timer_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/sleep_timer.dart';

class SleepTimerTile extends ConsumerWidget {
  const SleepTimerTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(sleepTimerProvider);
    return ListTile(
      leading: const Icon(Icons.bedtime_outlined),
      title: Text(context.localized.jmsSleepTitle),
      subtitle: Text(context.localized.jmsSleepState(timer.pauseFailed ? 'failed' : timer.mode.name)),
      onTap: () => showDialog<void>(context: context, builder: (_) => const SleepTimerDialog()),
    );
  }
}

class SleepTimerDialog extends ConsumerStatefulWidget {
  const SleepTimerDialog({super.key});

  @override
  ConsumerState<SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends ConsumerState<SleepTimerDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _minutes;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    final current = ref.read(sleepTimerProvider);
    _minutes =
        TextEditingController(text: current.deadline == null ? '30' : '${current.remaining.inMinutes.clamp(1, 720)}');
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timer = ref.watch(sleepTimerProvider);
    final mediaId = ref.watch(playBackModel.select((model) => model?.item.id));
    final seconds = timer.remaining.inSeconds;
    final remaining = '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    final endSupported = ref.read(videoPlayerProvider).backend != null;
    return AlertDialog(
      title: Text(context.localized.jmsSleepTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.localized.jmsSleepState(timer.pauseFailed ? 'failed' : timer.mode.name)),
              if (timer.mode == SleepTimerMode.countdown) Text(context.localized.jmsSleepRemaining(remaining)),
              const SizedBox(height: 12),
              Text(context.localized.jmsSleepBehavior),
              const SizedBox(height: 12),
              TextFormField(
                controller: _minutes,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: context.localized.jmsSleepMinutes),
                validator: (value) {
                  final minutes = int.tryParse(value ?? '');
                  return minutes == null || minutes < 1 || minutes > 720 ? context.localized.jmsSleepMinutes : null;
                },
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  if (!_form.currentState!.validate()) return;
                  timer.countdown(Duration(minutes: int.parse(_minutes.text)));
                },
                child: Text(context.localized.jmsSleepAction('start')),
              ),
              TextButton(
                onPressed: mediaId == null || !endSupported ? null : () => timer.afterEpisode(mediaId),
                child: Text(context.localized.jmsSleepAction('episode')),
              ),
              if (!endSupported) Text(context.localized.jmsSleepState('unsupported')),
              TextButton(onPressed: timer.cancel, child: Text(context.localized.jmsSleepAction('cancel'))),
            ]),
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.localized.close))],
    );
  }
}
