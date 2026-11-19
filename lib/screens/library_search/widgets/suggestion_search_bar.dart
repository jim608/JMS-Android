import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/providers/library_search_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/screens/shared/outlined_text_field.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/fladder_image.dart';
import 'package:fladder/util/localization_helper.dart';

class SuggestionSearchBar extends ConsumerStatefulWidget {
  final String? title;
  final bool autoFocus;
  final Duration debounceDuration;
  final SuggestionsController<ItemBaseModel>? suggestionsBoxController;
  final Function(String value)? onSubmited;
  final Function(String value)? onChanged;
  final Function(ItemBaseModel value)? onItem;
  const SuggestionSearchBar({
    this.title,
    this.autoFocus = false,
    this.debounceDuration = const Duration(milliseconds: 250),
    this.suggestionsBoxController,
    this.onSubmited,
    this.onChanged,
    this.onItem,
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SearchBarState();
}

class _SearchBarState extends ConsumerState<SuggestionSearchBar> {
  final _ownedSuggestions = SuggestionsController<ItemBaseModel>();
  SuggestionsController<ItemBaseModel> get suggestionsBoxController =>
      widget.suggestionsBoxController ?? _ownedSuggestions;
  final TextEditingController textEditingController = TextEditingController();
  bool isEmpty = true;

  @override
  void initState() {
    super.initState();
    final query = ref.read(librarySearchProvider(widget.key!).select((value) => value.filters.searchQuery));
    textEditingController.text = query;
    isEmpty = query.isEmpty;
  }

  @override
  void dispose() {
    textEditingController.dispose();
    _ownedSuggestions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final classic = ref.watch(classicInterfaceProvider);
    final useScreenWidth = !classic && MediaQuery.sizeOf(context).width < 600;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    ref.listen(librarySearchProvider(widget.key!).select((value) => value.filters.searchQuery), (previous, next) {
      if (textEditingController.text != next) {
        setState(() {
          textEditingController.text = next;
          isEmpty = next.isEmpty;
        });
      }
    });
    return Container(
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow),
      child: TypeAheadField<ItemBaseModel>(
        debounceDuration: widget.debounceDuration,
        constrainWidth: !useScreenWidth,
        offset: useScreenWidth ? const Offset(12, 6) : null,
        controller: textEditingController,
        hideOnEmpty: isEmpty,
        emptyBuilder: (context) => Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text("${context.localized.noSuggestionsFound}...", style: Theme.of(context).textTheme.titleMedium),
        ),
        suggestionsController: suggestionsBoxController,
        decorationBuilder: (context, child) => classic
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: FladderTheme.smallShape.borderRadius,
                ),
                child: child,
              )
            : Material(
                color: colors.surfaceContainerHigh,
                elevation: 4,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: child,
              ),
        builder: (context, controller, focusNode) => OutlinedTextField(
          focusNode: focusNode,
          autoFocus: widget.autoFocus,
          controller: controller,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) {
            widget.onSubmited?.call(value);
            suggestionsBoxController.close();
          },
          onChanged: (value) {
            setState(() {
              isEmpty = value.isEmpty;
            });
          },
          searchQuery: (query) async {
            if (query.isEmpty) return [];
            if (widget.key != null) {
              final items = await ref
                  .read(librarySearchProvider(widget.key!).notifier)
                  .fetchSuggestions(query, limit: 5);
              return items.map((e) => e.name).toList();
            }
            return [];
          },
          placeHolder: widget.title ?? "${context.localized.search}...",
          decoration: InputDecoration(
            hintText: widget.title ?? "${context.localized.search}...",
            prefixIcon: const Icon(IconsaxPlusLinear.search_normal),
            contentPadding: const EdgeInsets.only(top: 13),
            suffixIcon: controller.text.isNotEmpty
                ? IconButton(
                    tooltip: context.localized.clear,
                    onPressed: () {
                      widget.onSubmited?.call('');
                      controller.text = '';
                      suggestionsBoxController.close();
                      setState(() {
                        isEmpty = true;
                      });
                    },
                    icon: const Icon(Icons.clear),
                  )
                : null,
            border: InputBorder.none,
          ),
        ),
        loadingBuilder: (context) => const SizedBox(
          height: 50,
          child: Center(child: CircularProgressIndicator(strokeCap: StrokeCap.round)),
        ),
        onSelected: (suggestion) {
          if (widget.onItem != null) {
            widget.onItem!(suggestion);
          } else {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => suggestion.detailScreenWidget));
          }
        },
        itemBuilder: (context, suggestion) {
          if (!classic) {
            final image = suggestion.images?.primary;
            final year = suggestion.overview.yearAired;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 40,
                      height: 54,
                      child: image == null
                          ? ColoredBox(
                              color: colors.surfaceContainerHighest,
                              child: Icon(suggestion.type.icon, color: colors.onSurfaceVariant),
                            )
                          : FladderImage(image: image, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          suggestion.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [suggestion.type.label(context.localized), if (year != null) year].join('  ·  '),
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 50, maxHeight: 65),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                      child: AspectRatio(
                        aspectRatio: 0.8,
                        child: FladderImage(image: suggestion.images?.primary, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Flexible(child: Text(suggestion.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          if (suggestion.overview.yearAired != null)
                            Flexible(
                              child: Opacity(
                                opacity: 0.45,
                                child: Text(suggestion.overview.yearAired?.toString() ?? ""),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
        suggestionsCallback: (pattern) async {
          if (pattern.isEmpty) return [];
          if (widget.key != null) {
            return (await ref.read(librarySearchProvider(widget.key!).notifier).fetchSuggestions(pattern));
          }
          return [];
        },
      ),
    );
  }
}
