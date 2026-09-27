part of '../providers/seerr_service_provider.dart';

extension SeerrIssues on SeerrService {
  T _body<T>(Response<T> response) {
    seerrCheckStatus(response.statusCode);
    if (response.body == null) throw const SeerrFailure('invalid_response');
    return response.body as T;
  }

  Future<SeerrUserModel> issueUser() async {
    final user = _body(await me());
    if (user.id == null) throw const SeerrFailure('session_expired');
    return user;
  }

  Future<SeerrIssueTarget> issueTarget(int tmdbId, bool isTv) async {
    if (tmdbId <= 0) throw const SeerrFailure('media_not_scanned');
    if (isTv) {
      final details = _body(await tvDetails(tvId: tmdbId));
      if (details.id != tmdbId) throw const SeerrFailure('media_not_scanned');
      return SeerrIssueTarget.verified(tmdbId: tmdbId, isTv: true, title: details.name ?? '', media: details.mediaInfo);
    }
    final details = _body(await movieDetails(tmdbId: tmdbId));
    if (details.id != tmdbId) throw const SeerrFailure('media_not_scanned');
    return SeerrIssueTarget.verified(tmdbId: tmdbId, isTv: false, title: details.title ?? '', media: details.mediaInfo);
  }

  Future<SeerrIssuesResponse> issues({int skip = 0, bool management = false}) async {
    final user = await issueUser();
    if (!user.canViewIssues || (management && !user.canManageIssues)) {
      throw const SeerrFailure('permission_denied');
    }
    final page = _body(await _api.getIssues(
        take: 20,
        skip: skip,
        createdBy: management ? null : user.id,
        filter: management ? 'open' : 'all',
        sort: 'added'));
    if (!management && page.results.any((entry) => entry.createdBy?.id != user.id)) {
      throw const SeerrFailure('incompatible_filter');
    }
    return page;
  }

  Future<SeerrIssue> issue(int id) async {
    if (id <= 0) throw const SeerrFailure('invalid_report');
    return _body(await _api.getIssue(id));
  }

  Future<T> _mutate<T>(String key, Future<T> Function() action, {bool remember = false}) async {
    if (remember && _completedMutations.containsKey(key)) {
      return _completedMutations[key] as T;
    }
    if (_pendingMutations.contains(key)) {
      throw const SeerrFailure('already_sending');
    }
    if (_uncertainMutations.contains(key) || _uncertainMutations.length >= 20) {
      throw const SeerrFailure('timeout_check_history');
    }
    _pendingMutations.add(key);
    try {
      final result = await action();
      if (remember && result != null) {
        if (_completedMutations.length >= 20) {
          _completedMutations.remove(_completedMutations.keys.first);
        }
        _completedMutations[key] = result;
      }
      return result;
    } on SeerrFailure catch (error) {
      if ({'timeout_check_history', 'network_error', 'server_error', 'invalid_response'}.contains(error.code)) {
        _uncertainMutations.add(key);
      }
      rethrow;
    } finally {
      _pendingMutations.remove(key);
    }
  }

  Future<SeerrIssue> reportIssue(SeerrIssueTarget target, SeerrIssueType type, String message,
      {int? season, int? episode}) async {
    final body = target.issueBody(type, message, season: season, episode: episode);
    final user = await issueUser();
    if (!user.canCreateIssues) throw const SeerrFailure('permission_denied');
    final checked = await issueTarget(target.tmdbId, target.isTv);
    if (checked.mediaInfoId != target.mediaInfoId) {
      throw const SeerrFailure('media_not_scanned');
    }
    final key = 'issue:$body';
    final existing = await issues();
    for (final entry in existing.results) {
      if (entry.media?.id == target.mediaInfoId &&
          entry.issueType == type.value &&
          entry.problemSeason == season &&
          entry.problemEpisode == episode &&
          entry.comments.any((comment) => comment.message == message.trim())) {
        return entry;
      }
    }
    return _mutate(key, () async => _body(await _api.createIssue(body)), remember: true);
  }

  Future<SeerrIssue> addIssueComment(int id, String message) async {
    if (!seerrSafeMessage(message)) throw const SeerrFailure('invalid_report');
    final user = await issueUser();
    final existing = await issue(id);
    if (!user.canManageIssues && (!user.canCreateIssues || existing.createdBy?.id != user.id)) {
      throw const SeerrFailure('permission_denied');
    }
    if (existing.comments.any((entry) => entry.user?.id == user.id && entry.message == message.trim())) {
      return existing;
    }
    return _mutate(
        'comment:$id:${message.trim()}', () async => _body(await _api.commentIssue(id, {'message': message.trim()})),
        remember: true);
  }

  Future<SeerrIssue> changeIssueStatus(int id, bool resolved) async {
    final user = await issueUser();
    if (!user.canManageIssues) throw const SeerrFailure('permission_denied');
    return _mutate('status:$id', () async => _body(await _api.setIssueStatus(id, resolved ? 'resolved' : 'open')));
  }

  Future<Response<SeerrMediaRequest>> _submitSeerrRequest(SeerrCreateRequestBody body) async {
    final user = await issueUser();
    final isTv = body.mediaType == 'tv';
    if ((body.mediaId ?? 0) <= 0 || !user.canRequestMedia(isTv: isTv)) {
      throw const SeerrFailure('permission_denied');
    }
    if (isTv && (body.seasons == null || body.seasons!.isEmpty || body.seasons!.any((season) => season < 0))) {
      throw const SeerrFailure('select_seasons');
    }
    if (!user.canConfigureRequests &&
        (body.serverId != null || body.profileId != null || body.rootFolder != null || body.tags != null)) {
      throw const SeerrFailure('permission_denied');
    }
    if (body.userId != null && body.userId != user.id && !user.canManageUsers) {
      throw const SeerrFailure('permission_denied');
    }
    if (body.is4k == true &&
        !(user.hasPermission(SeerrPermission.request4k) ||
            user.hasPermission(isTv ? SeerrPermission.request4kTv : SeerrPermission.request4kMovie))) {
      throw const SeerrFailure('permission_denied');
    }
    final quota = await userQuota(userId: body.userId ?? user.id!);
    final entry = isTv ? quota?.tv : quota?.movie;
    final remaining = entry?.remaining;
    if (entry?.restricted == true ||
        (entry?.hasRestrictions == true && remaining != null && remaining < (isTv ? body.seasons!.length : 1))) {
      throw const SeerrFailure('quota_or_rate_limit');
    }
    final details = isTv
        ? _body(await tvDetails(tvId: body.mediaId!)).mediaInfo
        : _body(await movieDetails(tmdbId: body.mediaId!)).mediaInfo;
    for (final request in details?.requests ?? <SeerrMediaRequest>[]) {
      if (request.status != 3 &&
          request.requestedBy?.id == (body.userId ?? user.id) &&
          (request.is4k ?? false) == (body.is4k ?? false) &&
          (!isTv || body.seasons!.every((season) => request.seasons?.contains(season) ?? false))) {
        return Response(http.Response('', 200), request);
      }
    }
    return _mutate('request:${body.toJson()}', () async {
      final result = await _api.createRequest(body);
      _body(result);
      return result;
    }, remember: true);
  }
}
