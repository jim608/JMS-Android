import 'package:json_annotation/json_annotation.dart';
import 'package:fladder/seerr/seerr_models.dart';
import 'package:fladder/seerr/seerr_connection.dart';

part 'seerr_issue_models.g.dart';

enum SeerrIssueType {
  video(1),
  audio(2),
  subtitles(3),
  other(4);

  const SeerrIssueType(this.value);
  final int value;
}

@JsonSerializable()
class SeerrIssueComment {
  final int? id;
  final String? message;
  final SeerrUserModel? user;
  final DateTime? createdAt;
  SeerrIssueComment({this.id, this.message, this.user, this.createdAt});
  factory SeerrIssueComment.fromJson(Map<String, dynamic> json) =>
      _$SeerrIssueCommentFromJson(json);
  Map<String, dynamic> toJson() => _$SeerrIssueCommentToJson(this);
}

@JsonSerializable()
class SeerrIssue {
  final int id;
  final int issueType;
  final int status;
  final SeerrMedia? media;
  final SeerrUserModel? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int? problemSeason;
  final int? problemEpisode;
  final List<SeerrIssueComment> comments;
  SeerrIssue(
      {required this.id,
      required this.issueType,
      required this.status,
      this.media,
      this.createdBy,
      this.createdAt,
      this.updatedAt,
      this.problemSeason,
      this.problemEpisode,
      this.comments = const []});
  factory SeerrIssue.fromJson(Map<String, dynamic> json) =>
      _$SeerrIssueFromJson(json);
  Map<String, dynamic> toJson() => _$SeerrIssueToJson(this);
}

@JsonSerializable()
class SeerrIssuesResponse {
  final List<SeerrIssue> results;
  final SeerrPageInfo? pageInfo;
  SeerrIssuesResponse({this.results = const [], this.pageInfo});
  factory SeerrIssuesResponse.fromJson(Map<String, dynamic> json) =>
      _$SeerrIssuesResponseFromJson(json);
  Map<String, dynamic> toJson() => _$SeerrIssuesResponseToJson(this);
}

class SeerrIssueTarget {
  final int tmdbId;
  final int mediaInfoId;
  final bool isTv;
  final String title;
  const SeerrIssueTarget._(
      this.tmdbId, this.mediaInfoId, this.isTv, this.title);

  factory SeerrIssueTarget.verified(
      {required int tmdbId,
      required bool isTv,
      required String title,
      required SeerrMediaInfo? media}) {
    if (tmdbId <= 0 ||
        media?.id == null ||
        media!.id! <= 0 ||
        media.tmdbId != tmdbId || media.mediaType != (isTv ? 'tv' : 'movie')) {
      throw const SeerrFailure('media_not_scanned');
    }
    return SeerrIssueTarget._(tmdbId, media.id!, isTv, title);
  }

  Map<String, dynamic> issueBody(SeerrIssueType type, String message,
      {int? season, int? episode}) {
    if (!seerrSafeMessage(message) ||
        (season != null && (!isTv || season < 0)) ||
        (episode != null && (season == null || episode < 1))) {
      throw const SeerrFailure('invalid_report');
    }
    return {
      'mediaId': mediaInfoId,
      'issueType': type.value,
      'message': message.trim(),
      if (season != null) 'problemSeason': season,
      if (episode != null) 'problemEpisode': episode
    };
  }
}
