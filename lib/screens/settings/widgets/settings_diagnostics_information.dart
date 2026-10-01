import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/diagnostics_provider.dart';
import 'package:fladder/util/localization_helper.dart';

class SettingsDiagnosticsInformation extends ConsumerWidget {
  const SettingsDiagnosticsInformation({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(diagnosticsProvider);
    final labels = context.localized;
    return Column(
      children: [
        SwitchListTile(
          title: Text(labels.jmsDiagnosticsTitle),
          subtitle: Text(settings.configured
              ? labels.jmsDiagnosticsHint
              : labels.jmsDiagnosticsUnconfigured),
          value: settings.enabled,
          onChanged: !settings.configured && !settings.enabled
              ? null
              : (value) async {
                  if (value) {
                    final accepted = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(labels.jmsDiagnosticsTitle),
                        content: Text(labels.jmsDiagnosticsConsent),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(labels.cancel),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(labels.jmsDiagnosticsEnable),
                          ),
                        ],
                      ),
                    );
                    if (accepted != true) return;
                  }
                  final saved = await settings.setEnabled(value);
                  if (!saved && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(labels.jmsDiagnosticsSaveError)));
                  }
                },
        ),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: Text(labels.jmsDiagnosticsEndpoint),
          subtitle: Text(labels.jmsDiagnosticsEndpointHint),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _editEndpoint(context, settings),
        ),
      ],
    );
  }

  Future<void> _editEndpoint(
      BuildContext context, DiagnosticsSettings settings) async {
    final labels = context.localized;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => _EndpointDialog(value: settings.endpointValue),
    );
    if (value == null) return;
    final saved = await settings.setEndpoint(value);
    if (!saved && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(labels.jmsDiagnosticsInvalidEndpoint)));
    }
  }
}

class _EndpointDialog extends StatefulWidget {
  const _EndpointDialog({required this.value});
  final String value;

  @override
  State<_EndpointDialog> createState() => _EndpointDialogState();
}

class _EndpointDialogState extends State<_EndpointDialog> {
  late final controller = TextEditingController(text: widget.value);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.localized;
    return AlertDialog(
      title: Text(labels.jmsDiagnosticsEndpoint),
      content: TextField(
        controller: controller,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: labels.jmsDiagnosticsEndpoint,
          helperText: labels.jmsDiagnosticsEndpointHint,
          helperMaxLines: 4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(labels.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(labels.save),
        ),
      ],
    );
  }
}
