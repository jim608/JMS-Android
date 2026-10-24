import 'package:flutter/material.dart';

import 'package:fladder/util/localization_helper.dart';

/// A detail page must remain usable before any item data is available.
class DetailLoadState extends StatelessWidget {
  const DetailLoadState({
    required this.loading,
    required this.onBack,
    this.onRetry,
    super.key,
  });

  final bool loading;
  final VoidCallback onBack;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const CircularProgressIndicator(strokeCap: StrokeCap.round)
                  else
                    Icon(Icons.error_outline,
                        color: Theme.of(context).colorScheme.error, size: 32),
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      loading
                          ? context.localized.loading
                          : context.localized.somethingWentWrong,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          visualDensity: VisualDensity.standard,
                        ),
                        autofocus: loading,
                        onPressed: onBack,
                        icon: const BackButtonIcon(),
                        label: Text(MaterialLocalizations.of(context)
                            .backButtonTooltip),
                      ),
                      if (!loading && onRetry != null)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            visualDensity: VisualDensity.standard,
                          ),
                          autofocus: true,
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh),
                          label: Text(context.localized.retry),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
