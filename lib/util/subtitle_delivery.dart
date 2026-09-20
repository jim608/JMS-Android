String? subtitleDeliveryUrl(String? deliveryUrl, String codec) {
  if (deliveryUrl == null || deliveryUrl.isEmpty) return null;
  final uri = Uri.tryParse(deliveryUrl);
  if (uri == null) return null;
  final normalizedCodec = codec.trim().toLowerCase();
  final extension = switch (normalizedCodec) {
    'ass' || 'ssa' => normalizedCodec,
    _ => 'srt',
  };
  final query = uri.queryParametersAll;
  final styled = normalizedCodec == 'ass' || normalizedCodec == 'ssa';
  final formatKeys = query.keys.where((key) => key.toLowerCase() == 'format');
  return uri
      .replace(
        path: uri.path.replaceFirst(RegExp(r'\.(vtt|srt)$', caseSensitive: false), '.$extension'),
        queryParameters: styled && formatKeys.isNotEmpty
            ? {
                for (final entry in query.entries)
                  entry.key: entry.key.toLowerCase() == 'format' ? [extension] : entry.value
              }
            : null,
      )
      .toString();
}
