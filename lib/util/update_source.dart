class UpdateSource {
  final String owner;
  final String repo;
  const UpdateSource({
    this.owner = const String.fromEnvironment('JMS_UPDATE_OWNER'),
    this.repo = const String.fromEnvironment('JMS_UPDATE_REPO'),
  });

  bool get configured => owner.isNotEmpty && repo.isNotEmpty;
  bool get valid =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,38}$').hasMatch(owner) &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$').hasMatch(repo) &&
      '$owner/$repo'.toLowerCase() != 'donutware/fladder';
  String get identity => '$owner/$repo';
  Uri get releases => Uri.https('api.github.com', '/repos/$owner/$repo/releases', {'per_page': '20'});

  bool ownsAsset(Uri uri) =>
      valid &&
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty &&
      uri.pathSegments.length == 6 &&
      uri.pathSegments[0] == owner &&
      uri.pathSegments[1] == repo &&
      uri.pathSegments[2] == 'releases' &&
      uri.pathSegments[3] == 'download';

  static bool allowedRedirect(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      const {'release-assets.githubusercontent.com', 'objects.githubusercontent.com'}.contains(uri.host);
}
