import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fladder/services/playback_diagnostics.dart' as diagnostics;
import 'package:fladder/util/localization_helper.dart';

/// Opens an in-memory, redacted snapshot. Export requires a separate user action.
Future<void> showPlaybackDiagnostics(BuildContext context) {
  String report;
  try {
    report = diagnostics.PlaybackDiagnostics.instance.exportText();
  } catch (_) {
    report = context.localized.somethingWentWrong;
  }
  return showDialog<void>(
    context: context,
    builder: (context) => _PlaybackDiagnosticsDialog(report: report),
  );
}

class _PlaybackDiagnosticsDialog extends StatefulWidget {
  const _PlaybackDiagnosticsDialog({required this.report});

  final String report;

  @override
  State<_PlaybackDiagnosticsDialog> createState() =>
      _PlaybackDiagnosticsDialogState();
}

class _PlaybackDiagnosticsDialogState
    extends State<_PlaybackDiagnosticsDialog> {
  final _scrollController = ScrollController();
  bool _exporting = false;
  String? _status;

  bool get _chinese => Localizations.localeOf(context).languageCode == 'zh';
  String get _title => _chinese ? '播放診斷' : 'Playback diagnostics';

  void _setStatus(String status) {
    if (mounted) setState(() => _status = status);
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.report));
      if (mounted) _setStatus(context.localized.copiedToClipboard);
    } catch (_) {
      if (mounted) _setStatus(context.localized.somethingWentWrong);
    }
  }

  Future<void> _save() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: _title,
        fileName: 'JMS-playback-diagnostics.txt',
        type: FileType.custom,
        allowedExtensions: const ['txt'],
        bytes: Uint8List.fromList(utf8.encode(widget.report)),
      );
      // Web starts a browser download and returns null; native null is cancel.
      if (mounted && kIsWeb) {
        _setStatus(_chinese ? '已交由瀏覽器下載。' : 'Download requested.');
      } else if (mounted && path != null) {
        _setStatus(context.localized.saved);
      }
    } catch (_) {
      if (mounted) _setStatus(context.localized.somethingWentWrong);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      visualDensity: VisualDensity.standard,
    );
    return FocusTraversalGroup(
      child: AlertDialog(
        title: Text(_title),
        content: SizedBox(
          width: 560,
          height: (MediaQuery.sizeOf(context).height * 0.5)
              .clamp(120.0, 360.0)
              .toDouble(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_chinese
                  ? '僅在你選擇複製或儲存時匯出；此視窗不會上傳報告。'
                  : 'Export only when you choose Copy or Save. This dialog does not upload the report.'),
              const SizedBox(height: 12),
              Expanded(
                child: PrimaryScrollController(
                  controller: _scrollController,
                  child: Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      primary: true,
                      child: SelectableText(
                        widget.report,
                        key: const ValueKey('playback-diagnostics-preview'),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                ),
              ),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Semantics(liveRegion: true, child: Text(_status!)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            autofocus: true,
            style: buttonStyle,
            onPressed: _exporting ? null : _copy,
            icon: const Icon(Icons.copy),
            label: Text(MaterialLocalizations.of(context).copyButtonLabel),
          ),
          TextButton.icon(
            style: buttonStyle,
            onPressed: _exporting ? null : _save,
            icon: const Icon(Icons.save_alt),
            label: Text(context.localized.save),
          ),
          TextButton(
            style: buttonStyle,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.localized.close),
          ),
        ],
      ),
    );
  }
}
