import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/input_handler.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/subtitle_offset.dart';

final subtitleOffsetVisibleProvider =
    StateProvider.autoDispose<bool>((ref) => false);

class SubtitleOffsetButton extends ConsumerWidget {
  const SubtitleOffsetButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(videoPlayerProvider).subtitleOffsets;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) => IconButton(
        key: const Key('subtitle-offset-open'),
        tooltip: context.localized.jmsSubtitleOffsetTitle,
        icon: const Icon(Icons.sync_alt_rounded),
        onPressed: controller.primaryAvailable
            ? () =>
                ref.read(subtitleOffsetVisibleProvider.notifier).state = true
            : null,
      ),
    );
  }
}

class SubtitleOffsetTile extends ConsumerWidget {
  const SubtitleOffsetTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(videoPlayerProvider).subtitleOffsets;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) => ListTile(
        leading: const Icon(Icons.sync_alt_rounded),
        title: Text(context.localized.jmsSubtitleOffsetTitle),
        subtitle: Text(controller.primaryAvailable
            ? context.localized.jmsSubtitleOffsetSecondsValue(
                formatSubtitleOffsetSeconds(controller.primary))
            : context.localized.jmsSubtitleOffsetInactive),
        onTap: controller.primaryAvailable
            ? () {
                ref.read(subtitleOffsetVisibleProvider.notifier).state = true;
                Navigator.pop(context);
              }
            : null,
      ),
    );
  }
}

/// Kept inside the player's input/overlay tree so playback and its controls stay
/// mounted while timing is adjusted. No route change or pause/resume is needed.
class SubtitleOffsetOverlay extends ConsumerWidget {
  const SubtitleOffsetOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(subtitleOffsetVisibleProvider)) {
      return const SizedBox.shrink();
    }
    final controller = ref.watch(videoPlayerProvider).subtitleOffsets;
    if (controller == null) return const SizedBox.shrink();
    void close() =>
        ref.read(subtitleOffsetVisibleProvider.notifier).state = false;
    return PlayerShortcutBoundary(
        child: FocusScope(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const Key('subtitle-offset-dismiss'),
            behavior: HitTestBehavior.opaque,
            onTap: close,
            child: const SizedBox.expand(),
          ),
          SafeArea(
            child: Padding(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom),
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SubtitleOffsetPanel(
                        controller: controller, onClose: close),
                  ),
                )),
          ),
        ],
      ),
    ));
  }
}

class SubtitleOffsetPanel extends StatelessWidget {
  const SubtitleOffsetPanel(
      {required this.controller, required this.onClose, super.key});

  final SubtitleOffsetController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
          maxWidth: 360, maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      child: Material(
        key: const Key('subtitle-offset-panel'),
        color: Theme.of(context)
            .colorScheme
            .surfaceContainer
            .withValues(alpha: 0.94),
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                        child: Text(context.localized.jmsSubtitleOffsetTitle,
                            style: Theme.of(context).textTheme.titleMedium)),
                    IconButton(
                      key: const Key('subtitle-offset-close'),
                      tooltip: context.localized.close,
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, child) => SubtitleOffsetControls(
                    controller: controller,
                    primaryEnabled: controller.primaryAvailable,
                    secondaryEnabled: controller.secondaryAvailable,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Playback controls kept separate from player/provider lookup for accessibility
/// and interaction tests.
class SubtitleOffsetControls extends StatelessWidget {
  const SubtitleOffsetControls({
    required this.controller,
    required this.secondaryEnabled,
    this.primaryEnabled = true,
    super.key,
  });

  final SubtitleOffsetController controller;
  final bool primaryEnabled;
  final bool secondaryEnabled;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.localized.jmsSubtitleOffsetSecondsHelp),
          const SizedBox(height: 16),
          _SubtitleOffsetRow(
            key: ValueKey(('primary-offset-row', controller.editRevision())),
            controller: controller,
            value: controller.primary,
            available: primaryEnabled,
          ),
          if (secondaryEnabled) ...[
            const SizedBox(height: 20),
            _SubtitleOffsetRow(
              key: ValueKey((
                'secondary-offset-row',
                controller.editRevision(secondary: true)
              )),
              controller: controller,
              value: controller.secondary,
              available: secondaryEnabled,
              secondary: true,
            ),
          ],
          if (!primaryEnabled) ...[
            const SizedBox(height: 12),
            Text(context.localized.jmsSubtitleOffsetInactive),
          ],
          if (controller.busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (controller.failed) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                context.localized.jmsSubtitleOffsetFailed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubtitleOffsetRow extends StatefulWidget {
  const _SubtitleOffsetRow({
    required this.controller,
    required this.value,
    required this.available,
    this.secondary = false,
    super.key,
  });

  final SubtitleOffsetController controller;
  final Duration value;
  final bool available;
  final bool secondary;

  @override
  State<_SubtitleOffsetRow> createState() => _SubtitleOffsetRowState();
}

class _SubtitleOffsetRowState extends State<_SubtitleOffsetRow> {
  late final TextEditingController _text;
  final FocusNode _focus = FocusNode();
  Duration? _preview;
  bool _invalid = false;
  bool _dirty = false;
  int _epoch = 0;
  int? _dragEpoch;

  Duration get _actual => widget.secondary
      ? widget.controller.secondary
      : widget.controller.primary;
  bool get _enabled => widget.available && !widget.controller.busy;
  String get _prefix => widget.secondary ? 'secondary' : 'primary';

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(
      text: formatSubtitleOffsetSeconds(widget.value, showPositiveSign: false),
    );
  }

  @override
  void didUpdateWidget(covariant _SubtitleOffsetRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.value != widget.value ||
        (oldWidget.available && !widget.available) ||
        (widget.controller.busy && _preview != null)) {
      _epoch++;
      _restore();
    }
  }

  void _setText(Duration value) {
    final text = formatSubtitleOffsetSeconds(value, showPositiveSign: false);
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _restore() {
    _preview = null;
    _dragEpoch = null;
    _invalid = false;
    _dirty = false;
    _setText(_actual);
  }

  Future<void> _apply(Duration value) async {
    if (!_enabled) return;
    final epoch = _epoch;
    setState(() {
      _preview = null;
      _dragEpoch = null;
      _invalid = false;
    });
    await widget.controller.setOffset(value, secondary: widget.secondary);
    if (!mounted || epoch != _epoch) return;
    setState(_restore);
  }

  void _submit() {
    if (!_enabled) return;
    final value = parseSubtitleOffsetSeconds(_text.text);
    if (value == null) {
      setState(() => _invalid = true);
      return;
    }
    _apply(value);
  }

  void _startDrag(double value) {
    _focus.unfocus();
    _dragEpoch = _epoch;
  }

  void _previewDrag(double value) {
    if (_dragEpoch != _epoch) return;
    final offset = subtitleOffsetFromSliderSeconds(value);
    setState(() {
      _preview = offset;
      _invalid = false;
      _dirty = true;
      _setText(offset);
    });
  }

  void _endDrag(double value) {
    if (_dragEpoch != _epoch) return;
    _apply(subtitleOffsetFromSliderSeconds(value));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayed = _preview ?? widget.value;
    final label = context.localized
        .jmsSubtitleOffsetSecondsValue(formatSubtitleOffsetSeconds(displayed));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.secondary
              ? context.localized.jmsSecondarySubtitle
              : context.localized.jmsSubtitleOffsetPrimary,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Semantics(
          liveRegion: true,
          child: Text(
            label,
            key: Key('subtitle-offset-$_prefix-value'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: Key('subtitle-offset-$_prefix-input'),
                controller: _text,
                focusNode: _focus,
                enabled: widget.available,
                readOnly: widget.controller.busy,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: true),
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: context.localized.jmsSubtitleOffsetSecondsInput,
                  suffixText: context.localized.jmsSubtitleOffsetSecondsUnit,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {
                  _invalid = false;
                  _dirty = true;
                }),
                onEditingComplete: () {},
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: Key('subtitle-offset-$_prefix-apply'),
              tooltip: context.localized.jmsSubtitleOffsetSecondsApply,
              onPressed: _enabled && _dirty ? _submit : null,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        if (_invalid) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              context.localized.jmsSubtitleOffsetSecondsInvalid,
              key: Key('subtitle-offset-$_prefix-invalid'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        Slider(
          key: Key('subtitle-offset-$_prefix-slider'),
          value: displayed.inMilliseconds / 1000,
          min: -60,
          max: 60,
          divisions: 12000,
          label: label,
          semanticFormatterCallback: (value) => context.localized
              .jmsSubtitleOffsetSecondsValue(formatSubtitleOffsetSeconds(
                  subtitleOffsetFromSliderSeconds(value))),
          onChangeStart: _enabled ? _startDrag : null,
          onChanged: _enabled ? _previewDrag : null,
          onChangeEnd: _enabled ? _endDrag : null,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              key: Key('subtitle-offset-$_prefix-earlier'),
              onPressed: _enabled &&
                      widget.value > -SubtitleOffsetController.limit
                  ? () => _apply(widget.value - SubtitleOffsetController.step)
                  : null,
              child: Text(context.localized.jmsSubtitleOffsetSecondsEarlier),
            ),
            OutlinedButton(
              key: Key('subtitle-offset-$_prefix-later'),
              onPressed: _enabled &&
                      widget.value < SubtitleOffsetController.limit
                  ? () => _apply(widget.value + SubtitleOffsetController.step)
                  : null,
              child: Text(context.localized.jmsSubtitleOffsetSecondsLater),
            ),
            TextButton(
              key: Key('subtitle-offset-$_prefix-reset'),
              onPressed: _enabled && (widget.value != Duration.zero || _dirty)
                  ? () => _apply(Duration.zero)
                  : null,
              child: Text(context.localized.jmsSubtitleOffsetSecondsReset),
            ),
          ],
        ),
      ],
    );
  }
}
